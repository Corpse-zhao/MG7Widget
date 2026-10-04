//
//  LocationService.swift
//  MG7Widget
//
//  位置服务：经纬度 → 中文地址
//
//  精度策略（2026-10-03 修订）：
//   1. 优先高德 Web 服务逆地理（最高精度，国内路名/门牌准确）——需用户在设置里填 key
//   2. 没有 key 时回退 iOS 原生 CLGeocoder（免费，但国内只到 POI/街道级，易串到隔壁）
//   3. 两者都失败则至少把原始经纬度保留给用户（可直达导航）
//
//  坐标系说明：SAIC 返回的是 WGS-84（GPS 原始值）。
//   高德 Web API 默认吃 GCJ-02，故请求时带 coordsys=wgs84 让它自行转换。
//   Apple 地图在中国大陆会自动做 WGS-84 → GCJ-02 纠偏，所以导航 URL 直接用原值即可。
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

    /// 车辆坐标是否为 GCJ-02（默认是，见 CoordTransform.swift 头注释）
    private var coordsAreGCJ02: Bool = true
    func setCoordsAreGCJ02(_ v: Bool) {
        coordsAreGCJ02 = v
        cache.removeAll()
    }

    /// 最近一次地址来源，便于 UI 提示精度
    private(set) var lastSource: String = ""

    /// 经纬度 → 中文地址
    /// 入参约定：SAIC 原始坐标（GCJ-02，若开关开）。
    /// 内部会先转 WGS-84 再喂给系统服务（系统内部会再纠偏回 GCJ，正好抵消）。
    func reverseGeocode(lat: Double?, lon: Double?) async -> String? {
        guard let lat = lat, let lon = lon, lat != 0, lon != 0 else { return nil }
        let key = String(format: "%.5f,%.5f", lat, lon) + (coordsAreGCJ02 ? "|g" : "|w")
        if let hit = cache[key] { return hit }

        // 若车辆坐标是 GCJ-02，先转 WGS-84（系统服务期望 WGS 输入）
        let (wLat, wLon) = coordsAreGCJ02
            ? CoordTransform.gcj2wgs(lat: lat, lon: lon)
            : (lat, lon)

        // 1) 高德（高精度）。注意：高德吃 GCJ-02 ——
        //    坐标本来就是 GCJ 就直接传；是 WGS 就带 coordsys=wgs84 让它转
        if !amapKey.isEmpty {
            let (aLat, aLon) = coordsAreGCJ02 ? (lat, lon) : (wLat, wLon)
            if let addr = await amap(lat: aLat, lon: aLon, inputIsWGS: !coordsAreGCJ02) {
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

    private func amap(lat: Double, lon: Double, inputIsWGS: Bool) async -> String? {
        // inputIsWGS 时带 coordsys=wgs84 让高德转换；输入已是 GCJ 则不带
        var urlStr = "https://restapi.amap.com/v3/geocode/regeo"
            + "?key=\(amapKey)"
            + "&location=\(String(format: "%.6f,%.6f", lon, lat))"
        if inputIsWGS { urlStr += "&coordsys=wgs84" }
        urlStr += "&extensions=base&output=JSON"
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
