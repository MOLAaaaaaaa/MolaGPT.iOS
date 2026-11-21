import SwiftUI
import MolaCore

/// 对话列表（侧栏列）。原生 List：搜索、日期分组、滑动操作、编辑模式多选删除、长按菜单。
struct ConversationListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let openChat: () -> Void

    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var confirmBatchDelete = false

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        @Bindable var app = app
        List(selection: $selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { row($0).tag($0.sessionId) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if app.conversations.isEmpty {
                if app.searchText.isEmpty {
                    ContentUnavailableView("还没有对话", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("发出第一条消息后，对话会出现在这里。"))
                } else {
                    ContentUnavailableView.search(text: app.searchText)
                }
            }
        }
        .searchable(text: $app.searchText, prompt: "搜索标题和内容")
        .navigationTitle("对话")
        .toolbar { toolbar }
        .onChange(of: selection) { _, new in
            guard !isEditing, let id = new.first else { return }
            app.open(id)
            openChat()
            // 紧凑布局下返回列表时不保留高亮
            if sizeClass == .compact { DispatchQueue.main.async { selection = [] } }
        }
        .onChange(of: app.current.conversation.sessionId) { _, id in
            if !isEditing && sizeClass != .compact { selection = [id] }
        }
        .onChange(of: editMode) { _, mode in if !mode.isEditing { selection = [] } }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { if let c = renaming { app.rename(c.sessionId, renameText) } }
        }
        .confirmationDialog("删除 \(selection.count) 个对话？", isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                app.delete(Array(selection))
                editMode = .inactive
            }
        } message: { Text("此操作无法撤销。") }
        // 放在最外层：List 与工具栏按钮共享同一个编辑状态。
        .environment(\.editMode, $editMode)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { app.openSettings() } label: { Label("设置", systemImage: "gearshape") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !app.conversations.isEmpty {
                Button(isEditing ? "完成" : "编辑") {
                    withAnimation { editMode = isEditing ? .inactive : .active }
                }
                .fontWeight(isEditing ? .semibold : .regular)
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if isEditing {
                Button("全选") { selection = Set(app.conversations.map(\.sessionId)) }
                Spacer()
                Button("删除", role: .destructive) { confirmBatchDelete = true }
                    .disabled(selection.isEmpty)
            } else {
                Spacer()
                Text(app.conversations.isEmpty ? "" : "\(app.conversations.count) 个对话")
                    .font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                Spacer()
                Button {
                    app.newConversation()
                    openChat()
                } label: { Label("新对话", systemImage: "square.and.pencil") }
            }
        }
    }

    private func row(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if c.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(MolaColor.accent)
                }
                Text(c.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if app.isStreaming(c.sessionId) {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(relativeTime(c.updatedAt)).font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                }
            }
            Text(subtitle(c)).font(.subheadline).foregroundStyle(MolaColor.secondaryLabel).lineLimit(2)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { app.delete([c.sessionId]) } label: { Label("删除", systemImage: "trash") }
            Button { renameText = c.title; renaming = c } label: { Label("重命名", systemImage: "pencil") }
        }
        .swipeActions(edge: .leading) {
            Button { app.togglePin(c.sessionId) } label: {
                Label(c.pinned ? "取消置顶" : "置顶", systemImage: c.pinned ? "pin.slash" : "pin")
            }
            .tint(MolaColor.accent)
        }
        .contextMenu {
            Button { app.togglePin(c.sessionId) } label: {
                Label(c.pinned ? "取消置顶" : "置顶", systemImage: c.pinned ? "pin.slash" : "pin")
            }
            Button { renameText = c.title; renaming = c } label: { Label("重命名", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { app.delete([c.sessionId]) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func subtitle(_ c: Conversation) -> String {
        var parts: [String] = []
        if let p = app.persona(c.personaId), p.id != Persona.builtinDefaultId { parts.append(p.name) }
        if let preview = c.lastMessagePreview?.nonBlank {
            parts.append(preview.replacingOccurrences(of: "\n", with: " "))
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    // MARK: 分组

    private struct Group { let title: String; let items: [Conversation] }

    private var groups: [Group] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [Conversation])] = [("置顶", []), ("今天", []), ("昨天", []), ("前 7 天", []), ("前 30 天", []), ("更早", [])]
        for c in app.conversations {
            let d = Date(timeIntervalSince1970: TimeInterval(c.updatedAt) / 1000)
            let i: Int
            if c.pinned { i = 0 }
            else if cal.isDateInToday(d) { i = 1 }
            else if cal.isDateInYesterday(d) { i = 2 }
            else if now.timeIntervalSince(d) < 7 * 86400 { i = 3 }
            else if now.timeIntervalSince(d) < 30 * 86400 { i = 4 }
            else { i = 5 }
            buckets[i].1.append(c)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, items: $0.1) }
    }

    private func relativeTime(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "昨天" }
        if Date().timeIntervalSince(d) < 7 * 86400 { return d.formatted(.dateTime.weekday(.wide)) }
        return d.formatted(.dateTime.year(.twoDigits).month(.defaultDigits).day())
    }
}
