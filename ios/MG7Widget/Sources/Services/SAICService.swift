//
//  SAICService.swift
//  MG7Widget
//
//  SAIC / MG Live 车况接口客户端
//  ✅ 接口已于 2026-10-03 实测打通（PC 端与手机端均成功）
//
//  主接口：
//    GET https://mp.ebanma.com/app-mp/vp/1.2/getVehicleStatus
//        ?data={"appid":"MG","timestamp":<毫秒>,"vin":"...","token":"..."}
//  备用接口（MG Linker 同款，实测同样可用）：
//    GET https://mp.ebanma.com/app-mp/vp/1.1/getVehicleStatus
//        ?timestamp=<秒>&token=...&vin=...
//
//  ⚠️ token 会随 MG Live 使用而轮换，旧 token 立即失效（错误码 14101）
//

import Foundation

enum SAICError: LocalizedError {
    case badConfig
    case tokenExpired          // 14101：需 MGHelper 重新取 token
    case http(Int, String)
    case api(String, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badConfig:          return "配置不完整（需填写 token 与 VIN）"
        case .tokenExpired:       return "登录态已失效，token 需刷新（MG Live 打开一次即可）"
        case .http(let c, let m): return "网络错误 HTTP \(c)：\(m.prefix(100))"
        case .api(let c, let m):  return "接口返回错误 \(c)：\(m)"
        case .decode(let s):      return "数据解析失败：\(s)"
        }
    }
}

actor SAICService {

    static let shared = SAICService()
    private init() {}

    private let endpointV12 = "https://mp.ebanma.com/app-mp/vp/1.2/getVehicleStatus"
    private let endpointV11 = "https://mp.ebanma.com/app-mp/vp/1.1/getVehicleStatus"

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - 拉取车况

    func fetchSnapshot(token: String, vin: String) async throws -> VehicleSnapshot {
        guard !token.isEmpty, vin.count == 17 else { throw SAICError.badConfig }

        // 先试 vp/1.2（App 同款），失败再退 vp/1.1
        do {
            return try await fetchV12(token: token, vin: vin)
        } catch SAICError.tokenExpired {
            throw SAICError.tokenExpired      // token 死了，换接口也没用
        } catch {
            return try await fetchV11(token: token, vin: vin)
        }
    }

    // MARK: vp/1.2（facade JSON 参数）

    private func fetchV12(token: String, vin: String) async throws -> VehicleSnapshot {
        let payload: [String: Any] = [
            "appid": "MG",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "vin": vin,
            "token": token,
        ]
        let jsonStr = String(data: try JSONSerialization.data(withJSONObject: payload),
                             encoding: .utf8) ?? "{}"
        var comp = URLComponents(string: endpointV12)!
        comp.queryItems = [URLQueryItem(name: "data", value: jsonStr)]

        let data = try await send(comp.url!)
        return try parse(data, vin: vin)
    }

    // MARK: vp/1.1（平铺参数，MG Linker 同款）

    private func fetchV11(token: String, vin: String) async throws -> VehicleSnapshot {
        var comp = URLComponents(string: endpointV11)!
        comp.queryItems = [
            URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970))),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "vin", value: vin),
        ]
        let data = try await send(comp.url!)
        return try parse(data, vin: vin)
    }

    // MARK: - 网络

    private func send(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("okhttp/4.9.3", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw SAICError.decode("非 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw SAICError.http(http.statusCode,
                                 String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - 解析

    private func parse(_ data: Data, vin: String) throws -> VehicleSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SAICError.decode("根节点不是对象")
        }
        // 业务错误
        if let err = root["err_resp"] as? [String: Any] {
            let code = err["code"] as? String ?? "?"
            let msg  = err["msg"]  as? String ?? "未知错误"
            if code == "14101" { throw SAICError.tokenExpired }
            throw SAICError.api(code, msg)
        }
        guard let d = root["data"] as? [String: Any] else {
            throw SAICError.decode("缺少 data 节点")
        }
        return Self.map(d, vin: vin)
    }

    // MARK: - 字段映射（已用真实响应核实）

    private static func map(_ d: [String: Any], vin: String) -> VehicleSnapshot {
        let val = d["vehicle_value"]    as? [String: Any] ?? [:]
        let st  = d["vehicle_state"]    as? [String: Any] ?? [:]
        let pos = d["vehicle_position"] as? [String: Any] ?? [:]

        func num(_ n: [String: Any], _ k: String) -> Double? {
            if let v = n[k] as? Int    { return Double(v) }
            if let v = n[k] as? Double { return v }
            if let v = n[k] as? String { return Double(v) }
            return nil
        }
        func int(_ n: [String: Any], _ k: String) -> Int? { n[k] as? Int }
        func bool(_ n: [String: Any], _ k: String) -> Bool? { n[k] as? Bool }

        var s = VehicleSnapshot(vin: vin, fetchedAt: Date())

        s.rangeKm       = num(val, "driving_range")
        s.fuelPercent   = num(val, "fuel_level_prc")
        s.fuelRangeKm   = num(val, "fuel_range")
        s.isLocked      = bool(st, "lock")
        s.cabinTempC    = num(val, "interior_temperature")
        s.outsideTempC  = num(val, "exterior_temperature")
        s.odometerKm    = num(val, "odometer")
        s.speedKmh      = num(val, "speed")

        s.tyreFrontLeft  = num(val, "front_left_tyre_pressure")
        s.tyreFrontRight = num(val, "front_right_tyre_pressure")
        s.tyreRearLeft   = num(val, "rear_left_tyre_pressure")
        s.tyreRearRight  = num(val, "rear_right_tyre_pressure")

        // 电瓶：原值 ÷10（实测 119 → 11.9V，prc 700 → 70.0%）
        s.battery12V        = num(val, "vehicle_battery").map { $0 / 10.0 }
        s.battery12Percent  = num(val, "vehicle_battery_prc").map { $0 / 10.0 }

        s.doorOpen      = bool(st, "door")
        s.windowOpen    = bool(st, "window")
        s.sunroofOpen   = bool(st, "sunroof")
        s.bootOpen      = bool(st, "boot")
        s.bonnetOpen    = bool(st, "bonnet")
        s.climateOn     = bool(st, "climate")
        s.engineRunning = bool(st, "engine")

        s.latitude  = num(pos, "latitude")
        s.longitude = num(pos, "longitude")
        s.gpsStatus = int(pos, "gps_status")

        return s
    }

    // MARK: - 控车（P5 阶段实现，需先完成接口逆向）

    enum Command: String {
        case lock   = "lock"
        case unlock = "unlock"
        case acOn   = "ac_on"
        case acOff  = "ac_off"
    }

    /// ⚠️ 安全要求：调用前必须有 UI 二次确认，禁止静默执行。
    /// 接口逆向方法见 docs/03-控车逆向.md
    func sendCommand(_ cmd: Command,
                     token: String,
                     vin: String,
                     userId: String,
                     userName: String) async throws {
        // 待 P5 阶段按真实控车接口实现
        throw SAICError.api("TODO", "控车接口尚未逆向完成")
    }
}
