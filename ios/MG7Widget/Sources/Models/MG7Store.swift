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

    /// 共享目录。越狱环境用固定路径，否则回退沙盒。
    static var directory: URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: "/var/mobile/Library") {
            let u = URL(fileURLWithPath: jailDir)
            if !fm.fileExists(atPath: jailDir) {
                try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            }
            // 验证可写，不可写则回退
            let probe = u.appendingPathComponent(".probe")
            if fm.createFile(atPath: probe.path, contents: Data()) {
                try? fm.removeItem(at: probe)
                return u
            }
        }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
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

        var isValid: Bool {
            !accessToken.isEmpty && vin.count == 17
        }
    }

    static func saveConfig(_ c: Config) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .xml
        guard let data = try? enc.encode(c) else { return }
        try? data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configURL.path)
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
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: snapshotURL.path)
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
