import SwiftUI
import UniformTypeIdentifiers
import MolaCore
import MolaStorage

struct SkillsView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var pasting = false
    @State private var error: String?

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                Toggle("技能", isOn: $app.settings.skillsEnabled)
            } footer: {
                Text("技能是一份 SKILL.md 说明（可附带参考文件）。模型遇到匹配的任务时会先读取说明再处理。本机不执行技能里的脚本。")
            }
            Section {
                if app.skills.skills.isEmpty {
                    Text("还没有安装技能").foregroundStyle(MolaColor.secondaryLabel)
                }
                ForEach(app.skills.skills) { s in
                    NavigationLink(value: SettingsRoute.skill(s.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            Text(s.description).font(.caption).foregroundStyle(MolaColor.secondaryLabel).lineLimit(2)
                        }
                        .opacity(app.skills.isEnabled(s) ? 1 : 0.5)
                    }
                }
                .onDelete { idx in idx.map { app.skills.skills[$0] }.forEach(app.skills.delete) }
            } header: { Text("已安装") }
        }
        .navigationTitle("技能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("从文件导入（.zip / SKILL.md）", systemImage: "doc.badge.plus") { importing = true }
                    Button("粘贴 SKILL.md", systemImage: "doc.on.clipboard") { pasting = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .plainText, UTType(filenameExtension: "md") ?? .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do { try app.skills.importFile(url) } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $pasting) {
            PasteSkillSheet { text in
                do { try app.skills.importMarkdown(text); return nil } catch { return error.localizedDescription }
            }
        }
        .alert("导入失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") {}
        } message: { Text(error ?? "") }
    }
}

private struct PasteSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: (String) -> String?
    @State private var text = "---\nname: \ndescription: \n---\n\n"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).font(.footnote.monospaced()).frame(minHeight: 280)
                } footer: { if let error { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("粘贴 SKILL.md")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { if let e = onImport(text) { error = e } else { dismiss() } }
                }
            }
        }
    }
}

struct SkillDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let skillId: String
    @State private var confirmDelete = false

    var body: some View {
        if let s = app.skills.skills.first(where: { $0.id == skillId }) {
            Form {
                Section {
                    Toggle("启用", isOn: Binding(get: { app.skills.isEnabled(s) }, set: { app.skills.setEnabled(s, $0) }))
                    Text(s.description).font(.footnote)
                    if let c = s.compatibility { LabeledContent("环境要求", value: c) }
                }
                Section("文件") {
                    ForEach(app.skills.files(s), id: \.self) { f in
                        NavigationLink {
                            ScrollView { Text(app.skills.text(s, path: f) ?? "（非文本文件）").font(.footnote.monospaced()).textSelection(.enabled).padding() }
                                .navigationTitle(f).navigationBarTitleDisplayMode(.inline)
                        } label: { Label(f, systemImage: f == "SKILL.md" ? "doc.text.fill" : "doc") }
                    }
                }
                Section { Button("删除技能", role: .destructive) { confirmDelete = true } }
            }
            .navigationTitle(s.name)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("删除「\(s.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { app.skills.delete(s); dismiss() }
            }
        } else {
            ContentUnavailableView("技能不存在", systemImage: "book.closed")
        }
    }
}
