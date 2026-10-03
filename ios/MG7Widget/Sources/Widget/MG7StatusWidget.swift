//
//  MG7StatusWidget.swift
//  MG7WidgetExtension
//
//  MG7 车况小组件：小 / 中 / 大 三种尺寸
//  数据来源：读共享路径 snapshot.json（Widget Extension 不能主动联网）
//

import WidgetKit
import SwiftUI

// MARK: - Timeline

struct MG7Entry: TimelineEntry {
    let date: Date
    let snapshot: VehicleSnapshot?
    let carName: String
}

struct MG7Provider: TimelineProvider {

    func placeholder(in context: Context) -> MG7Entry {
        MG7Entry(date: Date(), snapshot: .mock, carName: "我的 MG7")
    }

    func getSnapshot(in context: Context, completion: @escaping (MG7Entry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MG7Entry>) -> Void) {
        let entry = load()
        // 每 15 分钟尝试刷新（系统会按策略节流）；真实数据更新靠 App 主动 reload
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> MG7Entry {
        let cfg = MG7Store.loadConfig()
        return MG7Entry(date: Date(),
                        snapshot: MG7Store.loadSnapshot(),
                        carName: cfg.carName.isEmpty ? "我的 MG7" : cfg.carName)
    }
}

// MARK: - Widget 定义

struct MG7StatusWidget: Widget {
    let kind = "MG7StatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MG7Provider()) { entry in
            MG7WidgetView(entry: entry)
        }
        .configurationDisplayName("MG7 车况")
        .description("查看续航、油量、胎压、位置与锁车状态")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - 视图分发

struct MG7WidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: MG7Entry

    var body: some View {
        // ⚠️ 背景必须直接贴在最外层 ZStack 上，不要用 Group + if/else 包裹
        //（Group 内的分支会让外层 modifier 作用层级不可靠 → 背景丢失 → 全黑）
        ZStack {
            widgetBackground          // 永远铺满的浅色底（最底层）
            content
        }
        .environment(\.colorScheme, .light)   // 强制浅色，深色模式下也保持可读
        .containerBackgroundCompat(widgetBackground)
    }

    private var widgetBackground: some View {
        LinearGradient(
            colors: [Color.white, Color(red: 0.97, green: 0.97, blue: 0.98)],
            startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:  SmallWidget(entry: entry)
        case .systemMedium: MediumWidget(entry: entry)
        default:            LargeWidget(entry: entry)
        }
    }
}

// MARK: - iOS 17 containerBackground 兼容封装

private extension View {
    @ViewBuilder
    func containerBackgroundCompat<V: View>(_ bg: V) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { bg }
        } else {
            self.background(bg)   // iOS 16：显式背景（本机走这条）
        }
    }
}

// MARK: - 小尺寸

struct SmallWidget: View {
    let entry: MG7Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.carName).font(.system(size: 13, weight: .bold))
                    .foregroundColor(MGTheme.orange)
                    .lineLimit(1)
                Spacer()
                Image(systemName: lockIcon).font(.system(size: 12))
                    .foregroundColor(lockColor)
            }
            Spacer(minLength: 0)
            Text(rangeText)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(MGTheme.orange)
                .minimumScaleFactor(0.6)
            Text("km 可用续航").font(.system(size: 10))
                .foregroundColor(MGTheme.textSecondary)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "fuelpump.fill").font(.system(size: 10))
                Text(fuelText).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(fuelColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MGTheme.widgetBg)          // iOS 16 兜底（无 containerBackground API）
        .widgetURL(nil)
    }

    private var rangeText: String {
        guard let v = entry.snapshot?.rangeKm else { return "—" }
        return String(Int(v))
    }
    private var fuelText: String {
        guard let v = entry.snapshot?.fuelPercent else { return "油量 —" }
        return "油量 \(Int(v))%"
    }
    private var fuelColor: Color {
        (entry.snapshot?.isFuelLow ?? false) ? MGTheme.danger : MGTheme.textSecondary
    }
    private var lockIcon: String {
        (entry.snapshot?.isLocked ?? false) ? "lock.fill" : "lock.open.fill"
    }
    private var lockColor: Color {
        (entry.snapshot?.isLocked ?? false) ? MGTheme.success : MGTheme.danger
    }
}

// MARK: - 中尺寸

struct MediumWidget: View {
    let entry: MG7Entry

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(entry.carName).font(.system(size: 13, weight: .bold))
                    .foregroundColor(MGTheme.orange)
                Spacer()
                Text(staleText).font(.system(size: 10))
                    .foregroundColor(MGTheme.textSecondary)
            }
            HStack(spacing: 0) {
                metric("续航", intVal(entry.snapshot?.rangeKm), "km",
                       accent: MGTheme.orange)
                metric("油量", intVal(entry.snapshot?.fuelPercent), "%",
                       accent: (entry.snapshot?.isFuelLow ?? false) ? MGTheme.danger : MGTheme.textPrimary)
                metric("电瓶",
                       entry.snapshot?.battery12V.map { String(format: "%.1f", $0) } ?? "—", "V",
                       accent: MGTheme.success)
                metric("车内", intVal(entry.snapshot?.cabinTempC), "℃",
                       accent: MGTheme.textPrimary)
            }
            HStack(spacing: 6) {
                statusDot("已锁", entry.snapshot?.isLocked ?? false, invert: true)
                statusDot("空调", entry.snapshot?.climateOn ?? false)
                statusDot("发动机", entry.snapshot?.engineRunning ?? false)
                Spacer()
                Text(addrText).font(.system(size: 10))
                    .foregroundColor(MGTheme.textSecondary).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MGTheme.widgetBg)
    }

    private func metric(_ t: String, _ v: String, _ u: String, accent: Color) -> some View {
        VStack(spacing: 1) {
            Text(t).font(.system(size: 10)).foregroundColor(MGTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(v).font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(accent).minimumScaleFactor(0.6).lineLimit(1)
                Text(u).font(.system(size: 9)).foregroundColor(MGTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statusDot(_ label: String, _ on: Bool, invert: Bool = false) -> some View {
        let active = invert ? on : on
        let color: Color = invert
            ? (on ? MGTheme.success : MGTheme.danger)
            : (on ? MGTheme.orange : Color(red: 0.80, green: 0.82, blue: 0.86))
        return HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10)).foregroundColor(MGTheme.textSecondary)
        }
    }

    private var staleText: String {
        guard let d = entry.snapshot?.fetchedAt, d != .distantPast else { return "无数据" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    private var addrText: String {
        guard let a = entry.snapshot?.address, !a.isEmpty else { return "" }
        return a
    }
    private func intVal(_ v: Double?) -> String {
        guard let v = v else { return "—" }
        return String(Int(v))
    }
}

// MARK: - 大尺寸

struct LargeWidget: View {
    let entry: MG7Entry

    var body: some View {
        // ⚠️ systemLarge 高度有限，内容过多会被压缩到渲染失败（表现为整块黑）。
        // 策略：紧凑间距 + minimumScaleFactor + 不用会抢空间的 Spacer + 全部可省略。
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.carName).font(.system(size: 14, weight: .bold))
                    .foregroundColor(MGTheme.orange).lineLimit(1)
                Spacer(minLength: 4)
                if entry.snapshot == nil {
                    Text("待刷新").font(.system(size: 9))
                        .foregroundColor(MGTheme.orange)
                } else {
                    Text(vinText).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(MGTheme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                bigMetric("可用续航", intVal(entry.snapshot?.rangeKm), "km", MGTheme.orange)
                bigMetric("油量", intVal(entry.snapshot?.fuelPercent), "%",
                          (entry.snapshot?.isFuelLow ?? false) ? MGTheme.danger : MGTheme.textPrimary)
            }

            // 胎压
            VStack(alignment: .leading, spacing: 4) {
                Text("胎压 kPa").font(.system(size: 9)).foregroundColor(MGTheme.textSecondary)
                HStack(spacing: 0) {
                    tyre("左前", entry.snapshot?.tyreFrontLeft)
                    tyre("右前", entry.snapshot?.tyreFrontRight)
                    tyre("左后", entry.snapshot?.tyreRearLeft)
                    tyre("右后", entry.snapshot?.tyreRearRight)
                }
            }

            // 健康
            HStack(spacing: 8) {
                smallMetric("电瓶", entry.snapshot?.battery12V.map { String(format: "%.1f V", $0) } ?? "—")
                smallMetric("里程", entry.snapshot?.odometerKm.map { "\(Int($0)) km" } ?? "—")
                smallMetric("车内", entry.snapshot?.cabinTempC.map { "\(Int($0)) ℃" } ?? "—")
            }

            // 状态
            HStack(spacing: 8) {
                chip("已锁", entry.snapshot?.isLocked ?? false, success: true)
                chip("门窗关", !(entry.snapshot?.doorOpen ?? false) && !(entry.snapshot?.windowOpen ?? false), success: true)
                chip("空调", entry.snapshot?.climateOn ?? false, success: false)
                Spacer(minLength: 0)
            }

            if let addr = entry.snapshot?.address, !addr.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 10))
                        .foregroundColor(MGTheme.orange)
                    Text(addr).font(.system(size: 10))
                        .foregroundColor(MGTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MGTheme.widgetBg)
    }

    private func bigMetric(_ t: String, _ v: String, _ u: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.system(size: 10)).foregroundColor(MGTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v).font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(c).minimumScaleFactor(0.6).lineLimit(1)
                Text(u).font(.system(size: 11)).foregroundColor(MGTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(MGTheme.orangeBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func tyre(_ l: String, _ v: Double?) -> some View {
        VStack(spacing: 1) {
            Text(l).font(.system(size: 9)).foregroundColor(MGTheme.textSecondary)
            Text(v.map { String(Int($0)) } ?? "—")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor((v ?? 999) < 220 ? MGTheme.danger : MGTheme.tyreBlue)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func smallMetric(_ t: String, _ v: String) -> some View {
        VStack(spacing: 1) {
            Text(t).font(.system(size: 9)).foregroundColor(MGTheme.textSecondary)
            Text(v).font(.system(size: 12, weight: .semibold))
                .foregroundColor(MGTheme.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(MGTheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func chip(_ t: String, _ on: Bool, success: Bool) -> some View {
        let c: Color = success ? (on ? MGTheme.success : MGTheme.danger)
                               : (on ? MGTheme.orange : Color(red: 0.80, green: 0.82, blue: 0.86))
        return HStack(spacing: 3) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(t).font(.system(size: 10)).foregroundColor(MGTheme.textSecondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(MGTheme.cardBg).clipShape(Capsule())
    }

    private var vinText: String {
        guard let v = entry.snapshot?.vin, v.count == 17 else { return "" }
        return "…" + v.suffix(6)
    }
    private func intVal(_ v: Double?) -> String {
        guard let v = v else { return "—" }
        return String(Int(v))
    }
}

// MARK: - Mock（占位/预览用）

extension VehicleSnapshot {
    static var mock: VehicleSnapshot {
        var s = VehicleSnapshot(vin: "LSJWJ4W90SZ187922", fetchedAt: Date())
        s.rangeKm = 64; s.fuelPercent = 9; s.fuelRangeKm = 64
        s.isLocked = true; s.cabinTempC = 32; s.outsideTempC = 30
        s.odometerKm = 8994
        s.tyreFrontLeft = 252; s.tyreFrontRight = 248
        s.tyreRearLeft = 240; s.tyreRearRight = 244
        s.battery12V = 11.9
        s.doorOpen = false; s.windowOpen = false; s.sunroofOpen = false
        s.climateOn = false; s.engineRunning = false
        s.address = "广东省广州市"
        return s
    }
}
