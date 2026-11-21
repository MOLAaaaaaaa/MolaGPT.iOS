import SwiftUI
import WebKit
import MolaCore

/// HTML 代码块默认显示为卡片，点按全屏运行（对应安卓 HtmlFenceView / HtmlRunner / HtmlSandbox）。
struct HtmlCardView: View {
    let code: String
    let closed: Bool
    @State private var running = false
    @State private var asCode = false

    var body: some View {
        if asCode {
            VStack(alignment: .trailing, spacing: 6) {
                CodeBlockView(language: "html", code: code)
                HStack {
                    Button("收起为卡片", systemImage: "rectangle.on.rectangle") { asCode = false }
                    Button("运行", systemImage: "play.fill") { running = true }.disabled(!closed)
                }
                .font(.caption).buttonStyle(.bordered)
            }
            .fullScreenCover(isPresented: $running) { HtmlRunnerView(html: code, title: HtmlFence.title(code)) }
        } else {
            Button { if closed { running = true } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "safari")
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(MolaColor.accent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HtmlFence.title(code)).font(.subheadline.weight(.semibold)).foregroundStyle(MolaColor.label).lineLimit(1)
                        Text(closed ? "\(code.split(separator: "\n").count) 行 · 点按运行" : "正在生成…")
                            .font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                    }
                    Spacer()
                    if closed { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(MolaColor.accent) }
                    else { ProgressView() }
                }
                .padding(12)
                .background(MolaColor.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("显示代码", systemImage: "chevron.left.forwardslash.chevron.right") { asCode = true }
                Button("拷贝代码", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }
            }
            .fullScreenCover(isPresented: $running) { HtmlRunnerView(html: code, title: HtmlFence.title(code)) }
        }
    }
}

struct HtmlRunnerView: View {
    let html: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var showSource = false
    @State private var errors: [String] = []
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            Group {
                if showSource {
                    ScrollView { Text(html).font(.caption.monospaced()).textSelection(.enabled).padding() }
                } else {
                    SandboxWebView(html: html, dark: scheme == .dark, reloadToken: reloadToken) { errors.append($0) }
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(showSource ? "显示页面" : "查看源码", systemImage: showSource ? "safari" : "chevron.left.forwardslash.chevron.right") { showSource.toggle() }
                        Button("重新加载", systemImage: "arrow.clockwise") { errors = []; reloadToken += 1 }
                        Button("拷贝源码", systemImage: "doc.on.doc") { UIPasteboard.general.string = html }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !errors.isEmpty && !showSource {
                    DisclosureGroup {
                        ScrollView {
                            Text(errors.suffix(20).joined(separator: "\n")).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    } label: {
                        Label("页面有 \(errors.count) 个错误", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    }
                    .padding(12)
                    .background(.regularMaterial)
                }
            }
        }
    }
}

/// 沙盒：每页独立伪 origin（自定义 scheme），CSP 只放行白名单 CDN，不开放原生接口（仅错误回报）。
struct SandboxWebView: UIViewRepresentable {
    let html: String
    let dark: Bool
    let reloadToken: Int
    let onError: (String) -> Void

    static let scheme = "mola-canvas"
    static let cdns = ["https://cdn.jsdelivr.net", "https://fastly.jsdelivr.net", "https://gcore.jsdelivr.net", "https://unpkg.com",
                       "https://cdnjs.cloudflare.com", "https://esm.sh", "https://cdn.tailwindcss.com", "https://registry.npmmirror.com",
                       "https://cdn.npmmirror.com", "https://lib.baomitu.com", "https://fonts.googleapis.com", "https://fonts.gstatic.com"]

    static var csp: String {
        let c = cdns.joined(separator: " ")
        return "default-src 'none'; script-src 'self' 'unsafe-inline' 'unsafe-eval' \(c); style-src 'self' 'unsafe-inline' \(c); " +
            "font-src 'self' data: \(c); img-src 'self' data: blob: \(c); connect-src 'self' \(c); media-src 'self' data: blob:; " +
            "frame-src 'none'; form-action 'none'; base-uri 'self'"
    }

    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: Self.scheme)
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "molaReport")
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        load(web, context: context)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.loadedToken != reloadToken { load(web, context: context) }
        web.evaluateJavaScript("window.__molaTheme && window.__molaTheme(\(dark ? "true" : "false"))")
    }

    private func load(_ web: WKWebView, context: Context) {
        let key = SHA256.hex(Array(SHA256.hash(html).prefix(6)))
        context.coordinator.document = Self.buildHTML(html, dark: dark)
        context.coordinator.loadedToken = reloadToken
        web.load(URLRequest(url: URL(string: "\(Self.scheme)://c-\(key)/index.html")!))
    }

    /// 在模型页面的 head 前注入 charset、viewport、主题变量与报错桥。
    static func buildHTML(_ page: String, dark: Bool) -> String {
        let theme = """
        <style id="mola-theme">
        :root{--mola-bg:#ffffff;--mola-surface:#f2f2f7;--mola-text:#1c1c1e;--mola-muted:#6e6e73;--mola-border:#d1d1d6;--mola-accent:#BE727F;
        --mola-chart-1:#BE727F;--mola-chart-2:#007AFF;--mola-chart-3:#FF9500;--mola-chart-4:#34C759;--mola-chart-5:#AF52DE;--mola-chart-6:#30B0C7;color-scheme:light}
        :root.mola-dark{--mola-bg:#000000;--mola-surface:#1c1c1e;--mola-text:#f2f2f7;--mola-muted:#98989f;--mola-border:#38383a;--mola-accent:#CF8996;color-scheme:dark}
        html,body{background:var(--mola-bg);color:var(--mola-text);margin:0;-webkit-text-size-adjust:100%;font-family:-apple-system,system-ui,sans-serif}
        </style>
        """
        let bridge = """
        <script>
        (function(){var r=function(t,m){try{window.webkit.messageHandlers.molaReport.postMessage(t+': '+m)}catch(e){}};
        window.__molaTheme=function(d){document.documentElement.classList.toggle('mola-dark',!!d)};window.__molaTheme(\(dark ? "true" : "false"));
        window.addEventListener('error',function(e){r('error',(e.message||'')+(e.lineno?' @'+e.lineno:''))});
        window.addEventListener('unhandledrejection',function(e){r('error',String(e.reason))});
        document.addEventListener('securitypolicyviolation',function(e){r('blocked',e.blockedURI)});})();
        </script>
        """
        let head = "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">" +
            "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">" + theme + bridge
        if let r = page.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var p = page; p.insert(contentsOf: head, at: r.upperBound); return p
        }
        if let r = page.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var p = page; p.insert(contentsOf: "<head>\(head)</head>", at: r.upperBound); return p
        }
        return "<!doctype html><html><head>\(head)</head><body>\(page)</body></html>"
    }

    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
        var document = ""
        var loadedToken = -1
        let onError: (String) -> Void
        init(onError: @escaping (String) -> Void) { self.onError = onError }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let isDoc = url.path == "/" || url.path == "/index.html"
            let data = isDoc ? Data(document.utf8) : Data()
            let resp = HTTPURLResponse(url: url, statusCode: isDoc ? 200 : 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": SandboxWebView.csp])!
            task.didReceive(resp)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if let s = message.body as? String { onError(String(s.prefix(500))) }
        }

        /// 页面内的外链交给系统浏览器；只允许本页与白名单 CDN 的子资源。
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == SandboxWebView.scheme || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return .allow }
            if action.targetFrame?.isMainFrame ?? true, url.scheme == "http" || url.scheme == "https" {
                await MainActor.run { _ = LinkOpener.open(url) }
                return .cancel
            }
            return .cancel
        }
    }
}
