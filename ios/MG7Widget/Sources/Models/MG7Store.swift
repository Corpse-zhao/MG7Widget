//
//  MG7Store.swift
//  MG7Widget
//
//  共享存储：App 与 Widget Extension 通过固定路径交换数据。
//  roothide 下 App Group 不可靠，故使用 /var/mobile/Library/MG7Widget/
//  非越狱环境自动回退到 App 沙盒（便于调试）。
//

import Foundation

enum MG7Store {

    // MARK: - 路径

    private static let jailDir = "/var/mobile/Library/MG7Widget"

    /// 确保共享目录可用，返回目录 URL；彻底不可用则返回 nil
    ///
    /// ⚠️ 权限模型（v0.3.5 修正）：
    ///  - App（TrollStore）以 root 运行；Widget 扩展由系统以 mobile 用户拉起。
    ///  - 旧版用「可写探针」判断 → mobile 的 Widget 对 root 目录写不进 →
    ///    误判回退到扩展自己沙盒 → 读不到 snapshot.json → 小组件全 "—"。
    ///  - Widget 只需要「可读」！探针改为可读性判断。
    ///  - 目录显式 755、数据文件 644，App 端每次保存后强制修正权限。
    private static func ensureSharedDir() -> URL? {
        let fm = FileManager.default
        let u = URL(fileURLWithPath: jailDir)

        if fm.fileExists(atPath: jailDir) {
            // 已存在：可读即用（Widget 场景只读就够）
            if fm.isReadableFile(atPath: u.path) { return u }
            // 不可读：尝试修权限（root 场景会成功；mobile 场景失败 → nil）
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jailDir)
            return fm.isReadableFile(atPath: u.path) ? u : nil
        }
        // 不存在：创建（App 首启；Widget 也可能先跑，mobile 对 /var/mobile/Library 可写）
        do {
            try fm.createDirectory(at: u, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            return u
        } catch {
            return nil
        }
    }

    /// 共享目录。越狱环境用固定路径，否则回退沙盒。
    static var directory: URL {
        if let u = ensureSharedDir() { return u }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
    }

    /// App 端调用：写完数据后把共享目录和文件权限修到「mobile 可读」
    private static func fixPermissions(file: String? = nil) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jailDir)
        if let f = file {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f)
        }
    }

    static var configURL:   URL { directory.appendingPathComponent("config.plist") }
    static var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }

    // MARK: - 配置（token / vin / 车辆信息）

    struct Config: Codable {
        var accessToken: String = ""
        var vin: String = ""
        var userId: String = ""
        var carName: String = "我的 MG7"
        var plateNumber: String = ""
        var fuelCapacity: Double = 65.0     // MG7 油箱 65L（源码证实）
        var autoRefresh: Bool = true
        var lastTokenSync: Date = .distantPast
        /// 高德 Web 服务 key（可选，填了定位更准；留空则用系统 CLGeocoder）
        var amapKey: String = ""

        var isValid: Bool {
            !accessToken.isEmpty && vin.count == 17
        }
    }

    static func saveConfig(_ c: Config) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .xml
        guard let data = try? enc.encode(c) else { return }
        try? data.write(to: configURL, options: .atomic)
        // 644（不再 600）：Widget(mobile) 要读车名等展示字段；
        // token 在越狱机上本就无绝对边界，644 风险增量可忽略
        fixPermissions(file: configURL.path)
    }

    static func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let c = try? PropertyListDecoder().decode(Config.self, from: data)
        else { return Config() }
        return c
    }

    // MARK: - 车况快照

    static func saveSnapshot(_ s: VehicleSnapshot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
        // 关键：目录 755 + 文件 644，否则 mobile 用户的 Widget 扩展读不到
        fixPermissions(file: snapshotURL.path)
    }

    static func loadSnapshot() -> VehicleSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(VehicleSnapshot.self, from: data)
    }

    // MARK: - 控制指令（跨进程开关，供 Debug 用）

    /// 写一个「请求刷新」标记，宿主 App 启动时消费
    static func requestRefresh() {
        try? Data().write(to: directory.appendingPathComponent(".refresh"))
    }
}
