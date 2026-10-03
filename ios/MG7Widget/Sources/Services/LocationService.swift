//
//  LocationService.swift
//  MG7Widget
//
//  位置服务：反地理编码（用 iOS 原生 CLGeocoder，无需第三方 API）
//

import Foundation
import CoreLocation

actor LocationService {

    static let shared = LocationService()
    private init() {}

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]

    /// 经纬度 → 中文地址
    func reverseGeocode(lat: Double?, lon: Double?) async -> String? {
        guard let lat = lat, let lon = lon, lat != 0, lon != 0 else { return nil }
        let key = String(format: "%.4f,%.4f", lat, lon)   // 4 位精度做缓存键
        if let hit = cache[key] { return hit }

        let loc = CLLocation(latitude: lat, longitude: lon)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                loc, preferredLocale: Locale(identifier: "zh_CN"))
            guard let p = placemarks.first else { return nil }
            var parts: [String] = []
            if let a = p.administrativeArea { parts.append(a) }
            if let c = p.locality, c != p.administrativeArea { parts.append(c) }
            if let d = p.subLocality { parts.append(d) }
            if let t = p.thoroughfare {
                var road = t
                if let n = p.subThoroughfare { road += n }
                parts.append(road)
            } else if let n = p.name {
                parts.append(n)
            }
            let addr = parts.joined()
            if !addr.isEmpty { cache[key] = addr; return addr }
        } catch {
            return nil
        }
        return nil
    }
}
