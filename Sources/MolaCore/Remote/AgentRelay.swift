import Foundation

// 远程 Agent（Claude Code / Codex）控制（对应安卓 AgentRelay.kt / AgentControlService / AgentTranscriptReducer）。
// 事件流用 HTTP 轮询（线上 Cloudflare 对 SSE 稳定 524）。

public enum AgentPhase: Int, Sendable, Codable { case idle = 0, spawning, running, waiting, completed, failed
    public var label: String {
        switch self { case .idle: return "空闲"; case .spawning: return "启动中"; case .running: return "运行中"; case .waiting: return "等待审批"; case .completed: return "已完成"; case .failed: return "失败" }
    }
}

public struct AgentModelOption: Sendable, Hashable { public var id: String; public var displayName: String; public var efforts: [String] }

public struct RelaySession: Sendable, Hashable, Identifiable {
    public var id: String
    public var backendId: String
    public var title: String
    public var workingDirectory: String?
    public var model: String?
    public var reasoningEffort: String?
    public var availableModels: [AgentModelOption]
    public var machineId: String?
    public var machineName: String?
    public var phase: AgentPhase
    public var permissionMode: Int
    public var needsAttention: Bool
    public var seq: Int
    public var updatedAtMs: Int64
    public var lastCommandError: String?

    public var backendLabel: String { backendId == "codex" ? "Codex" : "Claude Code" }
}

public struct RelayMachine: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var lastSeenAtMs: Int64
    /// 心跳超过 45 秒视为离线。
    public func online(now: Int64 = IDs.nowMs()) -> Bool { now - lastSeenAtMs < 45_000 }
}

/// 解析需兼容 camel / snake / Pascal 三种键名。
enum Keys {
    static func get(_ j: JSONValue?, _ names: String...) -> JSONValue? {
        guard let o = j?.objectValue else { return nil }
        for n in names {
            if let v = o[n] { return v }
            let snake = n.unicodeScalars.reduce("") { $0 + (CharacterSet.uppercaseLetters.contains($1) ? "_" + String($1).lowercased() : String($1)) }
            if let v = o[snake] { return v }
            let pascal = n.prefix(1).uppercased() + n.dropFirst()
            if let v = o[pascal] { return v }
        }
        return nil
    }
}

public enum AgentRelayAPI {
    public static func parseSessions(_ j: JSONValue) -> (sessions: [RelaySession], machines: [RelayMachine]) {
        let machines = (j["machines"]?.arrayValue ?? []).compactMap { m -> RelayMachine? in
            guard let id = Keys.get(m, "id")?.stringValue else { return nil }
            return RelayMachine(id: id, name: Keys.get(m, "name")?.stringValue ?? id, lastSeenAtMs: Int64(Keys.get(m, "lastSeenAtMs")?.doubleValue ?? 0))
        }
        let sessions = (j["sessions"]?.arrayValue ?? []).compactMap { s -> RelaySession? in
            guard let id = Keys.get(s, "conversationId", "sessionId", "id")?.stringValue else { return nil }
            let models = (Keys.get(s, "availableModels")?.arrayValue ?? []).compactMap { m -> AgentModelOption? in
                guard let mid = Keys.get(m, "id")?.stringValue else { return nil }
                return AgentModelOption(id: mid, displayName: Keys.get(m, "displayName")?.stringValue ?? mid,
                                        efforts: (Keys.get(m, "reasoningEfforts")?.arrayValue ?? []).compactMap(\.stringValue))
            }
            return RelaySession(id: id, backendId: Keys.get(s, "backendId")?.stringValue ?? "claude-code",
                                title: Keys.get(s, "title")?.stringValue?.nonBlank ?? "未命名会话",
                                workingDirectory: Keys.get(s, "workingDirectory")?.stringValue, model: Keys.get(s, "model")?.stringValue,
                                reasoningEffort: Keys.get(s, "reasoningEffort")?.stringValue, availableModels: models,
                                machineId: Keys.get(s, "machineId")?.stringValue, machineName: Keys.get(s, "machineName")?.stringValue,
                                phase: AgentPhase(rawValue: Keys.get(s, "phase")?.intValue ?? 0) ?? .idle,
                                permissionMode: Keys.get(s, "permissionMode")?.intValue ?? 2,
                                needsAttention: Keys.get(s, "needsAttention")?.boolValue ?? false, seq: Keys.get(s, "seq")?.intValue ?? 0,
                                updatedAtMs: Int64(Keys.get(s, "updatedAtMs", "activityAtMs")?.doubleValue ?? 0),
                                lastCommandError: Keys.get(s, "lastCommandError")?.stringValue)
        }
        return (sessions.sorted { $0.updatedAtMs > $1.updatedAtMs }, machines)
    }

    public static func cmdId() -> String {
        var g = SystemRandomNumberGenerator()
        return "app-" + (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    public enum Op: Sendable {
        case send(String), interrupt, approve(permissionId: String, choice: String), new(backend: String, workingDirectory: String?, title: String?, model: String?)
        case switchOptions(model: String?, effort: String?, permissionMode: Int?), close

        var name: String {
            switch self { case .send: return "Send"; case .interrupt: return "Interrupt"; case .approve: return "Approve"; case .new: return "New"; case .switchOptions: return "SwitchOptions"; case .close: return "Close" }
        }

        var payload: JSONValue {
            switch self {
            case .send(let t): return ["text": .string(t), "images": []]
            case .interrupt, .close: return [:]
            case .approve(let id, let c): return ["permissionId": .string(id), "choice": .string(c)]
            case .new(let b, let wd, let t, let m):
                var o: [String: JSONValue] = ["backendId": .string(b)]
                if let wd { o["workingDirectory"] = .string(wd) }
                if let t { o["title"] = .string(t) }
                if let m { o["model"] = .string(m) }
                return .object(o)
            case .switchOptions(let m, let e, let pm):
                var o: [String: JSONValue] = [:]
                if let m { o["model"] = .string(m) }
                if let e { o["reasoningEffort"] = .string(e) }
                if let pm { o["permissionMode"] = .number(Double(pm)) }
                return .object(o)
            }
        }
    }

    public static func command(sessionId: String, op: Op, machineId: String?) -> JSONValue {
        var o: [String: JSONValue] = ["sessionId": .string(sessionId), "cmdId": .string(cmdId()), "op": .string(op.name), "payloadJson": .string(op.payload.jsonString())]
        if let machineId { o["machineId"] = .string(machineId) }
        return .object(o)
    }
}

/// 转录折叠：按 segmentId upsert 块；回合结束时折叠未处理的权限提示。
public struct AgentTranscript: Sendable {
    public enum Block: Sendable, Identifiable, Hashable {
        case user(id: String, text: String)
        case answer(id: String, text: String)
        case thinking(id: String, text: String)
        case tool(id: String, fragment: ToolCallFragment)
        case permission(id: String, tool: String, description: String, args: String?, resolved: Bool)
        case status(id: String, text: String, failed: Bool)

        public var id: String {
            switch self {
            case .user(let id, _), .answer(let id, _), .thinking(let id, _), .tool(let id, _), .permission(let id, _, _, _, _), .status(let id, _, _): return id
            }
        }
    }

    public private(set) var blocks: [Block] = []
    public private(set) var latestSeq = 0
    public private(set) var usage: Usage?

    public init() {}

    private mutating func upsert(_ b: Block) {
        if let i = blocks.firstIndex(where: { $0.id == b.id }) { blocks[i] = b } else { blocks.append(b) }
    }

    public mutating func apply(_ events: [JSONValue]) {
        for wrapper in events {
            let seq = Keys.get(wrapper, "seq")?.intValue ?? 0
            if seq <= latestSeq && seq != 0 { continue }
            latestSeq = max(latestSeq, seq)
            let e = Keys.get(wrapper, "event") ?? wrapper
            let kind = (Keys.get(e, "kind")?.stringValue ?? "").lowercased()
            switch kind {
            case "userprompt", "user_prompt":
                upsert(.user(id: "u\(seq)", text: Keys.get(e, "text")?.stringValue ?? ""))
            case "answersnapshot", "answer_snapshot":
                upsert(.answer(id: "a-" + (Keys.get(e, "segmentId")?.stringValue ?? "\(seq)"), text: Keys.get(e, "text")?.stringValue ?? ""))
            case "thinkingsnapshot", "thinking_snapshot":
                upsert(.thinking(id: "t-" + (Keys.get(e, "segmentId")?.stringValue ?? "\(seq)"), text: Keys.get(e, "text")?.stringValue ?? ""))
            case "toolprogress", "tool_progress":
                let t = Keys.get(e, "tool")
                let tid = Keys.get(t, "id")?.stringValue ?? "\(seq)"
                let st: ToolStatus = [.running, .success, .failed, .cancelled][min(3, max(0, Keys.get(t, "status")?.intValue ?? 0))]
                let name = Keys.get(t, "name")?.stringValue ?? "tool"
                upsert(.tool(id: "tool-\(tid)", fragment: ToolCallFragment(id: "tool-\(tid)", name: name, status: st,
                                                                          label: Keys.get(t, "title")?.stringValue ?? name,
                                                                          argsJson: Keys.get(t, "argumentsJson")?.stringValue,
                                                                          resultPreview: Keys.get(t, "resultPreview")?.stringValue)))
            case "permissionprompt", "permission_prompt":
                let p = Keys.get(e, "permission")
                let pid = Keys.get(p, "id")?.stringValue ?? "\(seq)"
                upsert(.permission(id: pid, tool: Keys.get(p, "toolName")?.stringValue ?? "工具", description: Keys.get(p, "description")?.stringValue ?? "",
                                   args: Keys.get(p, "argumentsJson")?.stringValue, resolved: false))
            case "turndone", "turn_done":
                let u = Keys.get(e, "usage")
                usage = Usage(promptTokens: Keys.get(u, "inputTokens")?.intValue, completionTokens: Keys.get(u, "outputTokens")?.intValue,
                              totalTokens: Keys.get(u, "totalTokens")?.intValue)
                resolvePermissions()
            case "turnfailed", "turn_failed":
                upsert(.status(id: "f\(seq)", text: Keys.get(e, "message")?.stringValue ?? "运行失败", failed: true))
                resolvePermissions()
            case "historyreset", "history_reset":
                blocks.removeAll()
            default: break
            }
        }
    }

    public mutating func resolvePermission(_ id: String) {
        if let i = blocks.firstIndex(where: { $0.id == id }), case .permission(let id, let t, let d, let a, _) = blocks[i] {
            blocks[i] = .permission(id: id, tool: t, description: d, args: a, resolved: true)
        }
    }

    private mutating func resolvePermissions() {
        for b in blocks { if case .permission(let id, _, _, _, false) = b { resolvePermission(id) } }
    }
}
