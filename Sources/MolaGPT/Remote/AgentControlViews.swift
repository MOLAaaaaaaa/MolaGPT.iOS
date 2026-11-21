import SwiftUI
import Observation
import MolaCore
import MolaStorage

/// 远程 Agent 会话列表 + 事件轮询（对应安卓 AgentControlService / AgentControlViewModel）。
@MainActor
@Observable
final class AgentControlModel {
    @ObservationIgnored unowned let app: AppModel
    private(set) var sessions: [RelaySession] = []
    private(set) var machines: [RelayMachine] = []
    private(set) var transcripts: [String: AgentTranscript] = [:]
    var error: String?
    private(set) var loading = false
    @ObservationIgnored private var pollers: [String: Task<Void, Never>] = [:]

    init(app: AppModel) { self.app = app }

    private var session: MolaSession { app.account.session }

    func refresh() async {
        guard app.account.isLoggedIn else { return }
        loading = true
        defer { loading = false }
        do {
            let j = try await session.authedGet(MolaEndpoints.agentSessions + "?include_offline=1")
            (sessions, machines) = AgentRelayAPI.parseSessions(j)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func machine(_ id: String?) -> RelayMachine? { machines.first { $0.id == id } }

    /// 有新事件 250ms 再拉；空轮询每次 +1 秒，最长 5 秒；出错退避 1–10 秒。
    func startPolling(_ sessionId: String) {
        guard pollers[sessionId] == nil else { return }
        pollers[sessionId] = Task { [weak self] in
            var idle: Double = 0.25
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                let since = self.transcripts[sessionId]?.latestSeq ?? 0
                do {
                    let j = try await self.session.authedGet(MolaEndpoints.agentEventHistory + "?session=\(sessionId)&since=\(since)")
                    let events = j["events"]?.arrayValue ?? []
                    var t = self.transcripts[sessionId] ?? AgentTranscript()
                    t.apply(events)
                    self.transcripts[sessionId] = t
                    idle = events.isEmpty ? min(5, idle + 1) : 0.25
                    backoff = 1
                    if !events.isEmpty { await self.refresh() }
                    try await Task.sleep(for: .seconds(idle))
                } catch is CancellationError {
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(10, backoff * 2)
                }
            }
        }
    }

    func stopPolling(_ sessionId: String) { pollers[sessionId]?.cancel(); pollers[sessionId] = nil }

    func send(_ s: RelaySession, _ op: AgentRelayAPI.Op) async {
        do {
            let r = try await session.authedPost(MolaEndpoints.agentCommand, AgentRelayAPI.command(sessionId: s.id, op: op, machineId: s.machineId))
            if MolaJSON.bool(r["success"]) == false { error = r["message"]?.stringValue ?? "指令发送失败" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func approve(_ s: RelaySession, permissionId: String, choice: String) async {
        await send(s, .approve(permissionId: permissionId, choice: choice))
        transcripts[s.id]?.resolvePermission(permissionId)
    }

    func create(machineId: String, backend: String, workingDirectory: String?, title: String?) async {
        let placeholder = "new-\(AgentRelayAPI.cmdId())"
        do {
            _ = try await session.authedPost(MolaEndpoints.agentCommand,
                                             AgentRelayAPI.command(sessionId: placeholder, op: .new(backend: backend, workingDirectory: workingDirectory, title: title, model: nil), machineId: machineId))
            try? await Task.sleep(for: .seconds(1.5))
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AgentSessionsView: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false

    var body: some View {
        let model = app.agents
        List {
            if !app.account.isLoggedIn {
                ContentUnavailableView("需要登录", systemImage: "person.crop.circle.badge.exclamationmark",
                                       description: Text("登录 MolaGPT 账户后，可以在手机上查看并控制电脑上的 Claude Code / Codex。"))
            }
            ForEach(model.machines) { m in
                Section {
                    let list = model.sessions.filter { $0.machineId == m.id }
                    if list.isEmpty { Text("没有会话").foregroundStyle(MolaColor.secondaryLabel) }
                    ForEach(list) { s in
                        NavigationLink { AgentSessionView(sessionId: s.id) } label: { AgentSessionRow(session: s, online: m.online()) }
                    }
                } header: {
                    HStack {
                        Circle().fill(m.online() ? Color.green : Color.gray).frame(width: 8, height: 8)
                        Text(m.name)
                    }
                }
            }
            let orphan = model.sessions.filter { s in !model.machines.contains { $0.id == s.machineId } }
            if !orphan.isEmpty {
                Section("其他") { ForEach(orphan) { s in NavigationLink { AgentSessionView(sessionId: s.id) } label: { AgentSessionRow(session: s, online: false) } } }
            }
            if let e = model.error { Section { Text(e).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("远程 Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新会话", systemImage: "plus") { creating = true }.disabled(model.machines.filter { $0.online() }.isEmpty)
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .sheet(isPresented: $creating) { NewAgentSessionSheet() }
    }
}

private struct AgentSessionRow: View {
    let session: RelaySession
    let online: Bool

    var body: some View {
        let stalled = (session.phase == .running || session.phase == .waiting) && !online
        HStack(spacing: 10) {
            Image(systemName: session.backendId == "codex" ? "terminal" : "sparkles")
                .foregroundStyle(online ? MolaColor.accent : MolaColor.tertiaryLabel)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text([session.backendLabel, session.workingDirectory.map { ($0 as NSString).lastPathComponent }, stalled ? "已离线" : session.phase.label]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(MolaColor.secondaryLabel).lineLimit(1)
            }
            Spacer()
            if session.needsAttention || session.phase == .waiting { Circle().fill(.red).frame(width: 8, height: 8) }
            else if session.phase == .running && !stalled { ProgressView().controlSize(.small) }
        }
    }
}

struct AgentSessionView: View {
    @Environment(AppModel.self) private var app
    let sessionId: String
    @State private var draft = ""

    var body: some View {
        let model = app.agents
        let s = model.sessions.first { $0.id == sessionId }
        let blocks = model.transcripts[sessionId]?.blocks ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(blocks) { b in block(b, session: s).id(b.id) }
                }
                .padding(16)
            }
            .onChange(of: blocks.count) { _, _ in if let last = blocks.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("发送指令…", text: $draft, axis: .vertical).lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(MolaColor.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if s?.phase == .running {
                    Button { if let s { Task { await model.send(s, .interrupt) } } } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30)).foregroundStyle(.red)
                    }
                }
                Button {
                    guard let s, let t = draft.nonBlank else { return }
                    draft = ""
                    Task { await model.send(s, .send(t)) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, draft.nonBlank == nil ? Color(uiColor: .systemGray3) : MolaColor.accent)
                }
                .disabled(draft.nonBlank == nil || s == nil)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(s?.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let s {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if !s.availableModels.isEmpty {
                            Picker("模型", selection: Binding(get: { s.model ?? "" }, set: { m in Task { await model.send(s, .switchOptions(model: m, effort: nil, permissionMode: nil)) } })) {
                                ForEach(s.availableModels, id: \.id) { Text($0.displayName).tag($0.id) }
                            }
                        }
                        Picker("权限模式", selection: Binding(get: { s.permissionMode }, set: { pm in Task { await model.send(s, .switchOptions(model: nil, effort: nil, permissionMode: pm)) } })) {
                            Text("规划").tag(0); Text("自动接受编辑").tag(1); Text("默认").tag(2)
                        }
                        Button("关闭会话", systemImage: "xmark.circle", role: .destructive) { Task { await model.send(s, .close) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .onAppear { model.startPolling(sessionId) }
        .onDisappear { model.stopPolling(sessionId) }
    }

    @ViewBuilder private func block(_ b: AgentTranscript.Block, session: RelaySession?) -> some View {
        switch b {
        case .user(_, let t):
            Text(t).padding(.horizontal, 14).padding(.vertical, 9)
                .background(MolaColor.userBubbleClaude, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .answer(_, let t): MarkdownView(text: t)
        case .thinking(_, let t): ThinkingView(text: t, durationMs: 0, live: false)
        case .tool(_, let f): ToolCallView(name: f.label ?? f.name, icon: "terminal", label: nil, status: f.status, detail: f.argsJson ?? f.resultPreview)
        case .permission(let id, let tool, let desc, let args, let resolved):
            VStack(alignment: .leading, spacing: 8) {
                Label("\(tool) 请求权限", systemImage: "hand.raised.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                if !desc.isEmpty { Text(desc).font(.footnote) }
                if let a = args { Text(a).font(.caption.monospaced()).lineLimit(6).foregroundStyle(MolaColor.secondaryLabel) }
                if !resolved, let session {
                    HStack {
                        Button("允许一次") { Task { await app.agents.approve(session, permissionId: id, choice: "Once") } }.buttonStyle(.borderedProminent)
                        Button("总是允许") { Task { await app.agents.approve(session, permissionId: id, choice: "Always") } }.buttonStyle(.bordered)
                        Button("拒绝", role: .destructive) { Task { await app.agents.approve(session, permissionId: id, choice: "Deny") } }.buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                } else {
                    Text("已处理").font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .status(_, let t, let failed):
            Label(t, systemImage: failed ? "exclamationmark.triangle" : "info.circle").font(.footnote).foregroundStyle(failed ? .red : MolaColor.secondaryLabel)
        }
    }
}

private struct NewAgentSessionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var machineId = ""
    @State private var backend = "claude-code"
    @State private var dir = ""
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("电脑", selection: $machineId) {
                    ForEach(app.agents.machines.filter { $0.online() }) { Text($0.name).tag($0.id) }
                }
                Picker("Agent", selection: $backend) { Text("Claude Code").tag("claude-code"); Text("Codex").tag("codex") }
                TextField("工作目录（可选）", text: $dir).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("标题（可选）", text: $title)
            }
            .navigationTitle("新会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task { await app.agents.create(machineId: machineId, backend: backend, workingDirectory: dir.nonBlank, title: title.nonBlank); dismiss() }
                    }
                    .disabled(machineId.isEmpty)
                }
            }
            .onAppear { machineId = app.agents.machines.first { $0.online() }?.id ?? "" }
        }
    }
}
