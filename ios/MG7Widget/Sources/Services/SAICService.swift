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
import CommonCrypto

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
        return try await send(req)
    }

    /// 通用请求发送（供控车复用）
    private func send(_ req: URLRequest) async throws -> Data {
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

    // MARK: - 控车（P5）
    //
    // 状态：接口形态待抓包确认（MG Live 控车走独立路径，与只读车况不同）。
    // 抓包方法见 docs/03-控车逆向.md。
    //
    // 设计目标：抓到包后，**只需填下面的 CommandSpec 表**即可上线，
    //           不需要改动本文件其余逻辑。
    //
    // 已预留三种认证模式（按抓到包的真实情况选一种）：
    //   .plain      —— 无签名，参数直接发
    //   .bodySign   —— sign = MD5(排序后的参数串 + secret)
    //   .headersSign—— sign 放在请求头（原样重放即可）

    enum Command: String {
        case lock   = "lock"
        case unlock = "unlock"
        case acOn   = "ac_on"
        case acOff  = "ac_off"
    }

    /// 单条指令的接口描述 —— 抓包后只改这里
    struct CommandSpec {
        let method: String              // "POST" / "GET"
        let path: String                // 相对路径，如 "/app-mp/vp/1.1/controlVehicle"
        let bodyTemplate: [String: Any] // 请求体模板，用 {cmd} / {vin} / {token} 占位
        let contentType: String         // "application/json" 或 "application/x-www-form-urlencoded"
    }

    /// ⚠️ 待抓包填充：把下面三条换成真实值
    /// 若三条指令共用同一路径、只是 command 值不同，可合并成一条 spec。
    private static let commandSpecs: [Command: CommandSpec] = [:]
    // 填充示例（抓到包后照抄真实值，删掉注释即可）：
    //
    //  [.unlock: CommandSpec(
    //      method: "POST",
    //      path: "/app-mp/vp/1.1/controlVehicle",
    //      bodyTemplate: ["command": "unlock", "vin": "{vin}", "token": "{token}"],
    //      contentType: "application/json")],
    //  [.lock:   CommandSpec(... "command": "lock"  ...)],
    //  [.acOn:   CommandSpec(... "command": "ac_on" ...)],

    /// 认证模式枚举
    enum AuthMode {
        case plain
        case bodySign(secret: String)
        case headersSign(headers: [String: String])
    }

    /// ⚠️ 待抓包确认：看抓到的请求里 sign 是否出现、放哪
    private static let authMode: AuthMode = .plain

    /// ⚠️ 安全要求：调用前必须有 UI 二次确认，禁止静默执行。
    func sendCommand(_ cmd: Command,
                     token: String,
                     vin: String,
                     userId: String = "",
                     userName: String = "") async throws -> String {

        guard !token.isEmpty, vin.count == 17 else { throw SAICError.badConfig }

        // 1. 取指令描述；未配置说明尚未完成逆向
        guard let spec = Self.commandSpecs[cmd] else {
            throw SAICError.api("NOT_IMPLEMENTED",
                "该指令的接口尚未配置（需按 docs/03-控车逆向.md 抓包后填入 CommandSpec）")
        }

        // 2. 组装参数：替换占位符
        var body: [String: Any] = [:]
        for (k, v) in spec.bodyTemplate {
            if let s = v as? String {
                switch s {
                case "{vin}":      body[k] = vin
                case "{token}":    body[k] = token
                case "{cmd}":      body[k] = cmd.rawValue
                case "{userId}":   body[k] = userId
                case "{userName}": body[k] = userName
                case "{ts}":       body[k] = Int(Date().timeIntervalSince1970)
                case "{tsMs}":     body[k] = Int(Date().timeIntervalSince1970 * 1000)
                default:           body[k] = s
                }
            } else {
                body[k] = v
            }
        }

        // 3. 按认证模式加工
        var extraHeaders: [String: String] = [:]
        switch Self.authMode {
        case .plain:
            break
        case .bodySign(let secret):
            body["sign"] = Self.sign(params: body, secret: secret)
        case .headersSign(let headers):
            extraHeaders = headers
        }

        // 4. 发请求
        let url = URL(string: "https://mp.ebanma.com" + spec.path)!
        var req = URLRequest(url: url)
        req.httpMethod = spec.method
        req.setValue("okhttp/4.9.3", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(spec.contentType, forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        if spec.method.uppercased() == "POST" {
            if spec.contentType.contains("json") {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            } else {
                var comps = URLComponents()
                comps.queryItems = body.map { URLQueryItem(name: $0.key,
                                    value: "\($0.value)") }
                req.httpBody = comps.query?.data(using: .utf8)
            }
        } else {
            // GET：参数拼到 query
            var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comp.queryItems = body.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
            req.url = comp.url
        }

        // 5. 解析响应
        let data = try await send(req)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SAICError.decode("控车响应非 JSON")
        }
        if let err = root["err_resp"] as? [String: Any] {
            let code = err["code"] as? String ?? "?"
            let msg  = err["msg"]  as? String ?? "未知错误"
            if code == "14101" { throw SAICError.tokenExpired }
            throw SAICError.api(code, msg)
        }
        // 成功：返回服务端提示语（可能是「指令已下发」之类）
        if let d = root["data"] as? [String: Any],
           let m = d["msg"] as? String { return m }
        return root["msg"] as? String ?? "指令已下发"
    }

    /// 常见签名算法：参数按 key 升序拼 k=v&... 后接 secret，取 MD5
    /// （抓到真实请求后核对：看排序方式与是否含空值）
    private static func sign(params: [String: Any],
                             secret: String) -> String {
        let sorted = params.keys.sorted()
        let joined = sorted.map { "\($0)=\(params[$0]!)" }.joined(separator: "&")
        return md5(joined + secret)
    }

    private static func md5(_ s: String) -> String {
        // 用系统 CryptoKit 会引入依赖，这里用 CommonCrypto
        var digest = [UInt8](repeating: 0, count: 16)
        let bytes = Array(s.utf8)
        CC_MD5(bytes, CC_LONG(bytes.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
