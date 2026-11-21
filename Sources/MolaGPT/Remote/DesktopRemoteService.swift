import Foundation
import Observation
import CryptoKit
import UIKit
import MolaCore
import MolaStorage

/// 电脑远程（账号模式）：电脑列表（HTTP）、实时通道（WebSocket）、配对（P-256 ECDH + HKDF + HMAC）、签名请求与推送。
@MainActor
@Observable
final class DesktopRemoteService {
    @ObservationIgnored unowned let app: AppModel
    private(set) var desktops: [DesktopMachine] = []
    private(set) var onlineMachines: Set<String> = []
    private(set) var connected = false
    var error: String?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    @ObservationIgnored private var pushHandlers: [String: (JSONValue) -> Void] = [:]   // conversationId → handler
    @ObservationIgnored private var reconnectDelay: Double = 1
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    enum RemoteError: LocalizedError {
        case notLoggedIn, offline, unpaired, failed(String, String?), authFailed, timeout
        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "请先登录 MolaGPT 账户"
            case .offline: return "电脑已离线"
            case .unpaired: return "配对已失效，请重新配对"
            case .failed(let c, let m): return m ?? "请求失败（\(c)）"
            case .authFailed: return "身份验证失败，请重新配对"
            case .timeout: return "请求超时"
            }
        }
    }

    // MARK: 电脑列表

    func refreshDesktops() async {
        guard app.account.isLoggedIn else { return }
        do {
            desktops = DesktopProtocol.parseDesktops(try await app.account.session.authedGet(MolaEndpoints.agentDesktops))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 忘掉电脑：先删本地配对，再发 DELETE（忽略失败）。
    func forget(_ machineId: String) async {
        Keychain.delete(pairKey(machineId))
        guard let t = try? await app.account.session.validJWT() else { return }
        var c = URLComponents(url: MolaEndpoints.url(MolaEndpoints.agentDesktops), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "machineId", value: machineId)]
        var r = URLRequest(url: c.url!)
        r.httpMethod = "DELETE"
        r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        r.setValue(MolaUA.fixed, forHTTPHeaderField: "User-Agent")
        _ = try? await URLSession.shared.data(for: r)
        await refreshDesktops()
    }

    func isOnline(_ m: DesktopMachine) -> Bool { connected ? onlineMachines.contains(m.id) : m.online }

    // MARK: 配对存储（按账号隔离）

    private func pairKey(_ machineId: String) -> String {
        let user = app.account.username ?? "anon"
        return "remote.pair.\(MolaCore.SHA256.hex(Array(MolaCore.SHA256.hash(user).prefix(8)))).\(machineId)"
    }

    func pairing(_ machineId: String) -> (pairId: String, secret: [UInt8])? {
        guard let s = Keychain.get(pairKey(machineId)), let bar = s.firstIndex(of: "|"),
              let secret = Data(base64Encoded: String(s[s.index(after: bar)...])) else { return nil }
        return (String(s[..<bar]), [UInt8](secret))
    }

    func isPaired(_ machineId: String) -> Bool { pairing(machineId) != nil }

    static var deviceId: String {
        let key = "molagpt.remote.device_id"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = "ios-" + (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString).lowercased()
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    /// pair_account：手机 P-256 公钥（SPKI DER Base64）→ 电脑回 pub/mac/pairId → HKDF 派生 secret → 校验 mac → 存储。
    func pair(_ machineId: String) async throws {
        try await ensureConnected()
        let jwtBefore = app.account.jwt
        let priv = P256.KeyAgreement.PrivateKey()
        let phonePub = priv.publicKey.derRepresentation.base64EncodedString()
        let args: JSONValue = ["pub": .string(phonePub), "device": .string(String(UIDevice.current.name.prefix(60))), "deviceId": .string(Self.deviceId)]
        let data = try await request(machineId, op: "pair_account", args: args, signed: false)
        guard let desktopPub = data["pub"]?.stringValue, let pairId = data["pairId"]?.stringValue, let mac = data["mac"]?.stringValue,
              let pubData = Data(base64Encoded: desktopPub), let peer = try? P256.KeyAgreement.PublicKey(derRepresentation: pubData) else {
            throw RemoteError.authFailed
        }
        let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
        let key = shared.hkdfDerivedSymmetricKey(using: CryptoKit.SHA256.self, salt: Data(DesktopProtocol.accountContext.utf8),
                                                 sharedInfo: Data(DesktopProtocol.secretInfo.utf8), outputByteCount: 32)
        let secret = key.withUnsafeBytes { [UInt8]($0) }
        let expected = DesktopProtocol.pairMac(secret: secret, phonePub: phonePub, desktopPub: desktopPub, pairId: pairId)
        guard let macData = Data(base64Encoded: mac), constantTimeEqual(macData, Data(base64Encoded: expected) ?? Data()) else { throw RemoteError.authFailed }
        guard app.account.jwt == jwtBefore else { throw RemoteError.notLoggedIn }
        Keychain.set(pairKey(machineId), "\(pairId)|\(Data(secret).base64EncodedString())")
    }

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: 实时通道

    func ensureConnected() async throws {
        if connected, socket != nil { return }
        guard app.account.isLoggedIn else { throw RemoteError.notLoggedIn }
        let j = try await app.account.session.authedGet(MolaEndpoints.agentRealtime + "?role=terminal")
        guard let ticket = j["ticket"]?.stringValue else { throw RemoteError.failed("ticket", "实时通道连接失败") }
        var r = URLRequest(url: URL(string: MolaEndpoints.realtimeSocket)!)
        r.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        r.setValue(MolaUA.fixed, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 12
        let task = URLSession.shared.webSocketTask(with: r)
        socket = task
        task.resume()
        connected = true
        reconnectDelay = 1
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                task.sendPing { _ in }
                _ = self
            }
        }
    }

    func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        pingTask?.cancel()
        receiveTask?.cancel()
        failAll(RemoteError.failed("disconnected", "连接已断开"))
    }

    private func failAll(_ e: Error) {
        let p = pending
        pending.removeAll()
        for (_, c) in p { c.resume(throwing: e) }
        onlineMachines.removeAll()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                let text: String
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                if let j = JSONValue.parse(text) { handle(j) }
            } catch {
                guard socket === task else { return }
                connected = false
                socket = nil
                failAll(RemoteError.failed("disconnected", "连接已断开"))
                // 有页面在用时按 1/2/4/8/15 秒退避重连
                if !pushHandlers.isEmpty {
                    try? await Task.sleep(for: .seconds(reconnectDelay))
                    reconnectDelay = [1, 2, 4, 8, 15].first { $0 > reconnectDelay } ?? 15
                    try? await ensureConnected()
                }
                return
            }
        }
    }

    private func handle(_ j: JSONValue) {
        if let body = j["body"] {
            if let re = body["re"]?.stringValue, let c = pending.removeValue(forKey: re) {
                if MolaJSON.bool(body["ok"]) == true { c.resume(returning: body["data"] ?? .null) }
                else {
                    let code = body["code"]?.stringValue ?? "error"
                    if code == "unpaired", let from = j["from"]?.stringValue { Keychain.delete(pairKey(from)) }
                    c.resume(throwing: code == "unpaired" ? RemoteError.unpaired : RemoteError.failed(code, body["message"]?.stringValue))
                }
                return
            }
            if body["ev"] != nil, let cid = body["conversationId"]?.stringValue { pushHandlers[cid]?(body) }
            return
        }
        switch j["kind"]?.stringValue {
        case "connected":
            onlineMachines = Set(j["machines"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            Task { await refreshDesktops() }
        case "presence":
            if let m = j["machineId"]?.stringValue {
                if MolaJSON.bool(j["online"]) == true { onlineMachines.insert(m) } else { onlineMachines.remove(m) }
            }
            Task { await refreshDesktops() }
        case "undeliverable":
            if let ref = j["ref"]?.stringValue, let c = pending.removeValue(forKey: ref) { c.resume(throwing: RemoteError.offline) }
        case "sessions":
            if j["sessionId"]?.stringValue?.nonBlank == nil { Task { await refreshDesktops() } }
        default: break
        }
    }

    /// 签名请求，30 秒超时。
    func request(_ machineId: String, op: String, args: JSONValue, signed: Bool = true) async throws -> JSONValue {
        try await ensureConnected()
        var pair: (pairId: String, secret: [UInt8])?
        if signed {
            guard let p = pairing(machineId) else { throw RemoteError.unpaired }
            pair = p
        }
        let id = UUID().uuidString.lowercased()
        let frame = DesktopProtocol.frame(to: machineId, id: id, op: op, args: args, pairId: pair?.pairId, secret: pair?.secret)
        guard let socket else { throw RemoteError.offline }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
            pending[id] = c
            socket.send(.string(frame)) { [weak self] err in
                guard let err else { return }
                Task { @MainActor in self?.pending.removeValue(forKey: id)?.resume(throwing: err) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.pending.removeValue(forKey: id)?.resume(throwing: RemoteError.timeout)
            }
        }
    }

    func subscribe(_ conversationId: String, _ handler: @escaping (JSONValue) -> Void) { pushHandlers[conversationId] = handler }
    func unsubscribe(_ conversationId: String) {
        pushHandlers[conversationId] = nil
        // 无人订阅 30 秒后断开
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            if let self, self.pushHandlers.isEmpty { self.disconnect() }
        }
    }
}

/// 一段电脑对话的状态（对应安卓 RemoteConversationViewModel）：open + 连续 seq 推送，有缺口就重新 open。
@MainActor
@Observable
final class RemoteConversationModel {
    let machineId: String
    var conversationId: String
    private(set) var messages: [ChatMessage] = []
    private(set) var title = ""
    private(set) var busy = false
    private(set) var approvals: [DesktopApproval] = []
    private(set) var settings: JSONValue?
    var error: String?
    private var seq: Int64 = 0
    private var opening = false
    private var buffered: [JSONValue] = []
    @ObservationIgnored unowned let service: DesktopRemoteService

    init(service: DesktopRemoteService, machineId: String, conversationId: String) {
        self.service = service; self.machineId = machineId; self.conversationId = conversationId
    }

    func open() async {
        opening = true
        defer { opening = false }
        service.subscribe(conversationId) { [weak self] body in self?.onPush(body) }
        do {
            let d = try await service.request(machineId, op: "open", args: ["conversationId": .string(conversationId), "limit": 30])
            seq = Int64(d["seq"]?.doubleValue ?? 0)
            title = d["conversation"]?["title"]?.stringValue ?? title
            busy = MolaJSON.bool(d["conversation"]?["busy"]) ?? false
            settings = d["conversation"]?["settings"]
            messages = (d["messages"]?.arrayValue ?? []).compactMap { DesktopMessageMapper.map($0, conversationId: conversationId) }
            approvals = (d["approvals"]?.arrayValue ?? []).compactMap(DesktopApproval.parse)
            error = nil
            let replay = buffered
            buffered = []
            for b in replay { onPush(b) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func close() {
        service.unsubscribe(conversationId)
        let (m, c) = (machineId, conversationId)
        Task { [service] in _ = try? await service.request(m, op: "close", args: ["conversationId": .string(c)]) }
    }

    private func onPush(_ body: JSONValue) {
        if opening { buffered.append(body); return }
        let s = Int64(body["seq"]?.doubleValue ?? 0)
        if s <= seq { return }
        if s != seq + 1 { Task { await open() }; return }
        seq = s
        let data = body["data"] ?? .null
        switch body["ev"]?.stringValue {
        case "upsert":
            guard let m = DesktopMessageMapper.map(data, conversationId: conversationId) else { return }
            if let i = messages.firstIndex(where: { $0.messageId == m.messageId }) { messages[i] = m } else { messages.append(m) }
            if m.role == .user { messages.removeAll { $0.metadata["local_pending"] == "1" && $0.text == m.text } }
            messages.sort { $0.createdAt < $1.createdAt }
        case "remove":
            if let id = data["id"]?.stringValue { messages.removeAll { $0.messageId == id } }
        case "state":
            if let b = MolaJSON.bool(data["busy"]) { busy = b }
            if let t = data["title"]?.stringValue { title = t }
        case "settings": settings = data
        case "approval": if let a = DesktopApproval.parse(data), !approvals.contains(where: { $0.id == a.id }) { approvals.append(a) }
        case "resolved": if let id = data["requestId"]?.stringValue { approvals.removeAll { $0.id == id } }
        case "reset": Task { await open() }
        default: break
        }
    }

    func send(_ text: String) async {
        let cmd = UUID().uuidString.lowercased()
        var local = ChatMessage(sessionId: conversationId, role: .user, fragments: [.text(id: IDs.fragment(), markdown: text)])
        local.metadata["local_pending"] = "1"
        messages.append(local)
        do {
            _ = try await service.request(machineId, op: "send", args: ["conversationId": .string(conversationId), "text": .string(text), "attachments": [], "cmdId": .string(cmd)])
            busy = true
        } catch {
            // 重试必须复用同一个 cmdId
            do {
                _ = try await service.request(machineId, op: "send", args: ["conversationId": .string(conversationId), "text": .string(text), "attachments": [], "cmdId": .string(cmd)])
            } catch {
                messages.removeAll { $0.messageId == local.messageId }
                self.error = error.localizedDescription
            }
        }
    }

    func stop() async { _ = try? await service.request(machineId, op: "stop", args: ["conversationId": .string(conversationId)]) }

    func approve(_ a: DesktopApproval, _ decision: String) async {
        do {
            _ = try await service.request(machineId, op: "approve", args: ["requestId": .string(a.id), "decision": .string(decision)])
            approvals.removeAll { $0.id == a.id }
        } catch DesktopRemoteService.RemoteError.failed("resolved", _) {
            approvals.removeAll { $0.id == a.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
