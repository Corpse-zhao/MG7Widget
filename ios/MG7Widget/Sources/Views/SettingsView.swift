//
//  SettingsView.swift
//  MG7Widget
//
//  设置页：token / VIN 填写（开发期手填，P3 后由 MGHelper 自动同步）
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: CarViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var vin = ""
    @State private var userId = ""
    @State private var carName = ""
    @State private var plate = ""
    @State private var amapKey = ""
    @State private var coordsGCJ = true
    @State private var aliClientId = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("access_token（-prod_SAIC 结尾）", text: $token)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("登录凭证")
                } footer: {
                    Text("从 MG Live 抓包获取。打开 MG Live 刷新车况后，在抓包工具里找 mp.ebanma.com 请求头中的 token。")
                }

                Section {
                    TextField("17 位 VIN（LSJ 开头）", text: $vin)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                    TextField("user_id（可选，控车用）", text: $userId)
                        .font(.system(size: 12, design: .monospaced))
                        .keyboardType(.numberPad)
                    TextField("aliClientId（控车用，见下方说明）", text: $aliClientId)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("车辆信息 / 控车参数")
                } footer: {
                    Text("aliClientId：抓包 MG Live 点一次锁车/解锁，找 mp.ebanma.com/app-mp/mqttpublish 请求，URL 里 data 参数解码后的 aliClientId 字段（形如 GID_ios_mg@@@XXXX）。填你自己手机上抓到的，指令才能推到你车机。")
                }

                Section {
                    TextField("车辆昵称", text: $carName)
                    TextField("车牌号", text: $plate)
                } header: {
                    Text("展示信息")
                }

                Section {
                    TextField("高德 Web 服务 key（可选）", text: $amapKey)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Toggle(isOn: $coordsGCJ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("车辆坐标为火星坐标 (GCJ-02)")
                            Text("实测 MG7 后台返回 WGS-84（GPS 原始值），请保持关闭；v0.4.2 前误判开启导致偏 1.2km")
                                .font(.system(size: 10))
                                .foregroundColor(MGTheme.textSecondary)
                        }
                    }
                } header: {
                    Text("定位精度")
                } footer: {
                    Text("填了高德 key 后，地址会精确到街道门牌（推荐）。申请：lbs.amap.com → 控制台 → 应用管理 → 创建应用 → 添加 Key → 服务平台选「Web服务」。留空则用 iOS 系统定位，只到 POI/街道级。")
                }

                Section {
                    Button {
                        vm.saveToken(token, vin: vin, userId: userId)
                        var c = vm.config
                        c.carName = carName.isEmpty ? "我的 MG7" : carName
                        c.plateNumber = plate
                        c.amapKey = amapKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        c.coordsAreGCJ02 = coordsGCJ
                        c.aliClientId = aliClientId.trimmingCharacters(in: .whitespacesAndNewlines)
                        vm.updateConfig(c)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("保存并刷新").font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                    }
                    .listRowBackground(MGTheme.orange)
                    .foregroundColor(.white)
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("v\(AppInfo.version)").foregroundColor(MGTheme.textSecondary)
                    }
                    HStack {
                        Text("作者")
                        Spacer()
                        Text(AppInfo.author).foregroundColor(MGTheme.textSecondary)
                    }
                    HStack {
                        Text("小组件数据注入")
                        Spacer()
                        Text(MG7Store.pushStatusText()).foregroundColor(MGTheme.textSecondary)
                            .font(.system(size: 12))
                    }
                    HStack {
                        Text("App Group 容器")
                        Spacer()
                        Text(groupStatusText).foregroundColor(MGTheme.textSecondary)
                            .font(.system(size: 12))
                    }
                    HStack {
                        Text("共享目录")
                        Spacer()
                        Text("MG7Widget/").foregroundColor(MGTheme.textSecondary)
                            .font(.system(size: 12, design: .monospaced))
                    }
                } header: {
                    Text("关于")
                } footer: {
                    Text("数据通道：显示「小组件数据注入 ✅」时，打开本 App / 下拉刷新都会把最新车况直接推进小组件沙盒，小组件每 15 分钟也会自主联网刷新。「App Group 未分配」是 TrollStore 签名下的正常现象，不影响新通道。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                token = vm.config.accessToken
                vin = vm.config.vin
                userId = vm.config.userId
                carName = vm.config.carName
                plate = vm.config.plateNumber
                amapKey = vm.config.amapKey
                coordsGCJ = vm.config.coordsAreGCJ02
                aliClientId = vm.config.aliClientId
            }
        }
    }

    /// App Group 通道诊断：未分配 → 共享机制整体失效，小组件只能靠自主联网兜底
    private var groupStatusText: String {
        guard let dir = MG7Store.groupDirectory else { return "❌ 未分配" }
        let fm = FileManager.default
        let snap = dir.appendingPathComponent("snapshot.json").path
        if fm.fileExists(atPath: snap) { return "✅ 容器正常" }
        if fm.fileExists(atPath: dir.path) { return "⚠️ 容器空(先刷新)" }
        return "⚠️ 目录未建"
    }
}
