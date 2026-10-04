//
//  CoordTransform.swift
//  MG7Widget
//
//  WGS-84（GPS 原始）↔ GCJ-02（国测局火星坐标）双向转换
//
//  ⚠️ 为什么需要（2026-10-04 实锤）：
//  国家法规要求国内车联网平台上报的位置必须是 GCJ-02。
//  SAIC 返回的 latitude/longitude 实为 GCJ-02，之前被当 WGS-84 直接用：
//   - Apple 地图导航：Apple 对中国区输入坐标再做一次 WGS→GCJ 纠偏
//     → 双重转换 → 车辆位置偏移 500-700 米（用户实车验证）
//   - CLGeocoder 反地理编码：同理偏移
//  修复：凡是要把坐标交给 iOS 系统服务（地图/地理编码）的场景，
//  先 GCJ→WGS 转换，让系统内部的那次纠偏正好抵消回真实位置。
//

import Foundation

enum CoordTransform {

    private static let a = 6378245.0                     // 长半轴
    private static let ee = 0.00669342162296594323      // 偏心率平方
    private static let pi = Double.pi

    /// 是否在中国境外（境外无偏移，直接原样返回）
    static func outOfChina(lat: Double, lon: Double) -> Bool {
        lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y
            + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * pi) + 320.0 * sin(y * pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x
            + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0
        return ret
    }

    /// WGS-84 → GCJ-02
    static func wgs2gcj(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        if outOfChina(lat: lat, lon: lon) { return (lat, lon) }
        var dLat = transformLat(lon - 105.0, lat - 35.0)
        var dLon = transformLon(lon - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * pi)
        return (lat + dLat, lon + dLon)
    }

    /// GCJ-02 → WGS-84（一次逆推，误差 < 1 米，导航足够）
    static func gcj2wgs(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        if outOfChina(lat: lat, lon: lon) { return (lat, lon) }
        let (gLat, gLon) = wgs2gcj(lat: lat, lon: lon)
        return (lat * 2.0 - gLat, lon * 2.0 - gLon)
    }
}
