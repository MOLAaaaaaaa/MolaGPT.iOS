import UIKit
import SafariServices

/// 打开链接：网页链接按设置用 App 内 Safari（SFSafariViewController，类似 Telegram）或系统默认浏览器；
/// 其他 scheme（mailto、tel、molagpt 等）交给系统。直接从最上层的控制器弹出，sheet / 全屏页里点链接也能打开。
@MainActor
enum LinkOpener {
    /// 由设置「打开链接」同步（MolaGPTApp）。
    static var preferInApp = true

    /// 返回 true 表示已处理。
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            return true
        }
        guard preferInApp, let top = topViewController() else {
            UIApplication.shared.open(url)
            return true
        }
        let config = SFSafariViewController.Configuration()
        config.barCollapsingEnabled = true
        let safari = SFSafariViewController(url: url, configuration: config)
        safari.preferredControlTintColor = UIColor(red: 0xBE / 255, green: 0x72 / 255, blue: 0x7F / 255, alpha: 1)
        safari.dismissButtonStyle = .close
        safari.modalPresentationStyle = .pageSheet
        top.present(safari, animated: true)
        return true
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
