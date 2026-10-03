//
//  MG7Store.swift
//  MG7Widget
//
//  共享存储：App 与 Widget Extension 跨进程交换数据。
//
//  ⚠️ 通道演进史（重要教训，别再踩）：
//   v0.1~0.4 固定路径 /var/mobile/Library/MG7Widget/ —— App(root) 能写，
//            但 Widget 扩展由系统拉起，其沙盒 profile 拒绝访问任意绝对路径，
//            entitlement 的 absolute-path exception 对 extension 无效 → 永远读不到
//   v0.5+   改用 App Group（iOS 官方跨进程通道，Widget 沙盒天然放行）。
//            TrollStore 保留全部 entitlements，系统会为 group 自动创建共享容器。
//            固定路径保留作诊断/回退，写入时双写，读取 group 优先。
//

import Foundation

enum MG7Store {

    // MARK: - 通道定义

    /// App Group ID（App 与 Widget 两 target 的 entitlements 均已声明）
    static let appGroupID = "group.com.banliren.mg7widget"

    /// 旧固定路径（v0.4 及之前的通道，保留作回退/诊断）
    private static let jailDir = "/var/mobile/Library/MG7Widget"

    /// App Group 共享容器。Widget 沙盒天然放行；容器不存在时尝试创建。
    static var groupDirectory: URL? {
        guard let u = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: u.path) {
            try? fm.createDirectory(at: u, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o755])
        }
        // App 是 root 时 umask 不确定，显式保证 mobile 可读（老教训：v0.3.5 权限坑）
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    /// UserDefaults suite（与 group 容器同源，双保险）
    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - 旧固定路径（回退用）

    private static func ensureSharedDir() -> URL? {
        let fm = FileManager.default
        let u = URL(fileURLWithPath: jailDir)

        if fm.fileExists(atPath: jailDir) {
            if fm.isReadableFile(atPath: u.path) { return u }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jailDir)
            return fm.isReadableFile(atPath: u.path) ? u : nil
        }
        do {
            try fm.createDirectory(at: u, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            return u
        } catch {
            return nil
        }
    }

    /// 旧固定路径目录（诊断用途；App 端写，Widget 大概率读不到但留着无害）
    static var directory: URL {
        if let u = ensureSharedDir() { return u }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
    }

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
        // ① 旧固定路径（App 内部兼容）
        if let data = try? PropertyListEncoder().encode(c) {
            try? data.write(to: configURL, options: .atomic)
            fixPermissions(file: configURL.path)
        }
        // ② App Group：UserDefaults（主通道，跨进程最可靠）
        if let d = sharedDefaults {
            if let json = try? JSONEncoder().encode(c) {
                d.set(json, forKey: "config")
            }
        }
        // ③ App Group 容器文件（备用）
        if let dir = groupDirectory,
           let data = try? PropertyListEncoder().encode(c) {
            try? data.write(to: dir.appendingPathComponent("config.plist"), options: .atomic)
        }
    }

    static func loadConfig() -> Config {
        // 优先级：UserDefaults → group 容器文件 → 旧固定路径
        if let d = sharedDefaults, let json = d.data(forKey: "config"),
           let c = try? JSONDecoder().decode(Config.self, from: json) {
            return c
        }
        if let dir = groupDirectory,
           let data = try? Data(contentsOf: dir.appendingPathComponent("config.plist")),
           let c = try? PropertyListDecoder().decode(Config.self, from: data) {
            return c
        }
        if let data = try? Data(contentsOf: configURL),
           let c = try? PropertyListDecoder().decode(Config.self, from: data) {
            return c
        }
        return Config()
    }

    // MARK: - 车况快照

    static func saveSnapshot(_ s: VehicleSnapshot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(s) else { return }

        // ① 旧固定路径（诊断/回退）
        try? data.write(to: snapshotURL, options: .atomic)
        fixPermissions(file: snapshotURL.path)

        // ② App Group 容器文件（Widget 主通道）
        if let dir = groupDirectory {
            let f = dir.appendingPathComponent("snapshot.json")
            try? data.write(to: f, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: f.path)
        }

        // ③ UserDefaults suite（双保险）
        sharedDefaults?.set(data, forKey: "snapshot")
    }

    static func loadSnapshot() -> VehicleSnapshot? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        // 优先级：group 容器文件 → UserDefaults → 旧固定路径
        if let dir = groupDirectory,
           let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")),
           let s = try? dec.decode(VehicleSnapshot.self, from: data) {
            return s
        }
        if let data = sharedDefaults?.data(forKey: "snapshot"),
           let s = try? dec.decode(VehicleSnapshot.self, from: data) {
            return s
        }
        if let data = try? Data(contentsOf: snapshotURL),
           let s = try? dec.decode(VehicleSnapshot.self, from: data) {
            return s
        }
        return nil
    }

    // MARK: - 控制指令（跨进程开关，供 Debug 用）

    /// 写一个「请求刷新」标记，宿主 App 启动时消费
    static func requestRefresh() {
        try? Data().write(to: directory.appendingPathComponent(".refresh"))
    }
}
