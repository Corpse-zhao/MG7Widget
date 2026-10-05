//
//  Diagnostics.swift
//  MG7Widget
//
//  一次性诊断（v0.4.19）：把「小组件数据注入失败」的真实原因抓回来看。
//
//  背景：v0.4.18 已把 entitlements（no-sandbox / application-groups / 路径例外）
//  用 ldid 嵌进二进制（并剥离了 iOS 会拒的 DER slot），App 能正常启动，
//  但设置页仍显示「❌ 目录不可达(沙盒?)」「App Group ❌ 未分配」
//  → 说明 App 在**运行时**其实是带沙盒的，entitlements 没生效。
//
//  本诊断要回答三个问题：
//   ① 安装后（TrollStore 重签之后）二进制里**实际**残留了哪些 entitlements？
//      —— 直接读自身 Mach-O 的 LC_CODE_SIGNATURE，dump slot5(XML) / slot7(DER)。
//         这不依赖任何权限（读自己 bundle 永远放行）。
//   ② 进程到底是不是沙盒态？
//      —— 用 access()/opendir() 的 errno 区分 EACCES(沙盒挡) vs ENOENT(路径不存在)。
//   ③ /var/mobile/Library/MG7Widget/ 能不能写？小组件容器扫得到吗？
//
//  输出统一走 Diagnostics.fullReport()，设置页「诊断」区展示 + 一键复制。
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum Diagnostics {

    // MARK: - 总入口

    static func fullReport() -> String {
        var out: [String] = []

        out.append("===== MG7Widget 诊断 v\(AppInfo.version) =====")
        out.append("时间: \(stamp())")

        out.append("")
        out.append("-- 进程 --")
        out.append("uid=\(getuid()) euid=\(geteuid())")
        out.append("home=\(NSHomeDirectory())")
        out.append("bundle=\(Bundle.main.bundlePath)")
        let grp = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MG7Store.appGroupID)?.path
        out.append("groupContainer=\(grp ?? "nil")")

        out.append("")
        out.append("-- 主 App 二进制 entitlements（安装后实际残留）--")
        out.append(contentsOf: binaryEntitlements(path: Bundle.main.executablePath ?? ""))

        out.append("")
        out.append("-- 小组件 appex entitlements（安装后实际残留）--")
        out.append(contentsOf: binaryEntitlements(path: widgetExecutablePath()))

        out.append("")
        out.append("-- 路径可达性（access/F_OK、R_OK；ls=opendir 结果）--")
        for p in probePaths { out.append(probe(p)) }

        out.append("")
        out.append("-- /var/mobile/Library/MG7Widget 写入测试 --")
        out.append(contentsOf: writeTest())

        out.append("")
        out.append("-- 小组件容器扫描 --")
        out.append(contentsOf: containerScan())

        out.append("")
        out.append("-- 本 App 容器元数据 --")
        out.append(contentsOf: ownContainerMeta())

        return out.joined(separator: "\n")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - errno 文案

    private static func errnoText(_ e: Int32) -> String {
        switch e {
        case 0:      return "OK"
        case EACCES: return "EACCES(权限拒绝/沙盒挡)"
        case EPERM:  return "EPERM(不允许)"
        case ENOENT: return "ENOENT(不存在)"
        case ENOTDIR:return "ENOTDIR(不是目录)"
        default:     return "errno=\(e)"
        }
    }

    // MARK: - 路径探测

    private static let probePaths = [
        "/",
        "/var",
        "/var/mobile",
        "/var/mobile/Library",
        "/var/mobile/Library/MG7Widget",
        "/var/mobile/Containers",
        "/var/mobile/Containers/Data",
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Data/PluginKitExtension",
        "/var/mobile/Containers/Data/PluginKitPlugin",
        "/var/containers/Bundle/Application",
        "/private/var/mobile/Containers/Data/PluginKitExtension",
    ]

    private static func probe(_ p: String) -> String {
        var parts: [String] = []

        errno = 0
        let f = access(p, F_OK)
        let fe = errno
        parts.append("F_OK=\(f == 0 ? "OK" : errnoText(fe))")

        errno = 0
        let r = access(p, R_OK)
        let re = errno
        parts.append("R_OK=\(r == 0 ? "OK" : errnoText(re))")

        errno = 0
        if let dp = opendir(p) {
            closedir(dp)
            let n = (try? FileManager.default.contentsOfDirectory(atPath: p))?.count ?? -1
            parts.append("ls=OK(\(n))")
        } else {
            parts.append("ls=ERR \(errnoText(errno))")
        }

        return "\(p)\n    " + parts.joined(separator: "  ")
    }

    // MARK: - 写入测试

    private static func writeTest() -> [String] {
        var out: [String] = []
        let dir = "/var/mobile/Library/MG7Widget"

        errno = 0
        let mk = mkdir(dir, 0o755)
        if mk == 0 {
            out.append("mkdir \(dir): OK")
        } else if errno == EEXIST {
            out.append("mkdir \(dir): 已存在")
        } else {
            out.append("mkdir \(dir): FAIL \(errnoText(errno))")
        }

        let file = dir + "/diagnostics.txt"
        errno = 0
        let ok = FileManager.default.createFile(
            atPath: file, contents: Data("diag \(stamp())\n".utf8), attributes: nil)
        if ok {
            out.append("write \(file): OK")
        } else {
            out.append("write \(file): FAIL \(errnoText(errno))")
        }
        return out
    }

    // MARK: - 小组件容器扫描

    private static func containerScan() -> [String] {
        var out: [String] = []
        let bases = [
            "/var/mobile/Containers/Data/PluginKitExtension",
            "/var/mobile/Containers/Data/PluginKitPlugin",
        ]
        for base in bases {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else {
                out.append("\(base): 列不出（见上面路径探测的 errno）")
                continue
            }
            let names = entries.filter { !$0.hasPrefix(".") }
            out.append("\(base): \(names.count) 个条目")

            for name in names.prefix(8) {
                let dir = base + "/" + name
                var ident = "?"
                for meta in [".com.apple.containermanagerd.metadata.plist",
                             ".com.apple.mobile_container_manager.metadata.plist"] {
                    let mp = dir + "/" + meta
                    if let d = try? Data(contentsOf: URL(fileURLWithPath: mp)),
                       let pl = try? PropertyListSerialization.propertyList(
                           from: d, options: [], format: nil) {
                        ident = String(describing: pl)
                            .replacingOccurrences(of: "\n", with: " ")
                        break
                    }
                }
                out.append("  · \(String(name.prefix(8)))…  \(String(ident.prefix(200)))")
            }
        }
        return out
    }

    // MARK: - 自身容器元数据

    private static func ownContainerMeta() -> [String] {
        var out: [String] = []
        let home = NSHomeDirectory()
        let meta = home + "/.com.apple.mobile_container_manager.metadata.plist"
        if let d = try? Data(contentsOf: URL(fileURLWithPath: meta)),
           let pl = try? PropertyListSerialization.propertyList(
               from: d, options: [], format: nil) {
            out.append("home 元数据: \(pl)")
        } else {
            out.append("home 元数据: 读不到（\(NSHomeDirectory())）")
        }
        // 容器目录本身（Application/<UUID>）
        let container = (home as NSString).deletingLastPathComponent
        out.append("container=\(container)")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: container)) ?? []
        out.append("container 内容: \(items.sorted().joined(separator: " "))")
        return out
    }

    // MARK: - Mach-O entitlements dump

    /// 小组件 appex 可执行文件路径（App bundle 内的 PlugIns/，读自己 bundle 永远放行）
    private static func widgetExecutablePath() -> String {
        let plugins = Bundle.main.bundlePath + "/PlugIns"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: plugins) else {
            return ""
        }
        for it in items where it.hasSuffix(".appex") {
            let dir = plugins + "/" + it
            if let d = try? Data(contentsOf: URL(fileURLWithPath: dir + "/Info.plist")),
               let pl = try? PropertyListSerialization.propertyList(
                   from: d, options: [], format: nil) as? [String: Any],
               let exe = pl["CFBundleExecutable"] as? String {
                return dir + "/" + exe
            }
        }
        return ""
    }

    private static func binaryEntitlements(path: String) -> [String] {
        guard !path.isEmpty else { return ["（路径为空）"] }
        var out: [String] = ["file=\((path as NSString).lastPathComponent)"]
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), !d.isEmpty else {
            out.append("  读取失败: \(path)")
            return out
        }
        out.append("  size=\(d.count)")

        guard let (sigOff, sigSize) = findCodeSignature(d) else {
            out.append("  未找到 LC_CODE_SIGNATURE（无签名 blob）")
            return out
        }
        out.append("  签名区 offset=\(sigOff) size=\(sigSize)")

        guard let magic = u32be(d, sigOff), magic == 0xFADE0CC0 else {
            out.append("  superblob magic 异常: \(u32be(d, sigOff).map { String(format: "0x%08X", $0) } ?? "nil")")
            return out
        }
        guard let count = u32be(d, sigOff + 8) else {
            out.append("  superblob 不可解析")
            return out
        }
        out.append("  slot 数=\(count)")

        for i in 0..<Int(count) {
            let e = sigOff + 12 + i * 8
            guard let t = u32be(d, e), let o = u32be(d, e + 4) else { continue }
            let b = sigOff + Int(o)
            guard let bm = u32be(d, b), let bl = u32be(d, b + 4) else {
                out.append("  slot type=\(t) 头不可读")
                continue
            }
            let start = b + 8
            let end = min(b + Int(bl), sigOff + sigSize)
            let payload = (end > start) ? d.subdata(in: start..<end) : Data()
            let tag = String(format: "0x%08X", bm)
            switch t {
            case 5:
                out.append("  slot5 XML entitlements (\(payload.count)B, magic \(tag)):")
                out.append(payloadString(payload))
            case 7:
                out.append("  slot7 DER entitlements (\(payload.count)B, magic \(tag)) [存在]")
            default:
                out.append("  slot\(t) (\(payload.count)B, magic \(tag))")
            }
        }
        if count <= 3 {
            out.append("  提示: 无 slot7(DER)，仅 XML —— 若 TrollStore 只认 DER 就会丢权限")
        }
        return out
    }

    private static func payloadString(_ d: Data) -> String {
        guard let s = String(data: d, encoding: .utf8) else { return "    <非 UTF-8>" }
        return s.split(separator: "\n").map { "    " + String($0) }.joined(separator: "\n")
    }

    // MARK: - 二进制小工具

    private static func u32be(_ d: Data, _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        return UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16
             | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }

    private static func u32le(_ d: Data, _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8
             | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    /// 定位 (code signature dataoff, datasize)；兼容 thin(arm64) 与 fat
    private static func findCodeSignature(_ d: Data) -> (Int, Int)? {
        guard let magicBE = u32be(d, 0) else { return nil }
        if magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF {
            guard let n = u32be(d, 4) else { return nil }
            for i in 0..<Int(n) {
                let entOff = 8 + i * 20
                // fat_arch64 用 4 字节 offset+size（与 fat_arch 同为 20B 项）
                guard let off = u32be(d, entOff + 8) else { continue }
                if let r = thinSig(d, Int(off)) { return r }
            }
            return nil
        }
        return thinSig(d, 0)
    }

    private static func thinSig(_ d: Data, _ base: Int) -> (Int, Int)? {
        let magic = u32le(d, base) ?? 0
        let is64 = (magic == 0xFEEDFACF)
        guard is64 || magic == 0xFEEDFACE else { return nil }
        guard let ncmds = u32le(d, base + 16) else { return nil }
        var p = base + (is64 ? 32 : 28)
        for _ in 0..<Int(ncmds) {
            guard let cmd = u32le(d, p), let cmdsize = u32le(d, p + 4), cmdsize > 0 else { return nil }
            if cmd == 0x1D { // LC_CODE_SIGNATURE
                guard let dataoff = u32le(d, p + 8), let datasize = u32le(d, p + 12) else { return nil }
                return (base + Int(dataoff), Int(datasize))
            }
            p += Int(cmdsize)
        }
        return nil
    }
}
