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

    /// 电压归一化：服务端不同接口版本量纲不一（×10 或 ×100），取落在 8~18V 的候选
    private static func normalizeVoltage(_ v: Double) -> Double {
        let candidates = [v, v / 10.0, v / 100.0]
        return candidates.first { (8.0...18.0).contains($0) } ?? (v / 10.0)
    }

    /// 百分比归一化：同理，取落在 0~100% 的候选（先试原值本身）
    private static func normalizePercent(_ v: Double) -> Double {
        let candidates = [v, v / 10.0, v / 100.0]
        return candidates.first { (0.0...100.0).contains($0) } ?? (v / 10.0)
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

        // 电瓶：服务端量纲不统一（vp/1.1 实测 119=11.9V ÷10；vp/1.2 实测 1210=12.1V ÷100）
        // → 智能归一化：取落在合理电压区间 8~18V 的候选值
        s.battery12V = num(val, "vehicle_battery").map { Self.normalizeVoltage($0) }
        s.battery12Percent = num(val, "vehicle_battery_prc").map { Self.normalizePercent($0) }

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

    // MARK: - 控车（P5）—— 接口已逆向完成 ✅
    //
    // 2026-10-03 抓包实证（两条真实请求对比）：
    //
    //   GET https://mp.ebanma.com/app-mp/mqttpublish/1.0/mqttStatisticDataApi
    //       ?data=<URL编码的 JSON>
    //
    //   data 解码后：
    //   {"MQTTStatisticsDataDTO":"{\"commandId\":367794450,
    //     \"timestamp7\":1791037107463,\"timestamp1\":1791037101027,
    //     \"commandType\":\"上锁车门\",\"vin\":\"LSJWJ4W90SZ187922\",
    //     \"aliClientId\":\"GID_ios_mg@@@318FE098-...\"}"}
    //
    // 要点：
    //   - 指令本体 = commandType，**中文明文**（不是数字码）
    //     实测：「上锁车门」/「开启空调」
    //   - 外层 key = MQTTStatisticsDataDTO，其值是**一个被转义的 JSON 字符串**
    //   - commandId 用前半段 2025+流水号；实测值 202503679445 / 367794450
    //     ⇒ 服务端只做统计上报用途，我们自己生成即可（无需严格与服务端一致）
    //   - 响应恒为 {"req_id":"...","data":null}（只受理），
    //     真正执行结果走 MQTT 异步回报 → 调完刷新车况即可，不必自己连 MQTT
    //   - 实测该接口**未强制校验 sign**（sign 每次不同，但车况接口同样不校验）

    enum Command: String {
        case lock   = "lock"
        case unlock = "unlock"
        case acOn   = "ac_on"
        case acOff  = "ac_off"
    }

    /// 指令 → 服务端中文指令名（实测确认）
    /// ⚠️ 未实测的按语义推测，首次使用请对照 App 行为核验
    private static func commandTypeText(_ cmd: Command) -> String {
        switch cmd {
        case .lock:   return "上锁车门"      // ✅ 实测（22:19 抓包）
        case .unlock: return "解锁车门"      // ⚠️ 推测（请核验）
        case .acOn:   return "开启空调"      // ✅ 实测（22:03 抓包）
        case .acOff:  return "关闭空调"      // ⚠️ 推测（请核验）
        }
    }

    /// 控车接口路径（实测）
    private let controlPath = "/app-mp/mqttpublish/1.0/mqttStatisticDataApi"

    /// 该设备的 aliClientId —— 实测形如 GID_ios_mg@@@<UUID>
    /// 从 MG Live 抓包得到，或由 MGHelper 提供；缺失时用固定前缀兜底
    private var aliClientId: String = "GID_ios_mg@@@318FE098-2FDD-43DD-906A-5CD3574B456D"

    /// 允许外部注入真实的 aliClientId（设置页/MGHelper 提供）
    func setAliClientId(_ v: String) { if !v.isEmpty { aliClientId = v } }

    /// ⚠️ 安全要求：调用前必须有 UI 二次确认，禁止静默执行。
    /// 返回服务端受理提示；实际执行结果需稍后刷新车况确认。
    func sendCommand(_ cmd: Command,
                     token: String,
                     vin: String,
                     userId: String = "",
                     userName: String = "") async throws -> String {

        guard !token.isEmpty, vin.count == 17 else { throw SAICError.badConfig }

        let now = Int(Date().timeIntervalSince1970 * 1000)
        // 内层 JSON（字段顺序与实测一致，用数组保序构造）
        let inner = Self.buildInnerJSON(
            commandId: Self.makeCommandId(),
            ts7: now,
            ts1: now - 6000,
            commandType: Self.commandTypeText(cmd),
            vin: vin,
            aliClientId: aliClientId)

        // 外层：{"MQTTStatisticsDataDTO":"<转义后的内层JSON字符串>"}
        let outer: [String: Any] = ["MQTTStatisticsDataDTO": inner]
        let outerData = try JSONSerialization.data(withJSONObject: outer)
        let outerStr = String(data: outerData, encoding: .utf8) ?? "{}"

        var comp = URLComponents(string: "https://mp.ebanma.com" + controlPath)!
        comp.queryItems = [URLQueryItem(name: "data", value: outerStr)]

        // 请求头 —— v0.4.1 起与 MG Live 实测控车请求 100% 对齐（sign 除外）。
        // 2026-10-04 抓包对照发现：我们此前缺 Uuid/Model/brandCode/Accept-Language/
        // osVersion/watch-man-mobile/watch-man-token，且 timestamp 头应为秒级取整。
        // 服务端可能按「指纹完整度」决定是否真下发指令（受理≠执行）。
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "GET"
        req.setValue("MGProject_PD/2.1.7 (iPhone; iOS 16.6; Scale/3.00)", forHTTPHeaderField: "User-Agent")
        req.setValue("App", forHTTPHeaderField: "X-Client-Id")
        req.setValue("mgapp", forHTTPHeaderField: "app-type")
        req.setValue("2.1.7", forHTTPHeaderField: "versionCode")
        req.setValue("MG", forHTTPHeaderField: "channelID")
        req.setValue("iOS", forHTTPHeaderField: "os")
        req.setValue("IOS", forHTTPHeaderField: "watch-man-check-type")
        req.setValue("T", forHTTPHeaderField: "watch-man-check-flag")
        req.setValue("", forHTTPHeaderField: "watch-man-mobile")
        req.setValue("", forHTTPHeaderField: "watch-man-token")
        req.setValue("ehs", forHTTPHeaderField: "Model")          // MG7 车型代号（抓包实测）
        req.setValue("2", forHTTPHeaderField: "brandCode")
        req.setValue("zh-cn", forHTTPHeaderField: "Accept-Language")
        req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("16.6", forHTTPHeaderField: "osVersion")
        // Uuid 头 = aliClientId 的 @@@ 后段（GID_ios_mg@@@UUID → UUID，实测一致）
        if let uuidPart = aliClientId.split(separator: "@@@").last.map(String.init),
           !uuidPart.isEmpty {
            req.setValue(uuidPart, forHTTPHeaderField: "Uuid")
        }
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "token")
        if !userId.isEmpty { req.setValue(userId, forHTTPHeaderField: "userid") }
        // timestamp 头：MG Live 实测为毫秒向下取整到秒（1791797986800 → 1791797986000）
        req.setValue(String(now / 1000 * 1000), forHTTPHeaderField: "timestamp")

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
        // 实测成功响应：{"req_id":"...","data":null}
        return "指令已下发（\(Self.commandTypeText(cmd))）"
    }

    /// 手工构造内层 JSON —— 必须保持字段顺序与实测一致
    /// （服务端疑似按顺序解析，且需要正确的转义形态）
    private static func buildInnerJSON(commandId: Int, ts7: Int, ts1: Int,
                                       commandType: String, vin: String,
                                       aliClientId: String) -> String {
        // 注意：这是「字符串形式」的 JSON，稍后由外层序列化器自动转义
        func esc(_ s: String) -> String {
            return s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
        }
        return "{\"commandId\":\(commandId),"
             + "\"timestamp7\":\(ts7),"
             + "\"timestamp1\":\(ts1),"
             + "\"commandType\":\"\(esc(commandType))\","
             + "\"vin\":\"\(esc(vin))\","
             + "\"aliClientId\":\"\(esc(aliClientId))\"}"
    }

    /// commandId：实测为 2025 + 递增流水（202503679445 / 367794450）
    /// 服务端仅作统计，非严格校验，此处生成一个合理值
    private static func makeCommandId() -> Int {
        let seq = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000
        return 2025 * 100_000_000 + seq % 100_000_000
    }
}
