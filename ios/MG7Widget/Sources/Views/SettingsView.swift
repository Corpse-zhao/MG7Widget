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
                } header: {
                    Text("车辆信息")
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
                        Text("共享目录")
                        Spacer()
                        Text("MG7Widget/").foregroundColor(MGTheme.textSecondary)
                            .font(.system(size: 12, design: .monospaced))
                    }
                } header: {
                    Text("关于")
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
            }
        }
    }
}
