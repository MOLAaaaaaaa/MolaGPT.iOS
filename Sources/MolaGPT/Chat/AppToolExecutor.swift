import Foundation
import MolaCore
import MolaStorage

/// 一轮回答共用的来源账本（跨工具调用、跨轮次连续编号）。
actor CitationBox {
    var ledger = CitationLedger()
    func record(_ hits: [SearchHit], query: String, prefix: String?) -> (String, Bool, [SourceReference], String) {
        let r = ledger.record(hits, query: query, prefix: prefix)
        return (r.text, r.added, ledger.refs, ledger.queryLabel)
    }
}

/// 本地工具执行时的会话上下文。
struct ToolContext: Sendable {
    let sessionId: String
    let lastUserText: String
    let lastUserMessageId: String?
}

/// 本地工具（记忆、回忆、技能）由各自的仓库实现，通过这个回调接进来。
typealias LocalToolHandler = @Sendable (PendingToolCall, ToolContext) async -> ToolResult?

/// BYOK 工具执行（对应安卓 ByokChatService.executeTool）。构造时拍下所需状态的快照，执行期间不再访问 UI 状态。
struct AppToolExecutor: ToolExecutor {
    let session: URLSession
    let settings: AppSettings
    let currentProvider: ByokProvider
    let providers: [ByokProvider]
    let mcpServers: [McpServer]
    let mcp: McpClient
    /// 用户消息里的图片，按上传顺序全局编号（view_image 用）。
    let images: [(name: String, part: WireMessage.Part?)]
    let imageDirectory: URL
    let molaBaseURL: String
    let molaJWT: String?
    let citations = CitationBox()
    let local: [String: LocalToolHandler]
    let context: ToolContext

    func execute(_ call: PendingToolCall, emit: @escaping @Sendable (StreamEvent) -> Void) async -> ToolResult {
        if let h = local[call.name], let r = await h(call, context) { return r }
        switch call.name {
        case "search_web": return await search(call, emit: emit)
        case "fetch_url": return await fetch(call)
        case "view_image": return await viewImage(call)
        case "generate_image": return await generateImage(call, emit: emit)
        case "mcp_list_tools": return await mcpList(call)
        case "mcp_call": return await mcpCall(call)
        default: return .failure("Unsupported tool: \(call.name)")
        }
    }

    // MARK: 联网搜索

    private func search(_ call: PendingToolCall, emit: @escaping @Sendable (StreamEvent) -> Void) async -> ToolResult {
        let provider = settings.effectiveSearchProvider(loggedIn: molaJWT != nil)
        let limit = WebSearchAPI.resultCount(requested: call.int("max_results"), setting: settings.webSearchMaxResults, provider: provider)
        do {
            var hits: [SearchHit] = []
            var prefix: String?
            var query = call.string("query") ?? ""
            switch provider {
            case .duckduckgo:
                guard !query.isEmpty else { return .failure("Missing query") }
                let (status, data) = try await send(WebSearchAPI.duckDuckGo(query))
                guard (200..<300).contains(status) else { return .failure("Search failed: HTTP \(status)") }
                hits = WebSearchAPI.parseDuckDuckGo(String(decoding: data, as: UTF8.self), limit: limit)
                if hits.isEmpty { return ToolResult("未从 DuckDuckGo 获取到结果（可能被反爬限制），可在设置改用 Tavily/Exa。") }
            case .tavily:
                guard !query.isEmpty else { return .failure("Missing query") }
                guard let key = Keychain.get(Keychain.Key.webSearchKey(provider.rawValue))?.nonBlank else { return .failure("Search failed: 未配置 Tavily API Key，请在设置填写") }
                let (status, data) = try await send(WebSearchAPI.tavily(query, key: key, limit: limit))
                guard (200..<300).contains(status) else { return .failure("Search failed: HTTP \(status) \(ProviderError.summarize(String(decoding: data, as: UTF8.self)))") }
                let r = WebSearchAPI.parseTavily(data)
                hits = r.hits
                prefix = r.answer.map { "摘要：\($0)" }
                if hits.isEmpty { return ToolResult(r.answer ?? "Tavily 未返回结果") }
            case .exa:
                guard !query.isEmpty else { return .failure("Missing query") }
                guard let key = Keychain.get(Keychain.Key.webSearchKey(provider.rawValue))?.nonBlank else { return .failure("Search failed: 未配置 Exa API Key，请在设置填写") }
                let (status, data) = try await send(WebSearchAPI.exa(query, key: key, limit: limit))
                guard (200..<300).contains(status) else { return .failure("Search failed: HTTP \(status) \(ProviderError.summarize(String(decoding: data, as: UTF8.self)))") }
                hits = WebSearchAPI.parseExa(data)
                if hits.isEmpty { return ToolResult("Exa 未返回结果") }
            case .molagpt:
                guard let jwt = molaJWT else { return .failure("Search failed: 未登录 MolaGPT 账户，请在设置登录或改用其他搜索服务") }
                let queries = Array((call.args["queries"]?.arrayValue ?? []).prefix(5))
                guard !queries.isEmpty else { return .failure("Missing queries") }
                query = queries.compactMap { $0["query"]?.stringValue }.joined(separator: " / ")
                let (status, data) = try await send(WebSearchAPI.molagpt(baseURL: molaBaseURL, jwt: jwt, queries: queries, limit: limit))
                if status == 401 { return .failure("Search failed: 登录已过期，请重新登录") }
                guard (200..<300).contains(status) else { return .failure("Search failed: 搜索服务暂时不可用，请稍后重试。") }
                let r = WebSearchAPI.parseMolaGPT(data)
                hits = r.hits
                if !r.failedQueries.isEmpty { prefix = "以下查询搜索失败：\(r.failedQueries.joined(separator: "、"))" }
            }
            let (text, added, refs, label) = await citations.record(hits, query: query, prefix: prefix)
            if added { emit(.sources(refs: refs, query: label)) }
            return ToolResult(text)
        } catch {
            return .failure("Search failed: \(error.localizedDescription)")
        }
    }

    // MARK: 网页阅读

    private func fetch(_ call: PendingToolCall) async -> ToolResult {
        guard let raw = call.string("url"), let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return .failure("Missing url") }
        do {
            let (data, resp) = try await session.data(for: HTMLText.fetchRequest(url).urlRequest)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .failure("Fetch failed: HTTP \(status)") }
            let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let body = String(decoding: data.prefix(3_000_000), as: UTF8.self)
            let isHTML = type.contains("html") || body.prefix(500).lowercased().contains("<html")
            return ToolResult(HTMLText.fetchResult(url: (http?.url ?? url).absoluteString, body: body, isHTML: isHTML))
        } catch {
            return .failure("Fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: 视觉代理

    private func viewImage(_ call: PendingToolCall) async -> ToolResult {
        guard let idxText = call.string("image_index"), let idx = Int(idxText.filter(\.isNumber)) else { return .failure("Missing image_index") }
        guard images.indices.contains(idx - 1) else { return .failure("Image index \(idx) out of range (1-\(images.count))") }
        let img = images[idx - 1]
        guard let part = img.part else { return .failure("Image \(idx) (\(img.name)) is no longer available on this device.") }
        guard let (provider, model) = visionTarget() else {
            return .failure("Vision failed: 外挂视觉未配置可用的视觉模型：请在「设置 → 工具 → 视觉理解」中选择一个支持视觉的模型。")
        }
        do {
            let spec = try VisionProxy.request(provider: provider, model: model, query: call.string("query")?.nonBlank ?? "请分析这张图片。", image: part)
            let (status, data) = try await send(spec)
            guard (200..<300).contains(status) else {
                return .failure("Vision failed: HTTP \(status) \(ProviderError.summarize(String(decoding: data, as: UTF8.self)))")
            }
            guard let text = ProviderAdapters.parseNonStreamText(provider.type, body: data)?.nonBlank else { return .failure("Vision failed: 视觉模型没有返回内容") }
            return ToolResult(text)
        } catch {
            return .failure("Vision failed: \(error.localizedDescription)")
        }
    }

    private func visionTarget() -> (ByokProvider, ProviderModel)? {
        if let key = ModelKey(settings.visionProxyModelKey), let p = providers.first(where: { $0.id == key.providerId && $0.enabled }),
           let m = p.model(key.modelId) { return (p, m) }
        if let m = currentProvider.models.first(where: { $0.enabled && $0.supportsVision }) { return (currentProvider, m) }
        return nil
    }

    // MARK: 图像生成

    private func generateImage(_ call: PendingToolCall, emit: @escaping @Sendable (StreamEvent) -> Void) async -> ToolResult {
        guard let prompt = call.string("prompt")?.nonBlank else { return .failure("Missing image prompt") }
        guard let (provider, model) = imageTarget() else { return .failure("Image generation failed: 未配置图像模型") }
        do {
            let spec = try ImageGenAPI.generate(provider: provider, model: model.id, prompt: prompt, config: settings.imageGenConfig)
            let (status, data) = try await send(spec)
            guard (200..<300).contains(status) else {
                return .failure("Image generation failed: HTTP \(status) \(ProviderError.summarize(String(decoding: data, as: UTF8.self)))")
            }
            let r = ImageGenAPI.extractImages(data)
            guard let first = r.images.first else { return .failure("Image generation failed: \(r.text ?? "未返回图片")") }
            emit(.image(url: saveImage(first)))
            return ToolResult("[图像已生成并展示给用户]")
        } catch {
            return .failure("Image generation failed: \(error.localizedDescription)")
        }
    }

    private func imageTarget() -> (ByokProvider, ProviderModel)? {
        if let key = ModelKey(settings.imageGenModelKey), let p = providers.first(where: { $0.id == key.providerId && $0.enabled }),
           let m = p.model(key.modelId) { return (p, m) }
        if let m = currentProvider.models.first(where: { $0.enabled && $0.supportsImageGeneration }) { return (currentProvider, m) }
        for p in providers where p.enabled && p.purpose == .image {
            if let m = p.models.first(where: { $0.enabled && $0.supportsImageGeneration }) ?? p.models.first(where: \.enabled) { return (p, m) }
        }
        return nil
    }

    /// data URI 落盘到 Documents/gen_images，返回 file:// URL；http(s) 直接返回。
    private func saveImage(_ src: String) -> String {
        guard let (data, ext) = ImageGenAPI.decodeDataURI(src) else { return src }
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(ext)"
        let url = imageDirectory.appendingPathComponent(name)
        do { try data.write(to: url); return "local:\(imageDirectory.lastPathComponent)/\(name)" } catch { return src }
    }

    // MARK: MCP

    private func mcpList(_ call: PendingToolCall) async -> ToolResult {
        let enabled = mcpServers.filter(\.enabled)
        guard !enabled.isEmpty else { return ToolResult("No enabled MCP servers") }
        let filter = call.string("server")?.lowercased().nonBlank
        var sections: [String] = []
        for s in enabled where filter == nil || s.name.lowercased() == filter || s.id.lowercased() == filter {
            do {
                let tools = try await mcp.listTools(s).filter { !s.disabledTools.contains($0.name) }
                let lines = tools.map { t -> String in
                    var line = "\(t.name) - \(t.description ?? "")"
                    if let schema = t.inputSchema?["properties"]?.objectValue, !schema.isEmpty {
                        line += "\n  参数: \(t.inputSchema!.jsonString().prefix(600))"
                    }
                    return line
                }
                sections.append("\(s.name)\n" + (lines.isEmpty ? "No tools" : lines.joined(separator: "\n")))
            } catch {
                sections.append("\(s.name)\nMCP failed: \(error.localizedDescription)")
            }
        }
        return ToolResult(sections.isEmpty ? "No tools" : sections.joined(separator: "\n\n"))
    }

    private func mcpCall(_ call: PendingToolCall) async -> ToolResult {
        guard let name = call.string("server")?.lowercased().nonBlank else { return .failure("Missing server") }
        guard let tool = call.string("tool")?.nonBlank else { return .failure("Missing tool") }
        guard let server = mcpServers.first(where: { $0.enabled && ($0.name.lowercased() == name || $0.id.lowercased() == name) }) else {
            return .failure("MCP failed: 未找到已启用的服务器 \(name)")
        }
        if server.disabledTools.contains(tool) { return .failure("MCP tool disabled: \(tool)") }
        var args = call.args["arguments"] ?? .object([:])
        if let s = args.stringValue { args = JSONValue.parse(s) ?? .object([:]) }
        let out = await mcp.callTool(server, tool: tool, arguments: args, id: call.id)
        return ToolResult(out, failed: out.hasPrefix("MCP failed"))
    }

    private func send(_ spec: HTTPRequestSpec) async throws -> (Int, Data) {
        let (data, resp) = try await session.data(for: spec.urlRequest)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
