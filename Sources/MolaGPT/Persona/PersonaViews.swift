import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MolaCore
import MolaStorage

/// 角色头像：有卡片头像用图片，否则用 SF Symbol。
struct PersonaAvatar: View {
    @Environment(AppModel.self) private var app
    let persona: Persona?
    var size: CGFloat = 36

    var body: some View {
        if let p = persona, let img = app.roleEngine.avatar(p) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
        } else {
            Image(systemName: persona?.symbolName ?? "person.crop.circle")
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(MolaColor.accent)
                .frame(width: size, height: size)
                .background(MolaColor.accentSoft, in: Circle())
        }
    }
}

struct PersonasView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var error: String?
    @State private var newPersona: Persona?

    var body: some View {
        List {
            Section {
                ForEach(app.personas) { p in
                    NavigationLink(value: SettingsRoute.persona(p.id)) {
                        HStack(spacing: 12) {
                            PersonaAvatar(persona: p, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(p.name)
                                    if p.isRolePlay { badge("角色扮演") }
                                    if p.isBuiltin { badge("内置") }
                                }
                                Text(p.preview).font(.caption).foregroundStyle(MolaColor.secondaryLabel).lineLimit(1)
                            }
                        }
                    }
                    .swipeActions {
                        if !p.isBuiltin { Button("删除", role: .destructive) { app.roleEngine.delete(p) } }
                        Button("复制") { _ = app.roleEngine.duplicate(p) }.tint(.indigo)
                    }
                }
            } footer: { Text("可导入 SillyTavern 角色卡（PNG / JSON / charX）。角色扮演角色不使用长期记忆。") }
            Section {
                NavigationLink(value: SettingsRoute.lorebooks) { Label("共享世界书", systemImage: "books.vertical") }
            }
        }
        .navigationTitle("角色")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("新建角色", systemImage: "plus") {
                        newPersona = Persona(name: "", systemPrompt: "", sortOrder: (app.personas.map(\.sortOrder).max() ?? 0) + 1)
                    }
                    Button("导入角色卡", systemImage: "square.and.arrow.down") { importing = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .json, .zip, UTType(filenameExtension: "charx") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do { try app.roleEngine.importCard(try Data(contentsOf: url)) } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $newPersona) { p in NavigationStack { PersonaEditView(persona: p, isNew: true) } }
        .alert("导入失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") {}
        } message: { Text(error ?? "") }
    }

    private func badge(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(MolaColor.accentSoft, in: Capsule()).foregroundStyle(MolaColor.accent)
    }
}

/// 路由入口：内置角色只读查看，其它角色直接编辑。
struct PersonaRouteView: View {
    @Environment(AppModel.self) private var app
    let personaId: String
    @State private var copy: Persona?

    var body: some View {
        if let p = app.personas.first(where: { $0.id == personaId }) {
            if p.isBuiltin {
                Form {
                    Section {
                        HStack { Spacer(); PersonaAvatar(persona: p, size: 76); Spacer() }
                        LabeledContent("名称", value: p.name)
                        Text("内置角色 · 只读").font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
                    }
                    Section("系统提示词") { Text(p.systemPrompt).font(.callout).textSelection(.enabled) }
                    Section { Button("复制为副本并编辑") { copy = p.draftCopy(sortOrder: (app.personas.map(\.sortOrder).max() ?? 0) + 1) } }
                }
                .navigationTitle(p.name)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(item: $copy) { c in NavigationStack { PersonaEditView(persona: c, isNew: true) } }
            } else {
                PersonaEditView(persona: p, isNew: false)
            }
        } else {
            ContentUnavailableView("角色不存在", systemImage: "person.crop.circle.badge.questionmark")
        }
    }
}

struct PersonaEditView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var persona: Persona
    let isNew: Bool
    @State private var profile: PersonaProfile?
    @State private var photo: PhotosPickerItem?
    @State private var editingEntry: (bookIndex: Int, entry: LoreEntry)?
    @State private var showEntry = false

    init(persona: Persona, isNew: Bool) {
        _persona = State(initialValue: persona)
        _profile = State(initialValue: persona.profile)
        self.isNew = isNew
    }

    static let icons: [(String, String)] = [("assistant", "sparkles"), ("write", "pencil.line"), ("code", "chevron.left.forwardslash.chevron.right"),
                                            ("translate", "character.bubble"), ("learn", "graduationcap"), ("idea", "person.crop.circle")]

    var body: some View {
        let current = persona
        Form {
            Section {
                HStack(spacing: 14) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        PersonaAvatar(persona: current, size: 64)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.circle.fill").font(.title3).foregroundStyle(MolaColor.accent).background(Circle().fill(MolaColor.background))
                            }
                    }
                    .buttonStyle(.plain)
                    TextField("名称（必填）", text: $persona.name).font(.title3)
                }
                Picker("图标", selection: Binding(get: { persona.icon ?? "idea" }, set: { persona.icon = $0 })) {
                    ForEach(Self.icons, id: \.0) { Label($0.0 == "idea" ? "默认" : $0.0, systemImage: $0.1).tag($0.0) }
                }
                if persona.avatarPath != nil { Button("移除头像", role: .destructive) { persona.avatarPath = nil } }
            }
            Section {
                TextField("系统提示词", text: $persona.systemPrompt, axis: .vertical).lineLimit(4...16)
            } header: { Text("系统提示词") } footer: {
                Text("可用变量：{{date}} {{time}} {{datetime}} {{model}} {{provider}} {{username}}。使用 {{time}} 会让提示缓存失效。")
            }
            if profile != nil { roleplaySections } else {
                Section {
                    Button("启用角色扮演设定", systemImage: "theatermasks") { profile = PersonaProfile() }
                } footer: { Text("角色资料、开场白、示例对话与世界书。") }
            }
        }
        .navigationTitle(isNew ? "新建角色" : persona.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(persona.name.nonBlank == nil)
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    persona = app.roleEngine.setAvatar(persona, image: img)
                }
                photo = nil
            }
        }
        .sheet(isPresented: $showEntry) {
            if let e = editingEntry {
                LoreEntrySheet(entry: e.entry) { saved in
                    guard var p = profile else { return }
                    if let i = p.lorebooks[e.bookIndex].entries.firstIndex(where: { $0.id == saved.id }) { p.lorebooks[e.bookIndex].entries[i] = saved }
                    else { p.lorebooks[e.bookIndex].entries.append(saved) }
                    profile = p
                }
            }
        }
    }

    private func save() {
        var p = persona
        p.profile = profile
        app.roleEngine.save(p)
        if isNew { dismiss() }
    }

    private func binding(_ kp: WritableKeyPath<PersonaProfile, String>) -> Binding<String> {
        Binding(get: { profile?[keyPath: kp] ?? "" }, set: { profile?[keyPath: kp] = $0 })
    }

    @ViewBuilder private var roleplaySections: some View {
        Section("人设") {
            TextField("角色资料", text: binding(\.description), axis: .vertical).lineLimit(3...12)
            TextField("性格与表达", text: binding(\.personality), axis: .vertical).lineLimit(2...8)
            TextField("场景", text: binding(\.scenario), axis: .vertical).lineLimit(2...8)
            TextField("角色称呼（昵称）", text: Binding(get: { profile?.nickname ?? "" }, set: { profile?.nickname = $0.nonBlank }))
            Picker("模式", selection: Binding(get: { profile?.defaultMode ?? .atmosphere }, set: { profile?.mode = $0 })) {
                Text("角色扮演").tag(ConversationMode.atmosphere)
                Text("普通对话").tag(ConversationMode.chat)
            }
        }
        Section("我的身份") {
            Toggle("沿用个人资料里的称呼", isOn: Binding(get: { profile?.useProfileName ?? true }, set: { profile?.useProfileName = $0 }))
            if !(profile?.useProfileName ?? true) {
                TextField("你的称呼", text: Binding(get: { profile?.userName ?? "" }, set: { profile?.userName = $0.nonBlank }))
            }
            TextField("你的身份", text: binding(\.userDescription), axis: .vertical).lineLimit(2...6)
        }
        Section {
            TextField("开场白", text: binding(\.greeting), axis: .vertical).lineLimit(2...10)
            if let alts = profile?.alternateGreetings, !alts.isEmpty { LabeledContent("备选开场白", value: "\(alts.count) 条") }
            TextField("对话示例（用 <START> 分隔）", text: binding(\.exampleDialogue), axis: .vertical).lineLimit(3...12).font(.callout.monospaced())
        } header: { Text("开场与示例") } footer: { Text("新对话选择该角色时，开场白会作为第一条回答出现，多条开场白可左右切换。") }
        Section("补充指令") {
            TextField("角色补充（按深度插入）", text: binding(\.characterNote), axis: .vertical).lineLimit(2...6)
            if profile?.characterNote.isEmpty == false {
                Stepper("插入深度：\(profile?.characterNoteDepth ?? 4)", value: Binding(get: { profile?.characterNoteDepth ?? 4 }, set: { profile?.characterNoteDepth = $0 }), in: 0...50)
            }
            TextField("后置指令", text: binding(\.postHistoryInstructions), axis: .vertical).lineLimit(2...6)
        }
        lorebookSections
        if let p = profile, p.creator != nil || !p.tags.isEmpty || !p.importNotes.isEmpty || p.creatorNotes != nil {
            Section("卡片信息") {
                if let c = p.creator { LabeledContent("作者", value: c) }
                if let v = p.characterVersion { LabeledContent("版本", value: v) }
                if !p.tags.isEmpty { LabeledContent("标签", value: p.tags.joined(separator: "、")) }
                LabeledContent("规格", value: p.cardSpec)
                ForEach(p.importNotes, id: \.self) { Text($0).font(.footnote).foregroundStyle(MolaColor.secondaryLabel) }
                if let n = p.creatorNotes { DisclosureGroup("作者说明") { Text(n).font(.footnote) } }
            }
        }
        Section { Button("关闭角色扮演设定", role: .destructive) { profile = nil } }
    }

    @ViewBuilder private var lorebookSections: some View {
        ForEach(Array((profile?.lorebooks ?? []).enumerated()), id: \.element.id) { bi, book in
            Section {
                TextField("世界书名称", text: Binding(get: { profile?.lorebooks[bi].name ?? "" }, set: { profile?.lorebooks[bi].name = $0 }))
                ForEach(book.entries) { e in
                    Button { editingEntry = (bi, e); showEntry = true } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name.nonBlank ?? e.keys.joined(separator: "、").nonBlank ?? "（未命名条目）").foregroundStyle(MolaColor.label)
                            Text(e.constant ? "常驻 · \(e.position.label)" : "关键词：\(e.keys.joined(separator: "、"))")
                                .font(.caption).foregroundStyle(MolaColor.secondaryLabel).lineLimit(1)
                        }
                        .opacity(e.enabled ? 1 : 0.5)
                    }
                }
                .onDelete { profile?.lorebooks[bi].entries.remove(atOffsets: $0) }
                Button("添加条目", systemImage: "plus") { editingEntry = (bi, LoreEntry()); showEntry = true }
                DisclosureGroup("高级") {
                    Stepper("扫描深度：\(book.scanDepth)", value: Binding(get: { profile?.lorebooks[bi].scanDepth ?? 4 }, set: { profile?.lorebooks[bi].scanDepth = $0 }), in: 0...100)
                    Stepper("Token 预算：\(book.tokenBudget)", value: Binding(get: { profile?.lorebooks[bi].tokenBudget ?? 2048 }, set: { profile?.lorebooks[bi].tokenBudget = $0 }), in: 256...16384, step: 256)
                    Toggle("递归扫描", isOn: Binding(get: { profile?.lorebooks[bi].recursiveScanning ?? false }, set: { profile?.lorebooks[bi].recursiveScanning = $0 }))
                }
                Button("删除这本世界书", role: .destructive) { profile?.lorebooks.remove(at: bi) }
            } header: { Text("世界书 · \(book.entries.count) 条") }
        }
        Section {
            Button("新建世界书", systemImage: "book.closed") { profile?.lorebooks.append(Lorebook(name: "\(persona.name) 的世界书")) }
            let shared = app.store.lorebooks()
            if !shared.isEmpty {
                ForEach(shared) { b in
                    Toggle(isOn: Binding(get: { profile?.sharedLorebookIds.contains(b.id) ?? false }, set: { on in
                        profile?.sharedLorebookIds.removeAll { $0 == b.id }
                        if on { profile?.sharedLorebookIds.append(b.id) }
                    })) { Label(b.name, systemImage: "books.vertical") }
                }
            }
        } header: { Text("世界书") } footer: { Text("开启的共享世界书会与角色自带的世界书一起匹配。") }
    }
}

/// 世界书条目编辑。
struct LoreEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: LoreEntry
    let onSave: (LoreEntry) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可选）", text: $entry.name)
                    TextField("关键词（一行一个）", text: Binding(get: { entry.keys.joined(separator: "\n") },
                                                         set: { entry.keys = $0.components(separatedBy: "\n").compactMap { $0.trimmingCharacters(in: .whitespaces).nonBlank } }),
                              axis: .vertical).lineLimit(2...6)
                    TextField("内容", text: $entry.content, axis: .vertical).lineLimit(3...14)
                    Toggle("启用", isOn: $entry.enabled)
                    Toggle("常驻（不需要关键词）", isOn: $entry.constant)
                    Picker("插入位置", selection: $entry.position) {
                        ForEach(LorePosition.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if entry.position == .atDepth {
                        Stepper("深度：\(entry.depth)", value: $entry.depth, in: 0...100)
                        Picker("身份", selection: $entry.role) { Text("系统").tag("system"); Text("用户").tag("user"); Text("助手").tag("assistant") }
                    }
                    if entry.position == .outlet { TextField("出口名", text: Binding(get: { entry.outletName ?? "" }, set: { entry.outletName = $0.nonBlank })) }
                }
                Section("匹配") {
                    Toggle("区分大小写", isOn: $entry.caseSensitive)
                    Toggle("全词匹配", isOn: $entry.matchWholeWords)
                    Toggle("使用次要关键词", isOn: $entry.selective)
                    if entry.selective {
                        TextField("次要关键词（一行一个）", text: Binding(get: { entry.secondaryKeys.joined(separator: "\n") },
                                                                set: { entry.secondaryKeys = $0.components(separatedBy: "\n").compactMap { $0.trimmingCharacters(in: .whitespaces).nonBlank } }),
                                  axis: .vertical)
                        Picker("判定方式", selection: $entry.selectiveLogic) {
                            ForEach(SelectiveLogic.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    Stepper("扫描深度：\(entry.scanDepth.map(String.init) ?? "沿用")", value: Binding(get: { entry.scanDepth ?? -1 }, set: { entry.scanDepth = $0 < 0 ? nil : $0 }), in: -1...100)
                }
                Section("排序与预算") {
                    Stepper("次序：\(entry.order)", value: $entry.order, in: 0...1000)
                    Stepper("概率：\(entry.probability)%", value: $entry.probability, in: 0...100, step: 5)
                    Toggle("忽略预算", isOn: $entry.ignoreBudget)
                    TextField("分组（可选）", text: Binding(get: { entry.group ?? "" }, set: { entry.group = $0.nonBlank }))
                    if entry.group != nil {
                        Stepper("权重：\(entry.groupWeight)", value: $entry.groupWeight, in: 0...1000, step: 10)
                        Toggle("强制占位", isOn: $entry.groupOverride)
                    }
                }
                Section("递归") {
                    Toggle("不被递归触发", isOn: $entry.excludeRecursion)
                    Toggle("不触发递归", isOn: $entry.preventRecursion)
                    Stepper("延迟条数：\(entry.delay)", value: $entry.delay, in: 0...100)
                }
            }
            .navigationTitle("世界书条目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onSave(entry); dismiss() }.disabled(entry.content.nonBlank == nil)
                }
            }
        }
    }
}

/// 共享世界书列表与编辑。
struct LorebooksView: View {
    @Environment(AppModel.self) private var app
    @State private var revision = 0
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        let _ = revision
        List {
            let books = app.store.lorebooks()
            if books.isEmpty {
                ContentUnavailableView("没有共享世界书", systemImage: "books.vertical", description: Text("共享世界书可被多个角色引用。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(books) { b in
                NavigationLink(value: SettingsRoute.lorebook(b.id)) {
                    LabeledContent(b.name, value: "\(b.entries.count) 条")
                }
            }
            .onDelete { idx in idx.forEach { try? app.store.deleteLorebook(books[$0].id) }; revision += 1 }
        }
        .navigationTitle("共享世界书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("新建", systemImage: "plus") { try? app.store.upsert(Lorebook(name: "新世界书")); revision += 1 }
                    Button("导入 JSON", systemImage: "square.and.arrow.down") { importing = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: url), let j = JSONValue.parse(d) else { error = "不是有效的世界书 JSON"; return }
            let book = CharacterCardReader.lorebook(j["data"] ?? j, fallbackName: url.deletingPathExtension().lastPathComponent)
            try? app.store.upsert(book); revision += 1
        }
        .alert("导入失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") {} } message: { Text(error ?? "") }
        .onAppear { revision += 1 }
    }
}

struct LorebookEditView: View {
    @Environment(AppModel.self) private var app
    let bookId: String
    @State private var book: Lorebook?
    @State private var editing: LoreEntry?

    var body: some View {
        Form {
            if book != nil {
                Section {
                    TextField("名称", text: Binding(get: { book?.name ?? "" }, set: { book?.name = $0 }))
                    Stepper("扫描深度：\(book?.scanDepth ?? 4)", value: Binding(get: { book?.scanDepth ?? 4 }, set: { book?.scanDepth = $0 }), in: 0...100)
                    Stepper("Token 预算：\(book?.tokenBudget ?? 2048)", value: Binding(get: { book?.tokenBudget ?? 2048 }, set: { book?.tokenBudget = $0 }), in: 256...16384, step: 256)
                    Toggle("递归扫描", isOn: Binding(get: { book?.recursiveScanning ?? false }, set: { book?.recursiveScanning = $0 }))
                }
                Section("条目") {
                    ForEach(book?.entries ?? []) { e in
                        Button { editing = e } label: {
                            Text(e.name.nonBlank ?? e.keys.joined(separator: "、").nonBlank ?? "（未命名条目）").foregroundStyle(MolaColor.label)
                        }
                    }
                    .onDelete { book?.entries.remove(atOffsets: $0) }
                    Button("添加条目", systemImage: "plus") { editing = LoreEntry() }
                }
            }
        }
        .navigationTitle(book?.name ?? "世界书")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { book = app.store.lorebooks().first { $0.id == bookId } }
        .onChange(of: book) { _, b in if let b { try? app.store.upsert(b) } }
        .sheet(item: $editing) { e in
            LoreEntrySheet(entry: e) { saved in
                if let i = book?.entries.firstIndex(where: { $0.id == saved.id }) { book?.entries[i] = saved } else { book?.entries.append(saved) }
            }
        }
    }
}
