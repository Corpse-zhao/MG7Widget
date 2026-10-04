//
//  CarViewModel.swift
//  MG7Widget
//
//  主视图模型：管理配置、车况数据、刷新状态
//

import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class CarViewModel: ObservableObject {

    @Published var config: MG7Store.Config
    @Published var snapshot: VehicleSnapshot?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastRefreshText = "尚未刷新"
    @Published var showingSettings = false

    private let service = SAICService.shared

    init() {
        self.config = MG7Store.loadConfig()
        self.snapshot = MG7Store.loadSnapshot()
        updateRefreshText()
        let key = self.config.amapKey
        let gcj = self.config.coordsAreGCJ02
        let cid = self.config.aliClientId
        if !key.isEmpty || !cid.isEmpty {
            Task {
                await LocationService.shared.setAmapKey(key)
                await SAICService.shared.setAliClientId(cid)
            }
        }
        Task { await LocationService.shared.setCoordsAreGCJ02(gcj) }
    }

    func onLaunch() {
        // 开屏即注入：哪怕没网，也能把「上次的车况 + 配置」推进小组件沙盒
        // （App Group 未分配后，这是小组件拿到数据的唯一被动通道，v0.4.2）
        MG7Store.pushToWidgetContainer(config: config, snapshot: snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        if config.isValid {
            Task { await refresh() }
        } else {
            showingSettings = true
        }
    }

    /// 切回前台时调用：数据超过 2 分钟才重新拉，避免频繁请求触发风控
    func autoRefreshIfNeeded() async {
        guard config.isValid, !isLoading else { return }
        if let s = snapshot, Date().timeIntervalSince(s.fetchedAt) < 120 { return }
        await refresh()
    }

    // MARK: - 刷新

    func refresh() async {
        guard config.isValid else {
            errorMessage = "请先在设置中填写 token 与 VIN"
            return
        }
        // 并发去重：前台自动刷新与手动下拉撞车时，后来者直接复用结果，
        // 避免旧任务被取消而抛出「已取消」
        if isLoading { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var s = try await service.fetchSnapshot(token: config.accessToken, vin: config.vin)
            s.address = await LocationService.shared.reverseGeocode(lat: s.latitude, lon: s.longitude)
            snapshot = s
            MG7Store.saveSnapshot(s)
            updateRefreshText()
            // 通知小组件刷新
            WidgetCenter.shared.reloadAllTimelines()
        } catch is CancellationError {
            // 下拉刷新被快速滚动打断 / 前台自动刷新与手动刷新撞车
            // → 任务取消是正常现象，不提示用户
        } catch let e as URLError where e.code == .cancelled {
            // URLSession 层的取消（-999），同样静默
        } catch let e as SAICError {
            errorMessage = e.errorDescription
            if case .tokenExpired = e {
                errorMessage = "token 已失效。请打开一次 MG Live 刷新车况，然后回这里重新获取 token。"
            }
        } catch {
            let ns = error as NSError
            // 双保险：兜住所有形态的取消错误
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    private func updateRefreshText() {
        guard let s = snapshot, s.fetchedAt != .distantPast else {
            lastRefreshText = "尚未刷新"
            return
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        lastRefreshText = f.string(from: s.fetchedAt)
    }

    // MARK: - 配置

    func updateConfig(_ c: MG7Store.Config) {
        config = c
        MG7Store.saveConfig(c)   // 内部已注入小组件沙盒
        let key = c.amapKey
        let gcj = c.coordsAreGCJ02
        let cid = c.aliClientId
        Task {
            await LocationService.shared.setAmapKey(key)
            await LocationService.shared.setCoordsAreGCJ02(gcj)
            await SAICService.shared.setAliClientId(cid)
        }
        // 配置变化（车名/高德key等）也通知小组件重画
        WidgetCenter.shared.reloadAllTimelines()
    }

    func saveToken(_ token: String, vin: String, userId: String) {
        var c = config
        c.accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        c.vin = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        c.userId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        c.lastTokenSync = Date()
        updateConfig(c)
        Task { await refresh() }
    }
}
