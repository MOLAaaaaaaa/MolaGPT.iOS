import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MolaCore
import MolaStorage

/// 输入栏，三种界面风格：
/// - iOS 原生：类「信息」App，左侧 `+`，胶囊输入框内嵌推理与发送
/// - Claude：输入框在上，下方一行附件 / 工具菜单 / 已开启工具 / 发送
/// - 安卓：上方 chip 行（角色 / 联网 / 推理），输入框右侧 `+` 与圆形发送
/// iOS 26 使用 Liquid Glass，17–25 回退到 `.bar` 材质。
struct ComposerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.uiStyle) private var style
    let controller: ChatController

    @FocusState private var focused: Bool
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var sent = 0

    var body: some View {
        @Bindable var c = controller
        VStack(spacing: 8) {
            banners
            switch style {
            case .claude: claudeComposer
            case .native: nativeComposer
            case .android: androidComposer
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            // iOS 26 之前没有滚动边缘效果，补一层渐隐让内容从输入栏下方淡出。
            if #unavailable(iOS 26.0) {
                LinearGradient(colors: [MolaColor.background.opacity(0), MolaColor.background], startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: sent)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in
                if let (data, mime) = ImageProcessing.prepare(img) {
                    controller.addAttachment(data: data, name: "photo_\(IDs.random(4)).jpg", mimeType: mime)
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: DocumentText.supportedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
    }

    private var placeholder: String {
        controller.editingMessageId != nil ? "编辑消息" : "发消息给 \(controller.chosenRole?.name ?? "MolaGPT")"
    }

    // MARK: 提示条

    @ViewBuilder
    private var banners: some View {
        if let err = controller.errorBanner {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(err).frame(maxWidth: .infinity, alignment: .leading)
                Button { controller.errorBanner = nil } label: { Image(systemName: "xmark") }
                    .foregroundStyle(MolaColor.secondaryLabel)
                    .accessibilityLabel("关闭")
            }
            .font(.footnote)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .molaGlass(in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if controller.editingMessageId != nil {
            HStack(spacing: 8) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(MolaColor.accent)
                Text("编辑后发送将创建新分支").frame(maxWidth: .infinity, alignment: .leading)
                Button("取消") { controller.cancelEdit() }.fontWeight(.semibold)
            }
            .font(.footnote)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .molaGlass(in: Capsule())
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(controller.pendingAttachments) { a in
                    AttachmentThumb(attachment: a, url: controller.attachmentURL(a), size: 60) {
                        withAnimation(.snappy) { controller.removeAttachment(a.id) }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 12).padding(.trailing, 6)
        }
    }

    // MARK: 按钮

    // MARK: - 共用

    private func field(lines: ClosedRange<Int>, padding: EdgeInsets) -> some View {
        TextField(placeholder, text: Binding(get: { controller.draft }, set: { controller.draft = $0 }), axis: .vertical)
            .lineLimit(lines)
            .focused($focused)
            .padding(padding)
            .submitLabel(app.settings.enterToSend ? .send : .return)
            .onChange(of: focused) { _, f in if f { controller.prewarmToken() } }
            .onChange(of: controller.draft) { _, new in
                if !new.isEmpty { controller.prewarmToken() }
                if app.settings.enterToSend, new.hasSuffix("\n") {
                    controller.draft = String(new.dropLast())
                    send()
                }
            }
    }

    @ViewBuilder private var attachItems: some View {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
        }
        Button { showPhotos = true } label: { Label("照片", systemImage: "photo.on.rectangle") }
        Button { showFiles = true } label: { Label("文件", systemImage: "folder") }
    }

    @ViewBuilder private var toolToggles: some View {
        if toolsSupported {
            Toggle(isOn: Binding(get: { controller.webEnabled }, set: { controller.webEnabled = $0 })) {
                Label("联网搜索", systemImage: "globe")
            }
            if app.settings.imageGenEnabled && !controller.isOfficial {
                Toggle(isOn: Binding(get: { controller.imageGenEnabled }, set: { controller.imageGenEnabled = $0 })) {
                    Label("生成图像", systemImage: "paintbrush")
                }
            }
        }
    }

    @ViewBuilder private var reasoningItems: some View {
        Toggle(isOn: Binding(get: { thinkingOn }, set: { v in controller.useThinking = v; app.settings.useThinking = v })) {
            Label(controller.thinkingAlwaysOn ? "推理（此模型常开）" : "推理", systemImage: "brain")
        }
        .disabled(controller.thinkingAlwaysOn)
        let levels = controller.effortLevels
        if thinkingOn && !levels.isEmpty {
            Picker(selection: Binding(get: { currentEffort(levels) }, set: { v in controller.reasoningEffort = v; app.settings.reasoningEffort = v })) {
                ForEach(levels.reversed(), id: \.self) { Text(Thinking.effortLabel($0)).tag($0) }
            } label: {
                Label("推理强度", systemImage: "gauge.with.dots.needle.50percent")
            }
            .pickerStyle(.menu)
        }
    }

    private var effortTitle: String {
        let levels = controller.effortLevels
        return levels.isEmpty ? "推理" : "推理 · \(Thinking.effortLabel(currentEffort(levels)))"
    }

    // MARK: - Claude 风格

    private var claudeComposer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !controller.pendingAttachments.isEmpty { attachmentStrip }
            field(lines: 1...8, padding: EdgeInsets(top: 12, leading: 14, bottom: 6, trailing: 14))
            HStack(spacing: 6) {
                attachMenu
                toolsMenu
                activeToolPills
                Spacer(minLength: 0)
                ContextGaugeButton(controller: controller)
                sendButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .molaGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - iOS 原生风格

    private var nativeComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                attachItems
                Section { toolToggles }
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(MolaColor.label)
                    .frame(width: 40, height: 40)
                    .molaGlass(in: Circle(), interactive: true)
            }
            .accessibilityLabel("添加附件")
            VStack(alignment: .leading, spacing: 0) {
                if !controller.pendingAttachments.isEmpty { attachmentStrip }
                if toolsSupported && (controller.webEnabled || activeImageGen) {
                    HStack(spacing: 6) {
                        if controller.webEnabled { pill("联网", "globe") { controller.webEnabled = false } }
                        if activeImageGen { pill("图像", "paintbrush") { controller.imageGenEnabled = false } }
                    }
                    .padding(.horizontal, 10).padding(.top, 8)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    field(lines: 1...8, padding: EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 0))
                    ContextGaugeButton(controller: controller)
                    if controller.thinkingConfig != nil {
                        Menu { reasoningItems } label: {
                            HStack(spacing: 2) {
                                Image(systemName: thinkingOn ? "brain.fill" : "brain")
                                if thinkingOn && !controller.effortLevels.isEmpty {
                                    Text(Thinking.effortLabel(currentEffort(controller.effortLevels))).font(.caption.weight(.semibold))
                                }
                            }
                            .foregroundStyle(thinkingOn ? MolaColor.accent : MolaColor.secondaryLabel)
                            .frame(minWidth: 32, minHeight: 36)
                        }
                        .accessibilityLabel(thinkingOn ? "推理已开启" : "推理已关闭")
                    }
                    sendButton.padding(.trailing, 4).padding(.bottom, 3)
                }
            }
            .molaGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - 安卓风格

    private var androidComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 与安卓一致：角色 chip 只对自行接入的模型显示
                    if !controller.isOfficial {
                        Menu {
                            RoleMenuItems(controller: controller)
                        } label: {
                            filterChip(controller.chosenRole?.name ?? "角色", icon: controller.chosenRole?.symbolName ?? "person.crop.circle",
                                       on: controller.chosenRole != nil, dropdown: true)
                        }
                    }
                    if toolsSupported {
                        Button { controller.webEnabled.toggle() } label: { filterChip("联网搜索", icon: "globe", on: controller.webEnabled) }
                        if app.settings.imageGenEnabled && !controller.isOfficial {
                            Button { controller.imageGenEnabled.toggle() } label: { filterChip("生成图像", icon: "paintbrush", on: controller.imageGenEnabled) }
                        }
                    }
                    if controller.thinkingConfig != nil {
                        Menu { reasoningItems } label: { filterChip(thinkingOn ? effortTitle : "推理", icon: "brain", on: thinkingOn, dropdown: true) }
                    }
                }
                .buttonStyle(.plain)
            }
            .scrollClipDisabled()
            if !controller.pendingAttachments.isEmpty { attachmentStrip }
            HStack(alignment: .bottom, spacing: 4) {
                field(lines: 1...6, padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 0))
                Menu { attachItems } label: {
                    Image(systemName: "plus.circle").font(.title3).foregroundStyle(MolaColor.secondaryLabel).frame(width: 36, height: 40)
                }
                .accessibilityLabel("添加附件")
                ContextGaugeButton(controller: controller)
                androidSend
            }
            .padding(.trailing, 6)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(MolaColor.background))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(MolaColor.androidOutline, lineWidth: 1))
        }
    }

    /// Material FilterChip：选中为主色容器 + 对勾，未选中为描边。
    private func filterChip(_ title: String, icon: String, on: Bool, dropdown: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark" : icon).font(.caption.weight(.semibold))
            Text(title).lineLimit(1)
            if dropdown { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)) }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(on ? MolaColor.accent : MolaColor.label)
        .padding(.horizontal, 12).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? MolaColor.androidContainer : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(on ? Color.clear : MolaColor.androidOutline, lineWidth: 1))
    }

    private var androidSend: some View {
        Group {
            if controller.isStreaming {
                Button { controller.stop() } label: {
                    Image(systemName: "stop.fill").font(.callout).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(MolaColor.androidError, in: Circle())
                }
                .accessibilityLabel("停止生成")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.callout.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(controller.canSend ? MolaColor.accent : Color(uiColor: .systemGray3), in: Circle())
                }
                .disabled(!controller.canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.bottom, 4)
        .animation(.snappy, value: controller.isStreaming)
    }

    /// 当前模型支持工具调用时才显示联网 / 生成图像开关。
    private var toolsSupported: Bool { controller.isOfficial || (controller.selection?.model.supportsToolCalling ?? false) }
    private var activeImageGen: Bool { !controller.isOfficial && app.settings.imageGenEnabled && controller.imageGenEnabled }

    private var attachMenu: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
            }
            Button { showPhotos = true } label: { Label("照片", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("文件", systemImage: "folder") }
        } label: {
            circleIcon("plus")
        }
        .accessibilityLabel("添加附件")
    }

    private func circleIcon(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name)
            .font(.body.weight(.medium))
            .foregroundStyle(active ? MolaColor.accent : MolaColor.label)
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(MolaColor.separator, lineWidth: 0.75))
            .contentShape(Circle())
    }

    private var thinkingOn: Bool { controller.useThinking || controller.thinkingAlwaysOn }

    /// 工具菜单：联网搜索、生成图像、推理（开关 + 强度）。
    private var toolsMenu: some View {
        Menu {
            if toolsSupported {
                Toggle(isOn: Binding(get: { controller.webEnabled }, set: { controller.webEnabled = $0 })) {
                    Label("联网搜索", systemImage: "globe")
                }
                if app.settings.imageGenEnabled {
                    Toggle(isOn: Binding(get: { controller.imageGenEnabled }, set: { controller.imageGenEnabled = $0 })) {
                        Label("生成图像", systemImage: "paintbrush")
                    }
                }
            }
            if controller.thinkingConfig != nil {
                Section {
                    Toggle(isOn: Binding(get: { thinkingOn }, set: { v in
                        controller.useThinking = v
                        app.settings.useThinking = v
                    })) {
                        Label(controller.thinkingAlwaysOn ? "推理（此模型常开）" : "推理", systemImage: "brain")
                    }
                    .disabled(controller.thinkingAlwaysOn)
                    let levels = controller.effortLevels
                    if thinkingOn && !levels.isEmpty {
                        Picker(selection: Binding(get: { currentEffort(levels) }, set: { v in
                            controller.reasoningEffort = v
                            app.settings.reasoningEffort = v
                        })) {
                            ForEach(levels.reversed(), id: \.self) { Text(Thinking.effortLabel($0)).tag($0) }
                        } label: {
                            Label("推理强度", systemImage: "gauge.with.dots.needle.50percent")
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            if !toolsSupported && controller.thinkingConfig == nil {
                Text("当前模型不支持工具与推理")
            }
        } label: {
            circleIcon("slider.horizontal.3")
        }
        .accessibilityLabel("工具")
    }

    /// 已开启的工具：小标签，点一下关闭（推理标签点开是强度菜单）。
    private var activeToolPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if toolsSupported && controller.webEnabled {
                    pill("联网", "globe") { controller.webEnabled = false }
                }
                if toolsSupported && activeImageGen {
                    pill("图像", "paintbrush") { controller.imageGenEnabled = false }
                }
                if controller.thinkingConfig != nil && thinkingOn {
                    let levels = controller.effortLevels
                    let title = levels.isEmpty ? "推理" : "推理 · \(Thinking.effortLabel(currentEffort(levels)))"
                    if controller.thinkingAlwaysOn || levels.isEmpty {
                        pill(title, "brain", closable: !controller.thinkingAlwaysOn) { controller.useThinking = false; app.settings.useThinking = false }
                    } else {
                        Menu {
                            Picker("推理强度", selection: Binding(get: { currentEffort(levels) }, set: { v in
                                controller.reasoningEffort = v; app.settings.reasoningEffort = v
                            })) {
                                ForEach(levels.reversed(), id: \.self) { Text(Thinking.effortLabel($0)).tag($0) }
                            }
                            Button("关闭推理", systemImage: "xmark") { controller.useThinking = false; app.settings.useThinking = false }
                        } label: { pillLabel(title, "brain", closable: false) }
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    private func pill(_ title: String, _ icon: String, closable: Bool = true, off: @escaping () -> Void) -> some View {
        Button(action: off) { pillLabel(title, icon, closable: closable) }
            .buttonStyle(.plain)
            .disabled(!closable)
            .accessibilityLabel("关闭\(title)")
    }

    private func pillLabel(_ title: String, _ icon: String, closable: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title)
            if closable { Image(systemName: "xmark").font(.caption2.weight(.bold)).opacity(0.6) }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(MolaColor.accent)
        .padding(.horizontal, 10).frame(height: 30)
        .background(MolaColor.accentSoft, in: Capsule())
    }

    private func currentEffort(_ levels: [String]) -> String {
        if levels.contains(controller.reasoningEffort) { return controller.reasoningEffort }
        guard let cfg = controller.thinkingConfig else { return Thinking.high }
        return Thinking.resolveDefaultEffort(cfg, baseUrl: controller.selection?.provider.baseUrl ?? "")
    }

    private var sendButton: some View {
        Group {
            if controller.isStreaming {
                Button { controller.stop() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, MolaColor.label)
                }
                .accessibilityLabel("停止生成")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, controller.canSend ? MolaColor.accent : Color(uiColor: .systemGray3))
                }
                .disabled(!controller.canSend)
                .accessibilityLabel("发送")
            }
        }
                .contentTransition(.symbolEffect(.replace))
        .animation(.snappy, value: controller.isStreaming)
    }

    private func send() {
        if app.modelGroups.isEmpty { app.openSettings(.providers); return }
        guard controller.canSend else { return }
        controller.send()
        sent += 1
    }

    // MARK: 附件读取

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data), let (jpeg, mime) = ImageProcessing.prepare(img) else { continue }
            controller.addAttachment(data: jpeg, name: "image_\(IDs.random(4)).jpg", mimeType: mime)
        }
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            controller.importFile(url)
        }
    }
}
