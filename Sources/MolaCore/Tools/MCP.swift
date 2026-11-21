import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 远程 MCP（对应安卓 ByokMcpServer / McpToolListApi / ByokChatService.callMcpServer）。
// 安卓是无状态 JSON-RPC POST；这里先尝试标准 Streamable HTTP 握手（initialize + Mcp-Session-Id，
// 接受 JSON 或 SSE 响应），握手失败时回退到安卓的无状态调用，两类服务器都能用。

public struct McpServer: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var endpoint: String
    /// 不入库：运行时从 Keychain（`byok.mcp_server.token:<id>`）注入。
    public var token: String?
    public var headerName: String
    public var enabled: Bool
    public var disabledTools: [String]

    public init(id: String = IDs.generic("mcp"), name: String, endpoint: String, token: String? = nil,
                headerName: String = "Authorization", enabled: Bool = true, disabledTools: [String] = []) {
        self.id = id; self.name = name; self.endpoint = endpoint; self.token = token
        self.headerName = headerName; self.enabled = enabled; self.disabledTools = disabledTools
    }

    enum CodingKeys: String, CodingKey { case id, name, endpoint, headerName, enabled, disabledTools }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        token = nil
        headerName = try c.decodeIfPresent(String.self, forKey: .headerName) ?? "Authorization"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        disabledTools = try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
    }
}

public struct McpToolInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String?
    public var inputSchema: JSONValue?
    public var id: String { name }
    public init(name: String, description: String?, inputSchema: JSONValue?) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

public enum McpRPC {
    public static let protocolVersion = "2025-06-18"

    public static func body(method: String, id: String?, params: JSONValue? = nil) -> Data {
        var o: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { o["id"] = .string(id) }
        if let params { o["params"] = params }
        return JSONValue.object(o).data()
    }

    public static func headers(_ server: McpServer, sessionId: String?) -> [String: String] {
        var h = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream", "User-Agent": MolaUA.fixed]
        if let t = server.token?.nonBlank {
            let name = server.headerName.nonBlank ?? "Authorization"
            h[name] = t.lowercased().hasPrefix("bearer ") ? t : "Bearer \(t)"
        }
        if let sessionId { h["Mcp-Session-Id"] = sessionId; h["MCP-Protocol-Version"] = protocolVersion }
        return h
    }

    /// 响应体可能是 JSON，也可能是 SSE（取最后一个带 result/error 的 data 帧）。
    public static func parseResponse(_ data: Data) -> JSONValue? {
        if let j = JSONValue.parse(data) { return j }
        let text = String(decoding: data, as: UTF8.self)
        var found: JSONValue?
        for ev in SSEParser.parseAll(text) {
            if let j = JSONValue.parse(ev.data), j["result"] != nil || j["error"] != nil { found = j }
        }
        return found
    }

    public static func parseTools(_ root: JSONValue?) -> [McpToolInfo] {
        (root?["result"]?["tools"]?.arrayValue ?? []).compactMap { t in
            guard let name = t["name"]?.stringValue else { return nil }
            return McpToolInfo(name: name, description: t["description"]?.stringValue, inputSchema: t["inputSchema"])
        }
    }

    /// tools/call 结果 → 给模型的文本（安卓 formatMcpResult）。
    public static func formatResult(_ data: Data) -> String {
        guard let root = parseResponse(data) else { return String(String(decoding: data, as: UTF8.self).prefix(4000)) }
        if let e = root["error"], !e.isNull {
            return "MCP failed: \(e["message"]?.stringValue ?? e.jsonString())"
        }
        let result = root["result"]
        let parts = (result?["content"]?.arrayValue ?? []).compactMap { c -> String? in
            c["text"]?.stringValue ?? c["data"]?.stringValue ?? c["url"]?.stringValue ?? c["resource"]?["text"]?.stringValue
        }
        var text = parts.isEmpty ? String((result ?? .null).jsonString().prefix(4000)) : parts.joined(separator: "\n")
        if result?["isError"]?.boolValue == true { text = "MCP failed: " + text }
        return text
    }
}

/// MCP 会话客户端：缓存每个服务器的 Mcp-Session-Id。
public actor McpClient {
    private let session: URLSession
    private var sessions: [String: String] = [:]
    private var stateless: Set<String> = []

    public init(session: URLSession = .shared) { self.session = session }

    private func post(_ server: McpServer, _ body: Data, sessionId: String?) async throws -> (Int, Data, [AnyHashable: Any]) {
        guard let url = URL(string: server.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            throw ProviderError.invalidURL(server.endpoint)
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        for (k, v) in McpRPC.headers(server, sessionId: sessionId) { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        let (data, resp) = try await session.data(for: r)
        let http = resp as? HTTPURLResponse
        return (http?.statusCode ?? 0, data, http?.allHeaderFields ?? [:])
    }

    /// 握手；成功返回会话 id（服务器不发会话 id 时返回 ""）；失败返回 nil 并标为无状态服务器。
    private func ensureSession(_ server: McpServer) async -> String? {
        if stateless.contains(server.id) { return nil }
        if let s = sessions[server.id] { return s }
        let params: JSONValue = ["protocolVersion": .string(McpRPC.protocolVersion), "capabilities": [:],
                                 "clientInfo": ["name": "MolaGPT-iOS", "version": "1.0"]]
        guard let (status, data, headers) = try? await post(server, McpRPC.body(method: "initialize", id: "init-1", params: params), sessionId: nil),
              (200..<300).contains(status), let root = McpRPC.parseResponse(data), root["result"] != nil else {
            stateless.insert(server.id); return nil
        }
        let sid = headers.first { ($0.key as? String)?.lowercased() == "mcp-session-id" }?.value as? String ?? ""
        sessions[server.id] = sid
        _ = try? await post(server, McpRPC.body(method: "notifications/initialized", id: nil), sessionId: sid.nonBlank)
        return sid
    }

    private func call(_ server: McpServer, method: String, id: String, params: JSONValue?) async throws -> (Int, Data) {
        let sid = await ensureSession(server)
        var (status, data, _) = try await post(server, McpRPC.body(method: method, id: id, params: params), sessionId: sid?.nonBlank)
        if status == 404, sid != nil {
            // 会话过期：重新握手一次
            sessions[server.id] = nil
            let again = await ensureSession(server)
            (status, data, _) = try await post(server, McpRPC.body(method: method, id: id, params: params), sessionId: again?.nonBlank)
        }
        return (status, data)
    }

    public func listTools(_ server: McpServer) async throws -> [McpToolInfo] {
        let (status, data) = try await call(server, method: "tools/list", id: IDs.generic("rpc"), params: nil)
        guard (200..<300).contains(status) else { throw ProviderError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        if let e = McpRPC.parseResponse(data)?["error"], !e.isNull {
            throw ProviderError.decoding(e["message"]?.stringValue ?? "tools/list 失败")
        }
        return McpRPC.parseTools(McpRPC.parseResponse(data))
    }

    public func callTool(_ server: McpServer, tool: String, arguments: JSONValue, id: String) async -> String {
        do {
            let (status, data) = try await call(server, method: "tools/call", id: id, params: ["name": .string(tool), "arguments": arguments])
            guard (200..<300).contains(status) else {
                return "MCP failed: HTTP \(status) \(String(String(decoding: data, as: UTF8.self).prefix(800)))"
            }
            return McpRPC.formatResult(data)
        } catch {
            return "MCP failed: \(error.localizedDescription)"
        }
    }

    public func reset(_ serverId: String) { sessions[serverId] = nil; stateless.remove(serverId) }
}
