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

    // MARK: - 小组件沙盒注入通道（v0.4.2，App Group 未分配时的实际通道）
    //
    //  背景（2026-10-04 用户截图实锤）：TrollStore/roothide 下系统不给本签名
    //  分配 App Group 容器（containerURL 返回 nil）→ 官方跨进程通道全灭。
    //  但宿主 App 是 root，可以反向把数据写进 **小组件 extension 自己的数据容器**
    //  （/var/mobile/Containers/Data/PluginKitExtension/<UUID>/Library/MG7Share/）。
    //  extension 读自己的容器永远放行，无需任何 entitlement。

    /// 小组件 extension 的 bundle id（容器元数据里按它匹配）
    static let widgetBundleID = "com.banliren.mg7widget.widget"

    /// 当前进程是否为小组件 extension（appex 结尾）
    static var isExtension: Bool {
        Bundle.main.bundlePath.hasSuffix(".appex")
    }

    private static var cachedWidgetContainer: URL?

    /// 定位小组件的数据容器：扫 PluginKitExtension 容器元数据。
    /// 用「描述串包含 bundle id」来匹配，不依赖元数据 plist 的具体 key 名。
    static func widgetContainerURL() -> URL? {
        if let hit = cachedWidgetContainer,
           FileManager.default.fileExists(atPath: hit.path) { return hit }
        let fm = FileManager.default
        for base in ["/var/mobile/Containers/Data/PluginKitExtension",
                     "/var/mobile/Containers/Data/PluginKitPlugin"] {
            guard let entries = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for e in entries {
                let meta = base + "/" + e + "/.com.apple.containermanagerd.metadata.plist"
                guard let data = fm.contents(atPath: meta),
                      let obj = try? PropertyListSerialization.propertyList(
                          from: data, options: [], format: nil)
                else { continue }
                if String(describing: obj).contains(widgetBundleID) {
                    let u = URL(fileURLWithPath: base + "/" + e)
                    cachedWidgetContainer = u
                    return u
                }
            }
        }
        return nil
    }

    /// mobile 用户的 uid（写入文件后 chown，保证小组件进程可覆盖写）
    private static var mobileUID: Int {
        if let a = try? FileManager.default.attributesOfItem(atPath: "/var/mobile"),
           let u = a[.ownerAccountID] as? Int { return u }
        return 501
    }

    /// root 写完的文件要归还给 mobile，否则小组件进程无法覆盖写
    private static func fixOwner(_ path: String) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        let uid = mobileUID
        try? fm.setAttributes([.ownerAccountID: uid, .groupOwnerAccountID: uid],
                              ofItemAtPath: path)
    }

    /// 把配置/快照注入小组件沙盒。仅宿主 App（root）调用有意义。
    /// @return 状态文案（诊断用）
    @discardableResult
    static func pushToWidgetContainer(config: Config?, snapshot: VehicleSnapshot?) -> String {
        guard !isExtension else { return "—（小组件进程内不可注入）" }
        let fm = FileManager.default
        guard let c = widgetContainerURL() else {
            cachedWidgetContainer = nil
            return "❌ 未找到小组件容器"
        }
        let share = c.appendingPathComponent("Library/MG7Share", isDirectory: true)
        try? fm.createDirectory(at: share, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: share.path)
        var ok = false
        if let cfg = config, let data = try? PropertyListEncoder().encode(cfg) {
            let f = share.appendingPathComponent("config.plist")
            if (try? data.write(to: f, options: .atomic)) != nil {
                fixOwner(f.path); ok = true
            }
        }
        if let snap = snapshot {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(snap) {
                let f = share.appendingPathComponent("snapshot.json")
                if (try? data.write(to: f, options: .atomic)) != nil {
                    fixOwner(f.path); ok = true
                }
            }
        }
        return ok ? "✅ 已注入" : "⚠️ 注入失败(权限?)"
    }

    /// 诊断文案（设置页「小组件数据注入」行）——区分失败原因，便于远程定位
    static func pushStatusText() -> String {
        guard !isExtension else { return "—" }
        if let c = widgetContainerURL() {
            let f = c.appendingPathComponent("Library/MG7Share/snapshot.json").path
            if FileManager.default.fileExists(atPath: f) { return "✅ 已注入" }
            return "⚠️ 已定位,待刷新"
        }
        // 区分：目录都不可达（沙盒挡住）vs 可达但没匹配到小组件容器
        let fm = FileManager.default
        let a = try? fm.contentsOfDirectory(atPath: "/var/mobile/Containers/Data/PluginKitExtension")
        let b = try? fm.contentsOfDirectory(atPath: "/var/mobile/Containers/Data/PluginKitPlugin")
        if a == nil && b == nil { return "❌ 目录不可达(沙盒?)" }
        let n = (a?.count ?? 0) + (b?.count ?? 0)
        return "❌ 扫了\(n)个容器未匹配"
    }

    /// 本进程容器里的注入文件路径（小组件侧读这里；App 侧同名路径不存在，天然空读）
    private static var ownShareConfigURL: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("MG7Share/config.plist")
    }
    private static var ownShareSnapshotURL: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("MG7Share/snapshot.json")
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
        /// 车辆坐标是否为 GCJ-02 火星坐标。
        /// ⚠️ 2026-10-04 实测定论：MG 后台返回 **WGS-84（GPS 原始值）**，此开关应保持关闭！
        /// 依据：官方 App 定位「盈丰中路35号」 vs 我们 v0.4.2 显示「南洲北路751号」，
        /// 偏差 1256m ≈ 2×广州典型 GCJ 偏移(623m)——说明坐标被多转/漏转了一个 Δ。
        /// v0.4.2 之前默认 true 是误判（SAIC 坐标当 GCJ 处理导致双重偏移）。
        var coordsAreGCJ02: Bool = false
        /// 一次性迁移标记：v0.4.3 起坐标结论反转，旧配置里的 true 需重置
        var coordFixV3: Bool = false
        /// 控车用的阿里云 MQTT 设备 ID（从 MG Live 抓包 mqttpublish 请求取，留空用内置默认）
        var aliClientId: String = ""
        /// 是否在主界面显示控车面板（v0.4.4 起默认隐藏；控车未验证通过，用户要求可删）
        var showControl: Bool = false

        var isValid: Bool {
            !accessToken.isEmpty && vin.count == 17
        }

        // ⚠️ v0.4.4 关键修复：自定义容错解码。
        // synthesized Codable 遇到旧版本数据缺新字段时会**整条抛 DecodingError**，
        // 导致所有存储通道解码全失败 → loadConfig 返回空配置 → token 全丢、每次升级都要重填！
        // （v0.4.2 加 amapKey、v0.4.3 加 coordFixV3 时都踩过）
        // 全字段 decodeIfPresent + 默认值后，新版本永远能读旧数据。
        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken   = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
            vin           = try c.decodeIfPresent(String.self, forKey: .vin) ?? ""
            userId        = try c.decodeIfPresent(String.self, forKey: .userId) ?? ""
            carName       = try c.decodeIfPresent(String.self, forKey: .carName) ?? "我的 MG7"
            plateNumber   = try c.decodeIfPresent(String.self, forKey: .plateNumber) ?? ""
            fuelCapacity  = try c.decodeIfPresent(Double.self, forKey: .fuelCapacity) ?? 65.0
            autoRefresh   = try c.decodeIfPresent(Bool.self, forKey: .autoRefresh) ?? true
            lastTokenSync = try c.decodeIfPresent(Date.self, forKey: .lastTokenSync) ?? .distantPast
            amapKey       = try c.decodeIfPresent(String.self, forKey: .amapKey) ?? ""
            coordsAreGCJ02 = try c.decodeIfPresent(Bool.self, forKey: .coordsAreGCJ02) ?? false
            coordFixV3    = try c.decodeIfPresent(Bool.self, forKey: .coordFixV3) ?? false
            aliClientId   = try c.decodeIfPresent(String.self, forKey: .aliClientId) ?? ""
            showControl   = try c.decodeIfPresent(Bool.self, forKey: .showControl) ?? false
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
        // ④ App(root)：注入小组件沙盒（配置变了小组件要能立刻读到，v0.4.2）
        if !isExtension {
            pushToWidgetContainer(config: c, snapshot: nil)
        }
    }

    static func loadConfig() -> Config {
        // 优先级：
        // ① 本容器注入文件（小组件进程读宿主 App(root) 写进来的；App 进程同名路径不存在，空读）
        // ② UserDefaults suite → ③ group 容器文件 → ④ 旧固定路径
        for url in [ownShareConfigURL] {
            if let data = try? Data(contentsOf: url),
               var c = try? PropertyListDecoder().decode(Config.self, from: data) {
                migrateCoords(&c)
                return c
            }
        }
        if let d = sharedDefaults, let json = d.data(forKey: "config"),
           var c = try? JSONDecoder().decode(Config.self, from: json) {
            migrateCoords(&c)
            return c
        }
        if let dir = groupDirectory,
           let data = try? Data(contentsOf: dir.appendingPathComponent("config.plist")),
           var c = try? PropertyListDecoder().decode(Config.self, from: data) {
            migrateCoords(&c)
            return c
        }
        if let data = try? Data(contentsOf: configURL),
           var c = try? PropertyListDecoder().decode(Config.self, from: data) {
            migrateCoords(&c)
            return c
        }
        return Config()
    }

    /// v0.4.3 一次性迁移：坐标结论反转（实测 SAIC=WGS-84），
    /// 把旧配置里的 coordsAreGCJ02=true 重置为 false（只做一次，尊重之后的手动改动）
    private static func migrateCoords(_ c: inout Config) {
        guard !c.coordFixV3 else { return }
        c.coordsAreGCJ02 = false
        c.coordFixV3 = true
        saveConfig(c)
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

        // ④ App(root)：注入小组件沙盒（App Group 未分配时的实际通道，v0.4.2）
        if !isExtension {
            pushToWidgetContainer(config: nil, snapshot: s)
        }
    }

    static func loadSnapshot() -> VehicleSnapshot? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        // 优先级：
        // ① 本容器注入文件（App 推来的；小组件进程内是宿主写的，App 进程内空读）
        // ② group 容器文件 → ③ UserDefaults → ④ 旧固定路径
        if let data = try? Data(contentsOf: ownShareSnapshotURL),
           let s = try? dec.decode(VehicleSnapshot.self, from: data) {
            return s
        }
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
