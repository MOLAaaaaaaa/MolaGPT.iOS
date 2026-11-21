import SwiftUI
import MolaCore
import MolaStorage

/// 记忆管理页（对应安卓 ByokMemoryScreen）。
struct MemorySettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: MemoryEntry?
    @State private var adding = false
    @State private var confirmClear = false
    @State private var running = false
    @State private var profileDraft: [MemoryProfileKey: String] = [:]

    private var memory: MemoryService { app.memory }

    var body: some View {
        @Bindable var app = app
        let _ = memory.revision
        let entries = app.store.memoryEntries().filter { $0.profileKey == nil }
        let candidates = app.store.memoryCandidates()
        let topics = app.store.memoryTopics()
        let projection = memory.projection()
        Form {
            Section {
                Toggle("本地记忆", isOn: $app.settings.byokMemoryMasterEnabled)
            } footer: {
                Text("记忆只保存在本机。开启后，支持工具调用的模型可以记住你的背景与偏好，并在之后的对话中参考。角色扮演角色不使用记忆。")
            }

            if app.settings.byokMemoryMasterEnabled {
                Section {
                    Toggle("使用记忆", isOn: $app.settings.byokMemoryUse)
                    Toggle("回忆对话", isOn: $app.settings.byokConversationRecall)
                    Toggle("自动整理", isOn: $app.settings.byokMemoryAutoLearn)
                    Toggle("允许敏感信息", isOn: $app.settings.byokMemoryAllowSensitive)
                } footer: {
                    Text("回忆对话让模型在你提到「上次」「之前说过」时检索历史对话。默认不会记录密码、证件、健康等敏感信息。")
                }

                Section {
                    ModelKeyPicker(title: "整理模型", selection: $app.settings.byokMemoryModelKey, noneLabel: "未选择")
                    Picker("历史范围", selection: $app.settings.byokMemoryFullScan) {
                        Text("近期内容").tag(false)
                        Text("全部历史").tag(true)
                    }
                    Button {
                        running = true
                        Task { await memory.runManual(); running = false }
                    } label: {
                        HStack {
                            Text("开始整理")
                            Spacer()
                            if running || memory.consolidating { ProgressView() }
                        }
                    }
                    .disabled(app.settings.byokMemoryModelKey == nil || running)
                    if let err = memory.lastError { Text(err).font(.footnote).foregroundStyle(.red) }
                } header: { Text("自动整理") } footer: {
                    Text(app.settings.byokMemoryLastRunAt > 0
                         ? "上次整理：\(Date(timeIntervalSince1970: Double(app.settings.byokMemoryLastRunAt) / 1000).formatted(.relative(presentation: .named)))"
                         : "每 3 轮回答后在后台整理一次，需要显式选择整理模型。")
                }

                Section {
                    Picker("记忆量", selection: $app.settings.byokMemoryBudget) {
                        ForEach(MemoryMath.budgets, id: \.self) { Text("\($0) tokens").tag($0) }
                    }
                    LabeledContent("本次使用", value: "\(projection.injected) 条 · 约 \(projection.tokens) tokens")
                    if projection.skipped > 0 {
                        LabeledContent("暂未使用", value: "\(projection.skipped) 条")
                    }
                } header: { Text("对话记忆量") }

                Section("个人资料") {
                    ForEach(MemoryProfileKey.allCases, id: \.self) { k in
                        LabeledContent(k.label) {
                            TextField("未填写", text: Binding(get: { profileDraft[k] ?? memory.profile[k] ?? "" }, set: { profileDraft[k] = $0 }))
                                .multilineTextAlignment(.trailing)
                                .onSubmit { saveProfile(k) }
                        }
                    }
                }

                if !candidates.isEmpty {
                    Section {
                        ForEach(candidates) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(c.text)
                                if let q = c.quote { Text("“\(q)”").font(.caption).foregroundStyle(MolaColor.secondaryLabel).lineLimit(2) }
                                HStack {
                                    Button("记住") { memory.confirm(c) }.buttonStyle(.borderedProminent)
                                    Button("忽略") { memory.dismiss(c) }.buttonStyle(.bordered)
                                }
                                .controlSize(.small)
                            }
                        }
                    } header: { Text("待确认") } footer: { Text("把握不足或涉及敏感信息的内容需要你确认后才会生效。") }
                }

                ForEach(MemoryGroup.allCases, id: \.self) { g in
                    let groupTopics = topics.filter { $0.group == g }
                    if !groupTopics.isEmpty {
                        Section(g.rawValue) {
                            ForEach(groupTopics) { t in
                                DisclosureGroup {
                                    ForEach(entries.filter { $0.topicId == t.id }) { entryRow($0) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.title)
                                        if let s = t.summary { Text(s).font(.caption).foregroundStyle(MolaColor.secondaryLabel).lineLimit(2) }
                                    }
                                }
                                .swipeActions { Button("删除主题", role: .destructive) { memory.deleteTopic(t.id) } }
                            }
                        }
                    }
                }

                Section {
                    ForEach(entries.filter { e in e.topicId == nil || !topics.contains { $0.id == e.topicId } }) { entryRow($0) }
                    Button("添加记忆", systemImage: "plus") { adding = true }
                } header: { Text("全部记忆") }

                Section {
                    Button("清除全部记忆", role: .destructive) { confirmClear = true }
                }
            }
        }
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { e in MemoryEditSheet(entry: e) { memory.update($0) } }
        .sheet(isPresented: $adding) {
            MemoryEditSheet(entry: MemoryEntry(text: "", section: .preferences, confidence: 1, origin: .manual)) { memory.addManual($0.text, section: $0.section) }
        }
        .confirmationDialog("清除全部记忆？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { memory.clearAll() }
        } message: { Text("条目、待确认与证据都会删除，此操作无法撤销。") }
    }

    private func entryRow(_ e: MemoryEntry) -> some View {
        let count = app.store.evidenceCount(e.id)
        let active = MemoryMath.isActive(e)
        return Button { editing = e } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(e.text).foregroundStyle(MolaColor.label)
                HStack(spacing: 6) {
                    Text(e.section.rawValue)
                    if e.origin != .manual && e.origin != .confirmed { Text("对话记录") }
                    if count > 1 { Text("提及 \(count) 次") }
                    if !active { Text("暂未使用").foregroundStyle(.orange) }
                }
                .font(.caption2).foregroundStyle(MolaColor.secondaryLabel)
            }
        }
        .swipeActions { Button("删除", role: .destructive) { memory.delete(e.id) } }
    }

    private func saveProfile(_ k: MemoryProfileKey) {
        guard let v = profileDraft[k] else { return }
        if let existing = app.store.memoryEntry(profile: k), v.nonBlank == nil { memory.delete(existing.id) }
        else { memory.addManual(v, section: .identity, profileKey: k) }
        profileDraft[k] = nil
    }
}

struct MemoryEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: MemoryEntry
    let onSave: (MemoryEntry) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("内容（第三人称陈述句）", text: $entry.text, axis: .vertical).lineLimit(3...8)
                } footer: { Text("\(entry.text.count)/300") }
                Picker("分类", selection: $entry.section) {
                    ForEach(MemorySection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("永久保留", isOn: $entry.permanent)
            }
            .navigationTitle(entry.text.isEmpty ? "添加记忆" : "编辑记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(entry); dismiss() }.disabled(entry.text.nonBlank == nil || entry.text.count > 300)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
