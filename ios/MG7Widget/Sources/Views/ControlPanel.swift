//
//  ControlPanel.swift
//  MG7Widget
//
//  控车面板：解锁 / 锁车 / 远程空调
//  ⚠️ 安全要求：所有控车操作必须二次确认，禁止静默执行。
//
//  ⚠️ 接口状态：控车接口尚未逆向完成（MG Linker 3.7 版有，后续版本移除）。
//     当前 UI 已就绪，接口实现见 SAICService.sendCommand（待补）。
//

import SwiftUI

struct ControlPanel: View {
    @ObservedObject var vm: CarViewModel

    @State private var pendingAction: ControlAction?
    @State private var isSending = false
    @State private var resultText: String?

    enum ControlAction: Identifiable {
        case lock, unlock, acOn, acOff
        var id: String { String(describing: self) }

        var title: String {
            switch self {
            case .lock:   return "远程锁车"
            case .unlock: return "远程解锁"
            case .acOn:   return "开启空调"
            case .acOff:  return "关闭空调"
            }
        }
        var icon: String {
            switch self {
            case .lock:   return "lock.fill"
            case .unlock: return "lock.open.fill"
            case .acOn:   return "snowflake"
            case .acOff:  return "wind"
            }
        }
        var warning: String {
            switch self {
            case .lock:   return "将锁定所有车门。请确认车内无人、钥匙未留在车内。"
            case .unlock: return "将解锁所有车门。请确认车辆周边安全。"
            case .acOn:   return "将远程启动空调。请确认车辆处于通风良好的位置。"
            case .acOff:  return "将关闭远程空调。"
            }
        }
    }

    var body: some View {
        MG7Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("远程控制").font(.system(size: 13, weight: .semibold))
                        .foregroundColor(MGTheme.textSecondary)
                    Spacer()
                    Text("需二次确认").font(.system(size: 10))
                        .foregroundColor(MGTheme.danger)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(MGTheme.danger.opacity(0.12))
                        .clipShape(Capsule())
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: 4), spacing: 10) {
                    ForEach([ControlAction.lock, .unlock, .acOn, .acOff]) { a in
                        Button { pendingAction = a } label: {
                            VStack(spacing: 6) {
                                Image(systemName: a.icon).font(.system(size: 19))
                                Text(a.title.replacingOccurrences(of: "远程", with: ""))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundColor(MGTheme.orange)
                            .background(MGTheme.orangeBg)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(isSending || !vm.config.isValid)
                        .opacity((isSending || !vm.config.isValid) ? 0.5 : 1)
                    }
                }

                if isSending {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("正在下发指令…").font(.system(size: 12))
                            .foregroundColor(MGTheme.textSecondary)
                    }
                }
                if let r = resultText {
                    Text(r).font(.system(size: 12))
                        .foregroundColor(r.contains("成功") ? MGTheme.success : MGTheme.danger)
                }
                if !vm.config.isValid {
                    Text("请先在设置中完成 token 与 VIN 配置后使用控车功能")
                        .font(.system(size: 11)).foregroundColor(MGTheme.textSecondary)
                }
            }
        }
        .alert(item: $pendingAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.warning),
                primaryButton: .destructive(Text("确认执行")) {
                    Task { await perform(action) }
                },
                secondaryButton: .cancel(Text("取消")))
        }
    }

    private func perform(_ action: ControlAction) async {
        isSending = true
        resultText = nil
        defer { isSending = false }

        // ⚠️ 控车接口待逆向，先给出明确提示
        // 接口实现后替换为: try await SAICService.shared.sendCommand(...)
        try? await Task.sleep(nanoseconds: 400_000_000)
        resultText = "控车接口开发中：需先完成 MG Live 控车请求逆向（见 docs/03-控车逆向.md）"
    }
}
