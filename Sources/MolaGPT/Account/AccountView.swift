import SwiftUI
import MolaCore
import MolaStorage

/// MolaGPT 账户页（对应安卓 MolaAccountScreen）。
struct AccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showLogin = false
    @State private var confirmLogout = false
    @State private var portalError: String?
    @State private var now = Date()

    private var account: AccountManager { app.account }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: account.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 44)).foregroundStyle(MolaColor.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.isLoggedIn ? (account.username ?? "已登录") : "游客").font(.title3.weight(.semibold))
                        Text(account.status?.membership?.summary ?? (account.status?.isDonor == true ? "支持者" : account.isLoggedIn ? "已登录账号" : "登录后可同步对话、使用个性化记忆"))
                            .font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
                    }
                    Spacer()
                }
                if !account.isLoggedIn {
                    Button("登录 MolaGPT") { showLogin = true }.fontWeight(.semibold)
                }
            }

            if let c = account.status?.credits {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("额度剩余").font(.subheadline)
                            Spacer()
                            Text("\(c.remainingPercent)%").font(.title3.weight(.semibold).monospacedDigit())
                        }
                        ProgressView(value: Double(c.remainingPercent), total: 100).tint(c.remainingPercent < 15 ? .orange : MolaColor.accent)
                        HStack {
                            Text(c.tierLabel)
                            Text("·")
                            Text(c.windowLabel)
                            Spacer()
                            if let next = c.nextRefreshAt, next > 0 {
                                Text("刷新 \(Date(timeIntervalSince1970: Double(next)).formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                            }
                        }
                        .font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                        if c.remainingPercent == 0, let r = c.recoversAt, r > 0 {
                            Text("额度已用完，将于 \(Date(timeIntervalSince1970: Double(r)).formatted(date: .omitted, time: .shortened)) 起逐步恢复")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if let w = c.webSearchCalls { LabeledContent("联网搜索", value: "\(w) 次") }
                } header: { Text("额度") }
            } else if let quotas = account.status?.perModel, !quotas.isEmpty {
                Section("今日用量") {
                    ForEach(quotas.keys.sorted(), id: \.self) { k in
                        let q = quotas[k]!
                        LabeledContent(account.model(k)?.displayName ?? k, value: q.limit < 0 ? "\(q.used) / 不限" : "\(q.used) / \(q.limit)")
                    }
                }
            }

            Section {
                Button {
                    Task { await openPortal() }
                } label: {
                    HStack {
                        Label(account.status?.isDonor == true ? "支持者权益" : "成为支持者", systemImage: "heart.fill").foregroundStyle(.pink)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(MolaColor.tertiaryLabel)
                    }
                }
                .disabled(!account.isLoggedIn)
                if let e = portalError { Text(e).font(.footnote).foregroundStyle(.red) }
            } footer: { Text("支持 MolaGPT 的持续运营，获得更多额度与模型。") }

            if account.isLoggedIn {
                Section {
                    Toggle("云同步", isOn: $app.settings.cloudSyncEnabled)
                        .onChange(of: app.settings.cloudSyncEnabled) { _, on in if on { app.sync.syncNow(force: true) } }
                    Button {
                        app.sync.syncNow(force: true)
                    } label: {
                        HStack { Text("立即同步"); Spacer(); if app.sync.syncing { ProgressView() } }
                    }
                    if let t = app.sync.lastSyncAt { LabeledContent("上次同步", value: t.formatted(.relative(presentation: .named))) }
                    if let e = app.sync.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
                    NavigationLink(value: SettingsRoute.personalization) { Label("个性化（Tracks 记忆）", systemImage: "sparkles") }
                } header: { Text("同步与个性化") } footer: { Text("云同步只同步 MolaGPT 官方模型的对话；自定义服务的对话只保存在本机。") }
            }

            Section {
                Toggle("联网搜索", isOn: $app.settings.toolNetwork)
                Toggle("代码执行", isOn: $app.settings.toolCode)
            } header: { Text("官方模型工具") } footer: { Text("使用 MolaGPT 官方模型时，由服务端执行联网搜索与代码。") }

            if account.isLoggedIn {
                Section { Button("退出登录", role: .destructive) { confirmLogout = true } }
            }
            if let e = account.error {
                Section { Text(e).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("MolaGPT 账户")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await account.refresh(force: true) }
        .task { await account.refresh() }
        .sheet(isPresented: $showLogin) { LoginSheet() }
        .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出", role: .destructive) { Task { await account.logout() } }
        }
    }

    /// membership_portal.php 返回的地址必须是 /v2/membership，无 query，fragment 以 ticket= 开头。
    private func openPortal() async {
        portalError = nil
        do {
            let j = try await account.session.authedPost(MolaEndpoints.membershipPortal, [:])
            guard let s = j["url"]?.stringValue, let u = URLComponents(string: s), u.host == MolaEndpoints.host, u.path == "/v2/membership",
                  u.query == nil, u.fragment?.hasPrefix("ticket=") == true, let url = u.url else {
                portalError = "支持者页面地址无效"; return
            }
            openURL(url)
        } catch {
            portalError = error.localizedDescription
        }
    }
}

struct LoginSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                    Button {
                        Task { if await app.account.login(username: username, password: password) { dismiss() } }
                    } label: {
                        HStack { Text("登录").fontWeight(.semibold); Spacer(); if app.account.loading { ProgressView() } }
                    }
                    .disabled(username.nonBlank == nil || password.isEmpty || app.account.loading)
                }
                Section("其他登录方式") {
                    ForEach(OAuthProvider.allCases, id: \.self) { p in
                        Button { app.account.loginOAuth(p) } label: { Label("使用 \(p.label) 登录", systemImage: "person.badge.key") }
                    }
                }
                if let e = app.account.error { Section { Text(e).font(.footnote).foregroundStyle(.red) } }
                Section {
                    Link("注册账号", destination: URL(string: MolaEndpoints.base)!)
                }
            }
            .navigationTitle("登录 MolaGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onChange(of: app.account.isLoggedIn) { _, v in if v { dismiss() } }
        }
    }
}
