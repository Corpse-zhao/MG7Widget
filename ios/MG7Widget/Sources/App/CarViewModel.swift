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
    }

    func onLaunch() {
        if config.isValid {
            Task { await refresh() }
        } else {
            showingSettings = true
        }
    }

    // MARK: - 刷新

    func refresh() async {
        guard config.isValid else {
            errorMessage = "请先在设置中填写 token 与 VIN"
            return
        }
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
        } catch let e as SAICError {
            errorMessage = e.errorDescription
            if case .tokenExpired = e {
                errorMessage = "token 已失效。请打开一次 MG Live 刷新车况，然后回这里重新获取 token。"
            }
        } catch {
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
        MG7Store.saveConfig(c)
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
