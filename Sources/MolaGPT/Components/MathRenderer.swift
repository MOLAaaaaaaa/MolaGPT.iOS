import SwiftUI
import UIKit
import SwiftMath
import MolaCore

/// LaTeX → UIImage（SwiftMath / CoreText），带缓存。返回基线下方高度用于行内对齐。
@MainActor
enum MathRenderer {
    struct Rendered { let image: UIImage; let descent: CGFloat }

    private static var cache: [String: Rendered] = [:]
    private static var failed: Set<String> = []

    static func inline(_ latex: String, fontSize: CGFloat, dark: Bool) -> Rendered? {
        render(latex, fontSize: fontSize, dark: dark, mode: .text)
    }

    static func display(_ latex: String, fontSize: CGFloat, dark: Bool) -> Rendered? {
        render(latex, fontSize: fontSize, dark: dark, mode: .display)
    }

    private static func render(_ latex: String, fontSize: CGFloat, dark: Bool, mode: MTMathUILabelMode) -> Rendered? {
        let key = "\(mode == .display ? "D" : "T")|\(Int(fontSize))|\(dark ? 1 : 0)|\(latex)"
        if let hit = cache[key] { return hit }
        if failed.contains(key) { return nil }
        let color = UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        let source = normalize(latex)
        // 绘制用 SwiftMath 的 MTMathImage（内部已处理 CoreText 左下原点的翻转）。
        // 不要用 MTMathUILabel + layer.render(in:)：标签在 draw 里自己翻转坐标系，离屏渲染时会再翻一次，公式就上下颠倒了。
        let (error, rendered) = MTMathImage(latex: source, fontSize: fontSize, textColor: color, labelMode: mode, textAlignment: .left).asImage()
        guard error == nil, let image = rendered, image.size.width > 0, image.size.height > 0, image.size.width < 8000 else {
            failed.insert(key); return nil
        }
        // 只用标签量出基线下方高度（行内对齐用）；MTMathImage 在内容矮于半个字号时会垂直居中，相应修正
        let label = MTMathUILabel()
        label.labelMode = mode
        label.fontSize = fontSize
        label.latex = source
        label.frame = CGRect(origin: .zero, size: image.size)
        label.layoutSubviews()
        let ascent = label.displayList?.ascent ?? image.size.height
        var descent = label.displayList?.descent ?? 0
        if ascent + descent < fontSize / 2 { descent += (image.size.height - fontSize / 2) / 2 }
        let r = Rendered(image: image, descent: descent)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = r
        return r
    }

    /// SwiftMath 不认识的常见写法做轻量替换。
    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for (a, b) in [("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("\\displaystyle", ""), ("\\textstyle", ""),
                       ("\\left.", ""), ("\\right.", ""), ("\\le ", "\\leq "), ("\\ge ", "\\geq ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}

/// 代码高亮配色（Xcode 默认主题风格，深浅色自适应）。
enum CodeColors {
    static func color(_ kind: CodeTokenKind) -> UIColor {
        switch kind {
        case .keyword: dyn(0xAD3DA4, 0xFF7AB2)
        case .string: dyn(0xD12F1B, 0xFF8170)
        case .comment: dyn(0x5D6C79, 0x7F8C98)
        case .number: dyn(0x272AD8, 0xD9C97C)
        case .type: dyn(0x3E8087, 0x9EF1DD)
        case .function: dyn(0x326D74, 0x67B7A4)
        case .attribute: dyn(0x947100, 0xFFA14F)
        }
    }

    static func highlight(_ code: String, language: String?) -> AttributedString {
        let tokens = CodeHighlighter.tokenize(code, language: language)
        guard !tokens.isEmpty else { return AttributedString(code) }
        let ns = NSMutableAttributedString(string: code)
        let len = ns.length
        for t in tokens where t.location + t.length <= len {
            ns.addAttribute(.foregroundColor, value: color(t.kind), range: NSRange(location: t.location, length: t.length))
        }
        return (try? AttributedString(ns, including: \.uiKit)) ?? AttributedString(code)
    }

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? hex(dark) : hex(light) }
    }
    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
