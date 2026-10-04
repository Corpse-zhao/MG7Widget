//
//  LocationService.swift
//  MG7Widget
//
//  位置服务：经纬度 → 中文地址
//
//  精度策略（2026-10-04 修订）：
//   1. 优先高德 Web 服务逆地理（最高精度，国内路名/门牌准确）——需用户在设置里填 key
//   2. 没有 key 时回退 iOS 原生 CLGeocoder（免费，但国内只到 POI/街道级，易串到隔壁）
//   3. 两者都失败则至少把原始经纬度保留给用户（可直达导航）
//
//  坐标系结论（2026-10-04 实测定案）：
//   ⚠️ SAIC 后台返回 **WGS-84（GPS 原始值）**，不是 GCJ-02！
//   依据：官方 App「盈丰中路35号」vs 我们 v0.4.2「南洲北路751号」相差 1256m
//   ≈ 2×广州典型 GCJ 偏移(623m)——把 WGS 再转一次 WGS 必然产生双重偏移。
//
//   高德 regeo 的输入必须是 GCJ-02。官方文档参数表**没有 coordsys 字段**
//  （第三方实测只认 gps/mapbar/baidu，传 wgs84 会被静默忽略）——
//   v0.4.3 之前我们传 "coordsys=wgs84" 一直无效，地址长期偏 600m 的根因。
//   v0.4.4 起改为：**客户端用 CoordTransform.wgs2gcj 预转换后再传**，不依赖该参数。
//
//   Apple 地图在大陆会自动做 WGS→GCJ 纠偏，所以地图/导航 URL 直接用原值。
//

import Foundation
import CoreLocation

actor LocationService {

    static let shared = LocationService()
    private init() {}

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]

    /// 高德 Web 服务 key（设置页填写，为空则只用 CLGeocoder）
    private var amapKey: String = ""
    func setAmapKey(_ v: String) {
        amapKey = v.trimmingCharacters(in: .whitespacesAndNewlines)
        cache.removeAll()   // key 变了，缓存作废
    }

    /// 车辆坐标是否为 GCJ-02（实测默认 **否**：SAIC 返回 WGS-84）
    private var coordsAreGCJ02: Bool = false
    func setCoordsAreGCJ02(_ v: Bool) {
        coordsAreGCJ02 = v
        cache.removeAll()
    }

    /// 最近一次地址来源，便于 UI 提示精度
    private(set) var lastSource: String = ""

    /// 经纬度 → 中文地址
    /// 入参约定：SAIC 原始坐标（实测 WGS-84；若用户开关说 GCJ 则按 GCJ 处理）
    func reverseGeocode(lat: Double?, lon: Double?) async -> String? {
        guard let lat = lat, let lon = lon, lat != 0, lon != 0 else { return nil }
        let key = String(format: "%.5f,%.5f", lat, lon) + (coordsAreGCJ02 ? "|g" : "|w")
        if let hit = cache[key] { return hit }

        // WGS 视角坐标（CLGeocoder 期望 WGS 输入，系统内部会纠偏回 GCJ 查询）
        let (wLat, wLon) = coordsAreGCJ02
            ? CoordTransform.gcj2wgs(lat: lat, lon: lon)
            : (lat, lon)

        // 1) 高德（高精度）。高德吃 GCJ-02 —— 客户端先把坐标统一转成 GCJ 再传。
        //    ⚠️ v0.4.4：不再依赖 regeo 的 coordsys 参数！官方文档参数表里根本没有
        //    coordsys 字段（第三方实测只认 gps/mapbar/baidu），传 wgs84 会被静默
        //    忽略 → WGS 被当 GCJ 解析 → 地址偏 600m（「又回去了」的根因）
        if !amapKey.isEmpty {
            let g = coordsAreGCJ02
                ? (lat: lat, lon: lon)
                : CoordTransform.wgs2gcj(lat: lat, lon: lon)
            if let addr = await amap(lat: g.lat, lon: g.lon) {
                cache[key] = addr; lastSource = "高德"
                return addr
            }
        }

        // 2) CLGeocoder 回退（内部会 WGS→GCJ 查询，所以喂 WGS）
        if let addr = await clGeocode(lat: wLat, lon: wLon) {
            cache[key] = addr; lastSource = "系统"
            return addr
        }
        lastSource = "仅坐标"
        return nil
    }

    // MARK: - 高德 Web 服务逆地理

    /// 入参必须是 GCJ-02（调用方已保证），不再传 coordsys（官方不认 wgs84）
    private func amap(lat: Double, lon: Double) async -> String? {
        let urlStr = "https://restapi.amap.com/v3/geocode/regeo"
            + "?key=\(amapKey)"
            + "&location=\(String(format: "%.6f,%.6f", lon, lat))"
            + "&extensions=base&output=JSON"
        guard let url = URL(string: urlStr) else { return nil }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["status"] as? String) == "1",
                  let regeo = obj["regeocode"] as? [String: Any]
            else { return nil }

            // formatted_address 形如「广东省广州市海珠区瑞宝街道XX路XX号」
            if let formatted = regeo["formatted_address"] as? String, !formatted.isEmpty {
                // 若含门牌号更佳；否则用「区+街道+路名」
                if let comp = regeo["addressComponent"] as? [String: Any] {
                    let street = (comp["township"] as? String) ?? ""
                    let num = (comp["streetNumber"] as? [String: Any])?["street"] as? String ?? ""
                    let road = (comp["streetNumber"] as? [String: Any])?["street"] as? String ?? ""
                    if !road.isEmpty {
                        var s = formatted
                        // 把「街道」和「路名」拼进去，提高到达精度
                        if !street.isEmpty, !s.contains(street) { s += street }
                        if !num.isEmpty, !s.contains(num) { s += num }
                        return s
                    }
                }
                return formatted
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - CLGeocoder 回退

    private func clGeocode(lat: Double, lon: Double) async -> String? {
        let loc = CLLocation(latitude: lat, longitude: lon)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                loc, preferredLocale: Locale(identifier: "zh_CN"))
            // CLGeocoder 常返回多个候选，first 未必信息最全 → 取描述最完整的一个
            let best = placemarks.max { a, b in
                score(a) < score(b)
            }
            guard let p = best else { return nil }
            var parts: [String] = []
            if let a = p.administrativeArea { parts.append(a) }        // 省
            if let c = p.locality, c != p.administrativeArea { parts.append(c) }  // 市
            if let d = p.subLocality { parts.append(d) }               // 区
            if let s = p.subAdministrativeArea, !parts.contains(s) { parts.append(s) } // 街道办
            // 街道级：road + 门牌号
            if let t = p.thoroughfare {
                var road = t
                if let n = p.subThoroughfare, !road.contains(n) { road += n }
                parts.append(road)
            } else if let n = p.name, !parts.contains(n) {
                parts.append(n)
            }
            // 去重（相邻项可能重复，如「广州市 广州市」）
            var out: [String] = []
            for x in parts where !out.contains(x) { out.append(x) }
            let addr = out.joined()
            return addr.isEmpty ? nil : addr
        } catch {
            return nil
        }
    }

    /// 候选完整度打分：省市区街道门牌每有一项加分
    private func score(_ p: CLPlacemark) -> Int {
        var n = 0
        if p.administrativeArea != nil { n += 1 }
        if p.locality != nil { n += 1 }
        if p.subLocality != nil { n += 1 }
        if p.thoroughfare != nil { n += 2 }
        if p.subThoroughfare != nil { n += 2 }
        return n
    }
}
