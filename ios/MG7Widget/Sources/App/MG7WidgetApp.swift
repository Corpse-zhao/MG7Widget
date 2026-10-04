//
//  MG7WidgetApp.swift
//  MG7Widget
//
//  App 入口
//  署名：板栗仁
//

import SwiftUI

@main
struct MG7WidgetApp: App {

    @StateObject private var vm = CarViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .preferredColorScheme(.light)
                .onAppear { vm.onLaunch() }
        }
        // 切回前台自动刷新：不用等用户手动下拉
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active { Task { await vm.autoRefreshIfNeeded() } }
        }
    }
}

/// 版本号（与 control / 页脚保持同步）
enum AppInfo {
    static let version = "0.4.14"
    static let author  = "板栗仁"
}
