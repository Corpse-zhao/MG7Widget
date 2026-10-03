//
//  MGTheme.swift
//  MG7Widget
//
//  MG 品牌橙主题
//

import SwiftUI

enum MGTheme {
    static let orange      = Color(red: 1.00, green: 0.42, blue: 0.00)   // #FF6B00 MG橙
    static let orangeLight = Color(red: 1.00, green: 0.60, blue: 0.20)
    static let orangeBg    = Color(red: 1.00, green: 0.96, blue: 0.93)
    static let cardBg      = Color(red: 0.97, green: 0.97, blue: 0.98)
    static let textPrimary = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let textSecondary = Color(red: 0.55, green: 0.55, blue: 0.60)
    static let danger      = Color(red: 0.85, green: 0.25, blue: 0.20)
    static let success     = Color(red: 0.18, green: 0.65, blue: 0.35)
    static let tyreBlue    = Color(red: 0.20, green: 0.45, blue: 0.75)

    /// Widget 容器背景（必须是浅色实底，否则 iOS 17 深色容器 + 深色文字 = 全黑）
    static let widgetBg    = Color(red: 0.98, green: 0.98, blue: 0.99)

    static let gradient = LinearGradient(
        colors: [orange, orangeLight],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// 卡片容器
struct MG7Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MGTheme.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 数值展示块
struct StatTile: View {
    let title: String
    let value: String
    let unit: String?
    let accent: Color
    var warning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(MGTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(warning ? MGTheme.danger : accent)
                if let u = unit {
                    Text(u).font(.system(size: 12, weight: .medium))
                        .foregroundColor(MGTheme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
