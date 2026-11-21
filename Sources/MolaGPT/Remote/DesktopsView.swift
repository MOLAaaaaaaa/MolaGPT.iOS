import SwiftUI
import MolaCore
import MolaStorage

/// 「电脑」：继续桌面端 MolaGPT 的对话（账号模式）。
struct DesktopsView: View {
    @Environment(AppModel.self) private var app
    @State private var pairing: String?
    @State private var pairError: String?

    var body: some View {
        let svc = app.desktops
        List {
            if !app.account.isLoggedIn {
                ContentUnavailableView("需要登录", systemImage: "desktopcomputer",
                                       description: Text("在电脑上登录同一个 MolaGPT 账户，即可在手机上继续电脑上的对话。"))
            } else if svc.desktops.isEmpty {
                ContentUnavailableView("没有电脑", systemImage: "desktopcomputer",
                                       description: Text("在 MolaGPT 桌面版中开启远程访问后，电脑会出现在这里。"))
            }
            ForEach(svc.desktops) { m in
                Section {
                    if !svc.isPaired(m.id) {
                        Button {
                            pairing = m.id
                            Task {
                                do { try await svc.pair(m.id) } catch { pairError = error.localizedDescription }
                                pairing = nil
                            }
                        } label: {
                            HStack { Label("与这台电脑配对", systemImage: "link"); Spacer(); if pairing == m.id { ProgressView() } }
                        }
                        .disabled(!svc.isOnline(m) || pairing != nil)
                    }
                    ForEach(m.conversations) { c in
                        NavigationLink {
                            RemoteConversationView(machineId: m.id, conversationId: c.id, initialTitle: c.title)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).lineLimit(1)
                                    Text([c.modelLabel, c.updatedAtMs > 0 ? c.updatedAtMs.relativeText : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                                }
                                Spacer()
                                if c.pendingApprovals > 0 { Circle().fill(.red).frame(width: 8, height: 8) }
                                else if c.busy { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(!svc.isPaired(m.id) || !svc.isOnline(m))
                    }
                } header: {
                    HStack {
                        Image(systemName: "desktopcomputer").foregroundStyle(svc.isOnline(m) ? MolaColor.accent : MolaColor.tertiaryLabel)
                        Text(m.name)
                        Spacer()
                        Menu {
                            if svc.isPaired(m.id) { Button("重新配对", systemImage: "link") { Task { try? await svc.pair(m.id) } } }
                            Button("移除这台电脑", systemImage: "trash", role: .destructive) { Task { await svc.forget(m.id) } }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            if let e = svc.error { Section { Text(e).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("电脑")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await svc.refreshDesktops() }
        .task { await svc.refreshDesktops(); try? await svc.ensureConnected() }
        .alert("配对失败", isPresented: Binding(get: { pairError != nil }, set: { if !$0 { pairError = nil } })) { Button("好") {} } message: { Text(pairError ?? "") }
    }
}

struct RemoteConversationView: View {
    @Environment(AppModel.self) private var app
    let machineId: String
    let conversationId: String
    let initialTitle: String
    @State private var model: RemoteConversationModel?
    @State private var draft = ""

    var body: some View {
        Group {
            if let model {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(model.messages) { m in
                                Group {
                                    if m.role == .user {
                                        Text(m.text).padding(.horizontal, 14).padding(.vertical, 9)
                                            .background(MolaColor.userBubbleClaude, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                            .opacity(m.metadata["local_pending"] == "1" ? 0.6 : 1)
                                    } else {
                                        VStack(alignment: .leading, spacing: 10) {
                                            ForEach(m.fragments) { FragmentView(fragment: $0, streaming: m.status == .streaming) }
                                        }
                                    }
                                }
                                .id(m.messageId)
                            }
                            ForEach(model.approvals) { a in approvalCard(a, model: model) }
                        }
                        .padding(16)
                    }
                    .onChange(of: model.messages.count) { _, _ in if let last = model.messages.last { withAnimation { proxy.scrollTo(last.messageId, anchor: .bottom) } } }
                }
                .safeAreaInset(edge: .bottom) { composer(model) }
                .navigationTitle(model.title.nonBlank ?? initialTitle)
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let m = RemoteConversationModel(service: app.desktops, machineId: machineId, conversationId: conversationId)
            model = m
            await m.open()
        }
        .onDisappear { model?.close() }
    }

    private func composer(_ model: RemoteConversationModel) -> some View {
        VStack(spacing: 4) {
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("在电脑上继续…", text: $draft, axis: .vertical).lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(MolaColor.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if model.busy {
                    Button { Task { await model.stop() } } label: { Image(systemName: "stop.circle.fill").font(.system(size: 30)).foregroundStyle(.red) }
                }
                Button {
                    guard let t = draft.nonBlank else { return }
                    draft = ""
                    Task { await model.send(t) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, draft.nonBlank == nil ? Color(uiColor: .systemGray3) : MolaColor.accent)
                }
                .disabled(draft.nonBlank == nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func approvalCard(_ a: DesktopApproval, model: RemoteConversationModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(a.displayName ?? a.toolName) 等待审批", systemImage: "hand.raised.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            if let s = a.summary { Text(s).font(.footnote) }
            if let p = a.codePreview ?? a.argumentsPreview { Text(p).font(.caption.monospaced()).lineLimit(8).foregroundStyle(MolaColor.secondaryLabel) }
            HStack {
                ForEach(a.options, id: \.self) { opt in
                    Button(opt == "once" ? "允许一次" : opt == "session" ? "本次会话允许" : "拒绝", role: opt == "deny" ? .destructive : nil) {
                        Task { await model.approve(a, opt) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
