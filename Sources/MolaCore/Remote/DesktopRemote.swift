import Foundation

// 电脑远程（账号模式）协议（对应安卓 DesktopRemoteService / RemotePairing / DesktopMessageMapper）。
// 规格见 IOS/specs/desktop-remote-account.md。加密（ECDH/HKDF）在 App 层用 CryptoKit；签名用 MolaCore 的 HMAC。

public struct DesktopConversation: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var modelLabel: String?
    public var providerLabel: String?
    public var updatedAtMs: Int64
    public var busy: Bool
    public var pendingApprovals: Int
}

public struct DesktopMachine: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var appVersion: String?
    public var online: Bool
    public var lastSeenAtMs: Int64
    public var conversations: [DesktopConversation]
}

public enum DesktopProtocol {
    public static let accountContext = "molagpt-account-pair-v1"
    public static let secretInfo = "molagpt-remote-pair-v1"

    public static func parseDesktops(_ j: JSONValue) -> [DesktopMachine] {
        (j["desktops"]?.arrayValue ?? []).compactMap { d in
            guard let id = d["machineId"]?.stringValue else { return nil }
            let convs = (d["conversations"]?.arrayValue ?? []).compactMap { c -> DesktopConversation? in
                guard let cid = c["id"]?.stringValue else { return nil }
                return DesktopConversation(id: cid, title: c["title"]?.stringValue?.nonBlank ?? "新对话", modelLabel: c["modelLabel"]?.stringValue,
                                           providerLabel: c["providerLabel"]?.stringValue, updatedAtMs: Int64(c["updatedAtMs"]?.doubleValue ?? 0),
                                           busy: MolaJSON.bool(c["busy"]) ?? false, pendingApprovals: MolaJSON.int(c["pendingApprovals"]) ?? 0)
            }
            return DesktopMachine(id: id, name: d["machineName"]?.stringValue?.nonBlank ?? "电脑", appVersion: d["appVersion"]?.stringValue,
                                  online: MolaJSON.bool(d["online"]) ?? false, lastSeenAtMs: Int64(d["lastSeenAtMs"]?.doubleValue ?? 0),
                                  conversations: convs.sorted { $0.updatedAtMs > $1.updatedAtMs })
        }
    }

    /// 签名：base64url_nopad(HMAC-SHA256(secret, "id\nop\nts\npairId\na"))。
    public static func sign(secret: [UInt8], id: String, op: String, ts: Int64, pairId: String, args: String) -> String {
        SHA256.base64url(SHA256.hmac(key: secret, message: Array("\(id)\n\(op)\n\(ts)\n\(pairId)\n\(args)".utf8)))
    }

    /// 发给电脑的帧：`{to, body:{v,id,op,ts,a,pair,sig}}`；`a` 是 JSON 字符串。pair_account 不签名。
    public static func frame(to machineId: String, id: String, op: String, args: JSONValue, pairId: String?, secret: [UInt8]?, ts: Int64 = IDs.nowMs()) -> String {
        let a = args.jsonString()
        var sig = ""
        if let pairId, let secret { sig = sign(secret: secret, id: id, op: op, ts: ts, pairId: pairId, args: a) }
        let body: JSONValue = ["v": 1, "id": .string(id), "op": .string(op), "ts": .number(Double(ts)), "a": .string(a),
                               "pair": .string(pairId ?? ""), "sig": .string(sig)]
        return JSONValue.object(["to": .string(machineId), "body": body]).jsonString()
    }

    /// 配对 mac：HMAC-SHA256(secret, "molagpt-account-pair-v1|phonePub|desktopPub|pairId")，Base64。
    public static func pairMac(secret: [UInt8], phonePub: String, desktopPub: String, pairId: String) -> String {
        Data(SHA256.hmac(key: secret, message: Array("\(accountContext)|\(phonePub)|\(desktopPub)|\(pairId)".utf8))).base64EncodedString()
    }

    /// 新对话 id：`chat_<毫秒>_<9 位 [a-z0-9]>`。
    public static func newConversationId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var g = SystemRandomNumberGenerator()
        return "chat_\(IDs.nowMs())_" + String((0..<9).map { _ in chars[Int.random(in: 0..<chars.count, using: &g)] })
    }
}

public struct DesktopApproval: Sendable, Hashable, Identifiable {
    public var id: String
    public var toolName: String
    public var displayName: String?
    public var summary: String?
    public var argumentsPreview: String?
    public var codePreview: String?
    public var options: [String]

    public static func parse(_ j: JSONValue) -> DesktopApproval? {
        guard let id = j["requestId"]?.stringValue else { return nil }
        return DesktopApproval(id: id, toolName: j["toolName"]?.stringValue ?? "工具", displayName: j["displayName"]?.stringValue,
                               summary: j["summary"]?.stringValue, argumentsPreview: j["argumentsPreview"]?.stringValue,
                               codePreview: j["codePreview"]?.stringValue,
                               options: j["options"]?.arrayValue?.compactMap(\.stringValue) ?? ["once", "deny"])
    }
}

/// 电脑消息 → ChatMessage（思考段与工具卡按 UTF-16 偏移插回正文）。
public enum DesktopMessageMapper {
    public static func map(_ j: JSONValue, conversationId: String) -> ChatMessage? {
        guard let id = j["id"]?.stringValue else { return nil }
        let role: Role = j["role"]?.stringValue == "user" ? .user : .assistant
        let created = Int64(j["createdAtMs"]?.doubleValue ?? Double(IDs.nowMs()))
        let content = j["content"]?.stringValue ?? ""
        let meta = j["meta"]
        if role == .user {
            var m = ChatMessage(messageId: id, sessionId: conversationId, role: .user, status: .complete, createdAt: created,
                                fragments: content.isEmpty ? [] : [.text(id: "\(id):t0", markdown: content)])
            if j["kind"]?.stringValue == "task_notification" { m.metadata["task_notification"] = "1" }
            return m
        }
        let streaming = MolaJSON.bool(meta?["streaming"]) ?? false
        let stopped = MolaJSON.bool(meta?["stopped"]) ?? false
        var inserts: [(offset: Int, order: Int, frag: MessageFragment)] = []
        let utf16Count = content.utf16.count
        func clamp(_ v: Int?) -> Int { min(max(v ?? utf16Count, 0), utf16Count) }
        let segments = meta?["thinking_segments"]?.arrayValue ?? []
        if segments.isEmpty, let t = meta?["thinking"]?.stringValue?.nonBlank {
            inserts.append((0, -1, .thinking(id: "\(id):th0", text: t, collapsed: true, durationMs: nil)))
        }
        for (i, s) in segments.enumerated() {
            guard let src = s["source"]?.stringValue?.nonBlank else { continue }
            let secs = s["elapsed_seconds"]?.doubleValue
            inserts.append((clamp(MolaJSON.int(s["content_offset"])), MolaJSON.int(s["timeline_index"]) ?? i,
                            .thinking(id: "\(id):th\(i)", text: src, collapsed: true, durationMs: secs.map { Int64($0 * 1000) })))
        }
        for (i, t) in (meta?["tool_calls"]?.arrayValue ?? []).enumerated() {
            let tid = t["id"]?.stringValue ?? "p\(i)"
            let raw = (t["status"]?.stringValue ?? "").lowercased()
            var status: ToolStatus = ["completed", "succeeded", "success"].contains(raw) ? .success
                : ["failed", "cancelled", "canceled", "error", "denied", "interrupted"].contains(raw) ? .failed : .running
            if t["background_task_id"]?.stringValue != nil {
                let ts = t["task_state"]?.stringValue
                status = ts == "running" ? .running : ts == "completed" ? .success : .failed
            }
            let name = t["name"]?.stringValue ?? "tool"
            let frag = ToolCallFragment(id: "\(id):tool:\(tid)", name: name, status: status,
                                        label: t["label"]?.stringValue ?? t["summary"]?.stringValue ?? ToolLabels.label(name),
                                        argsJson: t["arguments_json"]?.stringValue,
                                        resultPreview: t["detail"]?.stringValue ?? t["result_preview_json"]?.stringValue, provider: "desktop")
            inserts.append((clamp(MolaJSON.int(t["content_offset"])), MolaJSON.int(t["timeline_index"]) ?? (1000 + i), .tool(frag)))
        }
        inserts.sort { $0.offset != $1.offset ? $0.offset < $1.offset : $0.order < $1.order }
        var fragments: [MessageFragment] = []
        let units = Array(content.utf16)
        var cursor = 0
        var n = 0
        func text(_ from: Int, _ to: Int) {
            guard to > from, let s = String(utf16CodeUnits: Array(units[from..<to]), count: to - from).nonBlank else { return }
            fragments.append(.text(id: "\(id):t\(n)", markdown: s)); n += 1
        }
        for ins in inserts {
            text(cursor, ins.offset)
            cursor = max(cursor, ins.offset)
            fragments.append(ins.frag)
        }
        text(cursor, units.count)
        if let srcs = meta?["sources"]?.arrayValue, !srcs.isEmpty {
            let refs = srcs.enumerated().compactMap { i, s -> SourceReference? in
                guard let u = s["url"]?.stringValue else { return nil }
                return SourceReference(title: s["title"]?.stringValue ?? u, url: u, snippet: nil, index: i + 1)
            }
            fragments.append(.search(id: "\(id):src", query: "", refs: refs, status: .done))
        }
        if stopped && fragments.isEmpty { fragments.append(.tip(id: "\(id):stopped", text: "已停止")) }
        var stats: MessageStats?
        if let rs = meta?["response_stats"], rs.objectValue != nil {
            stats = MessageStats(usage: Usage(promptTokens: MolaJSON.int(rs["promptTokens"]), completionTokens: MolaJSON.int(rs["completionTokens"]) ?? MolaJSON.int(rs["answerTokens"]),
                                              totalTokens: MolaJSON.int(rs["totalTokens"]), reasoningTokens: MolaJSON.int(rs["reasoningTokens"]),
                                              cachedTokens: MolaJSON.int(rs["cacheReadTokens"])),
                                 durationMs: rs["totalTime"]?.doubleValue.map { Int64($0) }, ttftMs: rs["ttft"]?.doubleValue.map { Int64($0) })
        }
        return ChatMessage(messageId: id, sessionId: conversationId, role: .assistant,
                           status: streaming ? .streaming : stopped ? .stopped : .complete, createdAt: created,
                           fragments: fragments, stats: stats)
    }
}
