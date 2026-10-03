//
//  VehicleSnapshot.swift
//  MG7Widget
//
//  车况快照数据模型 —— 字段名已于 2026-10-03 用真实响应核实
//  响应样本: tools/sample_response_full.json
//

import Foundation

struct VehicleSnapshot: Codable, Equatable {

    var vin: String
    var fetchedAt: Date

    // MARK: 基础车况
    var rangeKm: Double?            // driving_range
    var fuelPercent: Double?        // fuel_level_prc
    var fuelRangeKm: Double?        // fuel_range
    var isLocked: Bool?             // vehicle_state.lock
    var cabinTempC: Double?         // interior_temperature
    var outsideTempC: Double?       // exterior_temperature
    var odometerKm: Double?         // odometer
    var speedKmh: Double?           // speed

    // MARK: 胎压 kPa
    var tyreFrontLeft: Double?
    var tyreFrontRight: Double?
    var tyreRearLeft: Double?
    var tyreRearRight: Double?

    // MARK: 12V 电瓶（原值 ÷10）
    var battery12V: Double?         // vehicle_battery / 10
    var battery12Percent: Double?   // vehicle_battery_prc / 10

    // MARK: 开关状态
    var doorOpen: Bool?             // door
    var windowOpen: Bool?           // window
    var sunroofOpen: Bool?          // sunroof
    var bootOpen: Bool?             // boot
    var bonnetOpen: Bool?           // bonnet
    var climateOn: Bool?            // climate
    var engineRunning: Bool?        // engine

    // MARK: 位置
    var latitude: Double?
    var longitude: Double?
    var gpsStatus: Int?             // 2/3 = 定位成功
    var address: String?

    // MARK: 派生

    var isParked: Bool { (speedKmh ?? 0) == 0 && (engineRunning == false) }

    /// 数据是否过期（超过 30 分钟）
    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 1800 }

    /// 胎压是否偏低（MG7 建议 230-250 kPa）
    var lowTyres: [String] {
        var out: [String] = []
        if let v = tyreFrontLeft,  v < 220 { out.append("左前") }
        if let v = tyreFrontRight, v < 220 { out.append("右前") }
        if let v = tyreRearLeft,   v < 220 { out.append("左后") }
        if let v = tyreRearRight,  v < 220 { out.append("右后") }
        return out
    }

    /// 油量是否告急
    var isFuelLow: Bool { (fuelPercent ?? 100) <= 15 }

    static func empty(vin: String) -> VehicleSnapshot {
        VehicleSnapshot(vin: vin, fetchedAt: .distantPast)
    }
}
