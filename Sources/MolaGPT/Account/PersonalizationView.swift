import SwiftUI
import MolaCore
import MolaStorage

/// 个性化（对应安卓 PersonalizationScreen）：官方账户的 Tracks 记忆、待确认候选、回答风格。接口为 user_data_manager.php。
struct PersonalizationView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [JSONValue] = []
    @State private var candidates: [JSONValue] = []
    @State private var styles: Set<String> = []
    @State private var instruction = ""
    @State private var loading = false
    @State private var error: String?
    @State private var adding = false
    @State private var editing: (id: String, text: String)?
    @State private var newText = ""
    @State private var newSection = MemorySection.preferences

    static let stylePresets: [(String, String)] = [("more_direct", "更直接"), ("polite", "更礼貌"), ("concise", "更简洁"),
                                                   ("detailed", "更详细"), ("formal", "更正式"), ("casual", "更随意")]

    private var session: MolaSession { app.account.session }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Toggle("个性化记忆", isOn: Binding(get: { app.settings.personalizedMemoryEnabled }, set: { v in Task { await setEnabled(v) } }))
            } footer: { Text("开启后，MolaGPT 官方模型会参考你的长期背景与偏好回答。记忆保存在你的账户里。") }

            Section {
                ForEach(Self.stylePresets, id: \.0) { k, label in
                    Toggle(label, isOn: Binding(get: { styles.contains(k) }, set: { on in if on { styles.insert(k) } else { styles.remove(k) } }))
                }
                TextField("自定义回答要求（≤500 字）", text: $instruction, axis: .vertical).lineLimit(2...6)
                Button("保存风格") { Task { await saveStyles() } }
            } header: { Text("回答风格") }

            if !candidates.isEmpty {
                Section("待确认") {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(c["text"]?.stringValue ?? "")
                            HStack {
                                Button("记住") { Task { await act(["action": "add_memory_entry", "text": c["text"] ?? "", "section": c["section"] ?? .string(MemorySection.recent.rawValue), "candidate_id": c["id"] ?? .null]) } }
                                    .buttonStyle(.borderedProminent)
                                Button("忽略") { Task { await act(["action": "dismiss_candidate", "candidate_id": c["id"] ?? .null, "suppress": true]) } }
                                    .buttonStyle(.bordered)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            ForEach(MemorySection.allCases, id: \.self) { sec in
                let items = entries.filter { MemorySection.from($0["section"]?.stringValue) == sec }
                if !items.isEmpty {
                    Section(sec.rawValue) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, e in
                            let id = e["id"]?.stringValue ?? MolaJSON.int(e["id"]).map(String.init) ?? ""
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e["text"]?.stringValue ?? "")
                                Text(tier(e["confidence"]?.doubleValue ?? Double(e["confidence"]?.stringValue ?? "") ?? 0))
                                    .font(.caption2).foregroundStyle(MolaColor.secondaryLabel)
                            }
                            .contextMenu {
                                Button("编辑", systemImage: "pencil") { editing = (id, e["text"]?.stringValue ?? "") }
                                Button("认同", systemImage: "hand.thumbsup") { Task { await act(["action": "rate_memory_entry", "entry_id": .string(id), "rating": "agree"], evolve: true) } }
                                Button("存疑", systemImage: "questionmark.circle") { Task { await act(["action": "rate_memory_entry", "entry_id": .string(id), "rating": "doubt"], evolve: true) } }
                                Button("删除", systemImage: "trash", role: .destructive) { Task { await act(["action": "delete_memory_entry", "entry_id": .string(id)]) } }
                            }
                        }
                    }
                }
            }

            Section {
                Button("添加记忆", systemImage: "plus") { adding = true }
                if !entries.isEmpty {
                    Button("清除全部记忆", role: .destructive) { Task { await act(["action": "delete_all_memories"]) } }
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
        }
        .overlay { if loading && entries.isEmpty { ProgressView() } }
        .navigationTitle("个性化")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .alert("添加记忆", isPresented: $adding) {
            TextField("内容（第三人称陈述句）", text: $newText)
            Button("取消", role: .cancel) {}
            Button("添加") { Task { await act(["action": "add_memory_entry", "text": .string(newText), "section": .string(newSection.rawValue)]); newText = "" } }
        }
        .alert("编辑记忆", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("内容", text: Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 }))
            Button("取消", role: .cancel) {}
            Button("保存") { if let e = editing { Task { await act(["action": "update_memory_entry", "entry_id": .string(e.id), "new_text": .string(e.text)]) } } }
        }
    }

    private func tier(_ c: Double) -> String { c >= 0.8 ? "核心印象" : c >= 0.5 ? "初步了解" : "模糊猜测" }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            if let s = try await session.status(), let p = s.personalizedMemory { app.settings.personalizedMemoryEnabled = p }
            let e = try await session.authedPost(MolaEndpoints.userData, ["action": "get_memory_entries"])
            entries = e["entries"]?.arrayValue ?? []
            let c = try await session.authedPost(MolaEndpoints.userData, ["action": "get_candidates"])
            candidates = c["candidates"]?.arrayValue ?? []
            let st = try await session.authedPost(MolaEndpoints.userData, ["action": "get_style_preferences"])
            styles = Set(st["preferences"]?["styles"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            instruction = st["preferences"]?["custom_instruction"]?.stringValue ?? ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func act(_ body: JSONValue, evolve: Bool = false) async {
        do {
            if let t = body["text"]?.stringValue, t.count > 300 { error = "记忆内容不能超过 300 字"; return }
            _ = try await session.authedPost(MolaEndpoints.userData, body)
            if evolve { _ = try? await session.authedPost(MolaEndpoints.userData, ["action": "trigger_user_evolution"]) }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveStyles() async {
        await act(["action": "update_style_preferences",
                   "preferences": ["styles": .array(styles.sorted().map { .string($0) }), "custom_instruction": .string(String(instruction.prefix(500)))]])
    }

    /// 先本地乐观写入，失败回滚。
    private func setEnabled(_ v: Bool) async {
        let old = app.settings.personalizedMemoryEnabled
        app.settings.personalizedMemoryEnabled = v
        do {
            _ = try await session.authedPost(MolaEndpoints.sync, ["action": "update_setting", "setting": "personalized_memory_enabled", "value": .bool(v)])
        } catch {
            app.settings.personalizedMemoryEnabled = old
            self.error = error.localizedDescription
        }
    }
}
