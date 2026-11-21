import SwiftUI

@main
struct MolaGPTApp: App {
    @State private var app = AppModel.bootstrap()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(MolaColor.accent)
                .preferredColorScheme(app.colorScheme)
                .environment(\.htmlAsCard, app.settings.htmlAsCard)
                .environment(\.uiStyle, app.settings.uiStyle)
                // 所有 SwiftUI 链接（Markdown 正文、Link、openURL）统一按设置打开
                .environment(\.openURL, OpenURLAction { url in LinkOpener.open(url) ? .handled : .systemAction })
                .onChange(of: app.settings.linkOpenMode, initial: true) { _, mode in LinkOpener.preferInApp = mode == .inApp }
                .onOpenURL { url in
                    if url.scheme == "molagpt", url.host == "oauth_callback" { Task { await app.account.handleCallback(url) } }
                    if url.scheme == "molagpt", url.host == "share" { ShareImporter.consume(app) }
                    app.handleDeepLink(url)
                }
        }
    }
}
