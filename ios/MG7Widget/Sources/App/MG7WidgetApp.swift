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

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .preferredColorScheme(.light)
                .onAppear { vm.onLaunch() }
        }
    }
}

/// 版本号（与 control / 页脚保持同步）
enum AppInfo {
    static let version = "0.3.2"
    static let author  = "板栗仁"
}
