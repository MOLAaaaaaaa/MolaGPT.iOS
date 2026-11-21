import SwiftUI
import WebKit
import MolaCore

/// Mermaid 图（安卓仍按代码块显示，iOS 额外渲染）。
/// 流式中 / 渲染失败 / 离线时显示代码块；闭合后在沙盒 WKWebView 里用 mermaid.js 渲染，按内容自适应高度，点按全屏缩放。
struct MermaidView: View {
    let source: String
    var closed: Bool = true

    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 120
    @State private var failure: String?
    @State private var ready = false
    @State private var fullscreen = false
    @State private var showCode = false

    var body: some View {
        if !closed || showCode || failure != nil {
            VStack(alignment: .leading, spacing: 6) {
                CodeBlockView(language: "mermaid", code: source)
                if let failure, closed {
                    HStack(spacing: 8) {
                        Label(failure, systemImage: "exclamationmark.triangle").lineLimit(2)
                        Spacer()
                        Button("重试") { self.failure = nil; ready = false }
                    }
                    .font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                } else if showCode {
                    Button("显示图表", systemImage: "chart.xyaxis.line") { showCode = false }
                        .font(.caption).buttonStyle(.bordered)
                }
            }
        } else {
            MermaidWebView(source: source, dark: scheme == .dark, interactive: false,
                           onHeight: { height = min(max($0, 60), 560); ready = true },
                           onError: { failure = $0 })
                .id(scheme)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .opacity(ready ? 1 : 0)
                .overlay { if !ready { ProgressView() } }
                .padding(8)
                .background(MolaColor.secondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { fullscreen = true }
                .contextMenu {
                    Button("全屏查看", systemImage: "arrow.up.left.and.arrow.down.right") { fullscreen = true }
                    Button("显示代码", systemImage: "chevron.left.forwardslash.chevron.right") { showCode = true }
                    Button("拷贝代码", systemImage: "doc.on.doc") { UIPasteboard.general.string = source }
                }
                .fullScreenCover(isPresented: $fullscreen) { MermaidFullscreen(source: source) }
                .accessibilityLabel("Mermaid 图表")
                .accessibilityHint("点按全屏查看")
        }
    }
}

private struct MermaidFullscreen: View {
    let source: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            MermaidWebView(source: source, dark: scheme == .dark, interactive: true, onHeight: { _ in }, onError: { _ in })
                .id(scheme)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("图表")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("拷贝代码", systemImage: "doc.on.doc") { UIPasteboard.general.string = source }
                    }
                }
        }
    }
}

/// 复用 HTML 沙盒的 CSP / 伪 origin / 主题注入；额外回报内容高度。
struct MermaidWebView: UIViewRepresentable {
    let source: String
    let dark: Bool
    let interactive: Bool
    let onHeight: (CGFloat) -> Void
    let onError: (String) -> Void

    /// 国内网络下 jsDelivr 可能不通，依次回退 npmmirror / unpkg。
    static let scripts = [
        "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js",
        "https://registry.npmmirror.com/mermaid/11.4.1/files/dist/mermaid.min.js",
        "https://unpkg.com/mermaid@11.4.1/dist/mermaid.min.js",
    ]

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight, onError: onError) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: SandboxWebView.scheme)
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(context.coordinator), name: "mermaid")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = interactive
        web.isUserInteractionEnabled = interactive
        if interactive {
            web.scrollView.minimumZoomScale = 0.5
            web.scrollView.maximumZoomScale = 6
        }
        let key = SHA256.hex(Array(SHA256.hash(source + (dark ? "d" : "l")).prefix(6)))
        context.coordinator.document = SandboxWebView.buildHTML(Self.page(source, dark: dark, interactive: interactive), dark: dark)
        web.load(URLRequest(url: URL(string: "\(SandboxWebView.scheme)://m-\(key)/index.html")!))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func page(_ source: String, dark: Bool, interactive: Bool) -> String {
        // 源码以 JSON 字符串注入，避免 </script> 与转义问题。
        let src = (try? String(data: JSONEncoder().encode(source), encoding: .utf8)) ?? "\"\""
        let urls = (try? String(data: JSONEncoder().encode(scripts), encoding: .utf8)) ?? "[]"
        let viewport = interactive
            ? "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=6, user-scalable=yes\">" : ""
        return """
        <!doctype html><html><head>\(viewport)
        <style>
        html,body{background:transparent!important}
        body{display:flex;justify-content:center;align-items:\(interactive ? "center" : "flex-start");min-height:\(interactive ? "100vh" : "0")}
        #c{width:100%;\(interactive ? "padding:16px;box-sizing:border-box;" : "")}
        #c svg{display:block;margin:0 auto;max-width:100%;height:auto}
        </style></head><body><div id="c"></div>
        <script>
        (function(){
          var post=function(m){try{window.webkit.messageHandlers.mermaid.postMessage(m)}catch(e){}};
          var urls=\(urls), i=0, src=\(src);
          function report(){var h=document.getElementById('c').getBoundingClientRect().height;post({h:Math.ceil(h)})}
          function render(){
            try{
              mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:\(dark ? "'dark'" : "'default'"),
                fontFamily:'-apple-system,system-ui,sans-serif',themeVariables:{fontSize:'14px'}});
              mermaid.render('mola-mermaid',src).then(function(r){
                document.getElementById('c').innerHTML=r.svg;
                requestAnimationFrame(report);
              }).catch(function(e){post({error:String((e&&e.message)||e).split('\\n')[0]})});
            }catch(e){post({error:String(e.message||e)})}
          }
          function load(){
            if(i>=urls.length){post({error:'无法加载 Mermaid 渲染库（离线？）'});return}
            var s=document.createElement('script');s.src=urls[i++];s.onload=render;s.onerror=load;document.head.appendChild(s);
          }
          window.addEventListener('resize',function(){if(document.querySelector('#c svg'))report()});
          load();
        })();
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
        var document = ""
        let onHeight: (CGFloat) -> Void
        let onError: (String) -> Void
        init(onHeight: @escaping (CGFloat) -> Void, onError: @escaping (String) -> Void) {
            self.onHeight = onHeight; self.onError = onError
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let isDoc = url.path == "/" || url.path == "/index.html"
            let resp = HTTPURLResponse(url: url, statusCode: isDoc ? 200 : 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8",
                                                      "Content-Security-Policy": SandboxWebView.csp])!
            task.didReceive(resp)
            task.didReceive(isDoc ? Data(document.utf8) : Data())
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let h = body["h"] as? Double { onHeight(CGFloat(h)) }
            else if let h = body["h"] as? Int { onHeight(CGFloat(h)) }
            else if let e = body["error"] as? String { onError(String(e.prefix(200))) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            return url.scheme == SandboxWebView.scheme || url.scheme == "about" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            onError(error.localizedDescription)
        }
    }
}

/// WKUserContentController 会强引用 handler，用弱引用包一层避免 web view 与 coordinator 循环引用。
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
