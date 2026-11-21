import SwiftUI
import MolaStorage
import UIKit

/// iOS 配色：背景 / 文字 / 分隔线一律用系统语义色（自动适配深色与高对比度），
/// 品牌粉（与安卓主色 #BE727F / #CF8996 一致）只用作 tint 和用户气泡。
enum MolaColor {
    /// 品牌主色（tint）。
    static let accent = dynamic(0xBE727F, 0xCF8996)
    /// 用户气泡：比主色更深，保证白字对比度 ≥ 4.5:1。
    static let bubble = dynamic(0xA35A67, 0x8A4A57)
    /// Claude 风格的用户气泡（中性灰）。
    static let userBubbleClaude = Color(uiColor: .secondarySystemFill)
    /// 安卓风格：主色容器（MolaTheme primaryContainer）与描边。
    static let androidContainer = dynamic(0xF7E6E9, 0x5A2A33)
    static let androidOutline = dynamic(0xDEE2E6, 0x333333)
    static let androidError = dynamic(0xF44336, 0xFF6B6B)
    static let accentSoft = dynamic(0xF7E6E9, 0x3A2328)

    static let background = Color(uiColor: .systemBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let codeBackground = Color(uiColor: .secondarySystemBackground)
    static let label = Color(uiColor: .label)
    static let secondaryLabel = Color(uiColor: .secondaryLabel)
    static let tertiaryLabel = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    /// iOS 26+ 用 Liquid Glass，之前的系统回退到 `.bar` 材质。
    @ViewBuilder
    func molaGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.bar, in: shape)
                .overlay(shape.stroke(MolaColor.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    /// 底部悬浮栏：iOS 26 用 safeAreaBar（带滚动边缘效果），更早用 safeAreaInset。
    @ViewBuilder
    func molaBottomBar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0) { content() }
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) { content() }
        }
    }

    /// 导航副标题（iOS 26+），更早的系统忽略。
    @ViewBuilder
    func molaSubtitle(_ text: String?) -> some View {
        if #available(iOS 26.0, *), let text {
            self.navigationSubtitle(text)
        } else {
            self
        }
    }
}

/// 系统「设置」风格的彩色圆角方块图标。
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
    }
}

struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title; self.symbol = symbol; self.color = color
    }

    var body: some View {
        Label { Text(title) } icon: { SettingsIcon(symbol: symbol, color: color) }
    }
}

// MARK: - 界面风格

private struct UIStyleKey: EnvironmentKey { static let defaultValue: UIStyle = .claude }
extension EnvironmentValues {
    var uiStyle: UIStyle {
        get { self[UIStyleKey.self] }
        set { self[UIStyleKey.self] = newValue }
    }
}
