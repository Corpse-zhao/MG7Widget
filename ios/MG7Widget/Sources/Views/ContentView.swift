//
//  ContentView.swift
//  MG7Widget
//
//  主界面：车况总览 + 控车
//

import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var vm: CarViewModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    if let e = vm.errorMessage { errorBanner(e) }
                    if let s = vm.snapshot {
                        rangeRow(s)
                        tyreCard(s)
                        healthCard(s)
                        statusCard(s)
                        locationCard(s)
                    } else {
                        emptyState
                    }
                    ControlPanel(vm: vm)
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            // ✅ 下拉刷新必须挂在 ScrollView 上；挂在 NavigationView 外层在
            //    navigationBarHidden 的 iOS 16 环境里不生效。
            .refreshable { await vm.refresh() }
            .background(Color(red: 0.96, green: 0.96, blue: 0.97).ignoresSafeArea())
            .navigationBarHidden(true)
            .overlay(alignment: .top) { refreshBanner }
            .sheet(isPresented: $vm.showingSettings) {
                SettingsView(vm: vm)
            }
        }
        .navigationViewStyle(.stack)
    }

    /// 刷新中的顶部提示条（下拉刷新时给用户可见反馈）
    @ViewBuilder
    private var refreshBanner: some View {
        if vm.isLoading {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("正在获取车况…").font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(MGTheme.orange)
            .clipShape(Capsule())
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: 顶部

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.config.carName.isEmpty ? "我的 MG7" : vm.config.carName)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(.white)
                    Text(vm.config.vin.isEmpty ? "未绑定车辆" : vm.config.vin)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer()
                Button { vm.showingSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.22))
                        .clipShape(Circle())
                }
            }
            HStack(spacing: 14) {
                Label(lockText, systemImage: lockIcon)
                Spacer()
                Text("更新 \(vm.lastRefreshText)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.95))
        }
        .padding(18)
        .background(MGTheme.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 6)
    }

    private var lockText: String {
        guard let s = vm.snapshot else { return "—" }
        if s.doorOpen == true || s.windowOpen == true { return "门窗未关" }
        return (s.isLocked ?? false) ? "已锁车" : "未锁车"
    }
    private var lockIcon: String {
        guard let s = vm.snapshot else { return "questionmark.circle" }
        if s.doorOpen == true || s.windowOpen == true { return "exclamationmark.triangle.fill" }
        return (s.isLocked ?? false) ? "lock.fill" : "lock.open.fill"
    }

    // MARK: 错误横幅（醒目显示，失败原因一眼可见）

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(msg).font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.leading)
                if msg.contains("token") {
                    Button { vm.showingSettings = true } label: {
                        Text("去更新 token")
                            .font(.system(size: 12, weight: .bold))
                            .underline()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(MGTheme.danger)
        .padding(12)
        .background(MGTheme.danger.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 续航 + 油量

    private func rangeRow(_ s: VehicleSnapshot) -> some View {
        MG7Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("续航").font(.system(size: 13, weight: .semibold))
                        .foregroundColor(MGTheme.textSecondary)
                    Spacer()
                    if s.isFuelLow {
                        Text("油量告急").font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(MGTheme.danger)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 8) {
                    StatTile(title: "可用续航",
                             value: fmt(s.rangeKm), unit: "km",
                             accent: MGTheme.orange)
                    StatTile(title: "油量",
                             value: fmt(s.fuelPercent, 0), unit: "%",
                             accent: s.isFuelLow ? MGTheme.danger : MGTheme.textPrimary,
                             warning: s.isFuelLow)
                    StatTile(title: "油续航",
                             value: fmt(s.fuelRangeKm), unit: "km",
                             accent: MGTheme.textPrimary)
                }
            }
        }
    }

    // MARK: 胎压

    private func tyreCard(_ s: VehicleSnapshot) -> some View {
        MG7Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("胎压 (kPa)").font(.system(size: 13, weight: .semibold))
                        .foregroundColor(MGTheme.textSecondary)
                    Spacer()
                    if !s.lowTyres.isEmpty {
                        Text("\(s.lowTyres.joined(separator: "/")) 偏低")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(MGTheme.danger)
                    }
                }
                HStack(spacing: 0) {
                    tyreItem("左前", s.tyreFrontLeft)
                    Divider().frame(height: 34)
                    tyreItem("右前", s.tyreFrontRight)
                    Divider().frame(height: 34)
                    tyreItem("左后", s.tyreRearLeft)
                    Divider().frame(height: 34)
                    tyreItem("右后", s.tyreRearRight)
                }
            }
        }
    }

    private func tyreItem(_ label: String, _ v: Double?) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundColor(MGTheme.textSecondary)
            Text(v.map { String(Int($0)) } ?? "—")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor((v ?? 999) < 220 ? MGTheme.danger : MGTheme.tyreBlue)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 健康

    private func healthCard(_ s: VehicleSnapshot) -> some View {
        MG7Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("健康").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(MGTheme.textSecondary)
                HStack(spacing: 8) {
                    StatTile(title: "12V 电瓶",
                             value: s.battery12V.map { String(format: "%.1f", $0) } ?? "—",
                             unit: "V",
                             accent: (s.battery12V ?? 99) < 12.0 ? MGTheme.danger : MGTheme.success,
                             warning: (s.battery12V ?? 99) < 12.0)
                    StatTile(title: "总里程",
                             value: s.odometerKm.map { fmtGrouped($0) } ?? "—",
                             unit: "km", accent: MGTheme.textPrimary)
                    StatTile(title: "车内温度",
                             value: fmt(s.cabinTempC, 0), unit: "℃",
                             accent: MGTheme.textPrimary)
                }
            }
        }
    }

    // MARK: 状态

    private func statusCard(_ s: VehicleSnapshot) -> some View {
        MG7Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("状态").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(MGTheme.textSecondary)
                let items: [(String, Bool)] = [
                    ("车门", s.doorOpen ?? false),
                    ("车窗", s.windowOpen ?? false),
                    ("天窗", s.sunroofOpen ?? false),
                    ("后备箱", s.bootOpen ?? false),
                    ("引擎盖", s.bonnetOpen ?? false),
                    ("空调", s.climateOn ?? false),
                    ("发动机", s.engineRunning ?? false),
                ]
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4),
                          spacing: 10) {
                    ForEach(items, id: \.0) { name, on in
                        VStack(spacing: 4) {
                            Image(systemName: on ? "circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundColor(on ? MGTheme.orange : Color(red: 0.80, green: 0.82, blue: 0.86))
                            Text(name).font(.system(size: 11))
                                .foregroundColor(MGTheme.textSecondary)
                        }
                    }
                }
                Text("灰色=正常关闭 · 橙色=开启/运行")
                    .font(.system(size: 10)).foregroundColor(MGTheme.textSecondary)
            }
        }
    }

    // MARK: 位置

    private func locationCard(_ s: VehicleSnapshot) -> some View {
        MG7Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("位置").font(.system(size: 13, weight: .semibold))
                        .foregroundColor(MGTheme.textSecondary)
                    Spacer()
                    if let g = s.gpsStatus, g >= 2 {
                        Label("已定位", systemImage: "location.fill")
                            .font(.system(size: 11)).foregroundColor(MGTheme.success)
                    }
                }
                if let addr = s.address, !addr.isEmpty {
                    Text(addr).font(.system(size: 14, weight: .medium))
                        .foregroundColor(MGTheme.textPrimary)
                }
                if let lat = s.latitude, let lon = s.longitude {
                    HStack {
                        Text(String(format: "%.6f, %.6f", lat, lon))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(MGTheme.textSecondary)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = String(format: "%.6f,%.6f", lat, lon)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundColor(MGTheme.orange)
                        }
                    }
                    Button {
                        openMaps(lat: lat, lon: lon)
                    } label: {
                        Label("导航到车辆", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(MGTheme.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private func openMaps(lat: Double, lon: Double) {
        // Apple 地图对中国区输入坐标会做一次 WGS→GCJ 纠偏；
        // 车辆坐标本来就是 GCJ-02 → 先转 WGS 传过去，正好抵消，终点落回真实位置
        let p = vm.config.coordsAreGCJ02
            ? CoordTransform.gcj2wgs(lat: lat, lon: lon)
            : (lat: lat, lon: lon)
        let url = URL(string: "http://maps.apple.com/?daddr=\(p.lat),\(p.lon)&dirflg=d")!
        UIApplication.shared.open(url)
    }

    // MARK: 空态 / 页脚

    private var emptyState: some View {
        MG7Card {
            VStack(spacing: 12) {
                Image(systemName: "car.fill")
                    .font(.system(size: 40)).foregroundColor(MGTheme.orange.opacity(0.4))
                Text("尚未获取车况").font(.system(size: 15, weight: .semibold))
                Text("请先在设置中填入 token 与 VIN")
                    .font(.system(size: 12)).foregroundColor(MGTheme.textSecondary)
                Button("去设置") { vm.showingSettings = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .background(MGTheme.orange).clipShape(Capsule())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var footer: some View {
        // 错误已由页首 errorBanner 醒目展示，这里只留版本信息，避免重复
        VStack(spacing: 4) {
            Text("MG7 车况 v\(AppInfo.version) · \(AppInfo.author)")
                .font(.system(size: 10)).foregroundColor(MGTheme.textSecondary)
        }
        .padding(.top, 8)
    }

    // MARK: 工具

    private func fmt(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v = v else { return "—" }
        return digits == 0 ? String(Int(v)) : String(format: "%.\(digits)f", v)
    }
    private func fmtGrouped(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: Int(v))) ?? String(Int(v))
    }
}
