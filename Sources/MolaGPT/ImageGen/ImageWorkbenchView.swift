import SwiftUI
import PhotosUI
import MolaCore
import MolaStorage

/// 画图工作台（全屏）：任务列表 → 任务时间线 + 输入区；画廊、Base64 工具。
struct ImageWorkbenchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var path: [WorkbenchRoute] = []

    enum WorkbenchRoute: Hashable { case task(String), gallery, base64 }

    var body: some View {
        let _ = app.images.revision
        NavigationStack(path: $path) {
            List {
                if app.images.targets.isEmpty {
                    ContentUnavailableView {
                        Label("添加图像服务", systemImage: "paintbrush")
                    } description: {
                        Text("在模型服务里把服务用途设为「图像」，或在模型编辑页开启「图像生成」。")
                    } actions: {
                        Button("打开模型服务") { dismiss(); app.openSettings(.providers) }
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    NavigationLink(value: WorkbenchRoute.gallery) { Label("画廊", systemImage: "photo.on.rectangle.angled") }
                    NavigationLink(value: WorkbenchRoute.base64) { Label("Base64 图片工具", systemImage: "curlybraces") }
                }
                Section("任务") {
                    ForEach(app.store.imageTasks()) { t in
                        NavigationLink(value: WorkbenchRoute.task(t.id)) {
                            HStack(spacing: 12) {
                                thumbnail(t)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).lineLimit(1)
                                    Text(t.updatedAt.relativeText).font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                                }
                                Spacer()
                                if app.images.runningTaskIds.contains(t.id) { ProgressView() }
                            }
                        }
                        .swipeActions { Button("删除", role: .destructive) { app.images.delete(t) } }
                    }
                }
            }
            .navigationTitle("画图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("新建", systemImage: "square.and.pencil") { path.append(.task(app.images.newTask().id)) }
                        .disabled(app.images.targets.isEmpty)
                }
            }
            .navigationDestination(for: WorkbenchRoute.self) { r in
                switch r {
                case .task(let id): ImageTaskView(taskId: id)
                case .gallery: ImageGalleryView()
                case .base64: Base64ToolView()
                }
            }
            .onAppear {
                if let id = app.imageTaskToOpen { path = [.task(id)]; app.imageTaskToOpen = nil }
            }
        }
    }

    @ViewBuilder private func thumbnail(_ t: ImageTask) -> some View {
        let src = app.store.imageVersions(task: t.id).last { $0.status == .success }?.outputs.first?.src
        Group {
            if let src, let img = LocalImages.load(src) { Image(uiImage: img).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(MolaColor.tertiaryLabel) }
        }
        .frame(width: 44, height: 44)
        .background(MolaColor.fill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension Int64 {
    var relativeText: String { Date(timeIntervalSince1970: Double(self) / 1000).formatted(.relative(presentation: .named)) }
}

struct ImageTaskView: View {
    @Environment(AppModel.self) private var app
    let taskId: String
    @State private var prompt = ""
    @State private var refs: [ImageRef] = []
    @State private var size = "1024x1024"
    @State private var count = 1
    @State private var params = ImageParams()
    @State private var perImage = false
    @State private var photo: [PhotosPickerItem] = []
    @State private var renaming = false
    @State private var title = ""

    private var task: ImageTask? { app.store.imageTasks().first { $0.id == taskId } }

    var body: some View {
        let _ = app.images.revision
        let runs = app.store.imageRuns(taskId)
        let versions = app.store.imageVersions(task: taskId)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if runs.isEmpty {
                        ContentUnavailableView("要创作点什么？", systemImage: "sparkles", description: Text("描述画面，或添加参考图进行编辑。"))
                            .padding(.top, 80)
                    }
                    ForEach(runs) { run in
                        RunCard(run: run, versions: versions.filter { $0.runId == run.id }, onUse: { src in refs.append(ImageRef(src: src, fromOutput: true)) })
                            .id(run.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: runs.count) { _, _ in if let last = runs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(task?.title ?? "画图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let t = task {
                        Picker("模型", selection: Binding(get: { "\(t.providerId ?? "")::\(t.modelId ?? "")" }, set: { v in
                            var nt = t; let parts = v.components(separatedBy: "::"); nt.providerId = parts.first; nt.modelId = parts.last
                            try? app.store.upsert(nt); app.images.objectWillChangeHack()
                        })) {
                            ForEach(app.images.targets, id: \.1.id) { p, m in Text("\(m.displayName) · \(p.name)").tag("\(p.id)::\(m.id)") }
                        }
                        Picker("模式", selection: Binding(get: { t.mode }, set: { var nt = t; nt.mode = $0; try? app.store.upsert(nt); app.images.objectWillChangeHack() })) {
                            ForEach(WorkbenchMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Button("重命名", systemImage: "pencil") { title = t.title; renaming = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("重命名", isPresented: $renaming) {
            TextField("标题", text: $title)
            Button("取消", role: .cancel) {}
            Button("保存") { if var t = task, let v = title.nonBlank { t.title = v; try? app.store.upsert(t); app.images.objectWillChangeHack() } }
        }
        .onChange(of: photo) { _, items in
            guard !items.isEmpty else { return }
            photo = []
            Task {
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d), let png = img.pngData(),
                       let out = ImageTaskManager.save("data:image/png;base64,\(png.base64EncodedString())") {
                        refs.append(ImageRef(src: out.src))
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !refs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(refs.enumerated()), id: \.offset) { i, r in
                            ZStack(alignment: .topTrailing) {
                                if let img = LocalImages.load(r.src) { Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8)) }
                                Button { refs.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6)) }
                                    .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                if refs.count >= 2 { Toggle("逐张编辑", isOn: $perImage).font(.footnote) }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photo, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "photo.badge.plus").font(.title3).frame(width: 36, height: 36)
                }
                Menu {
                    Picker("尺寸", selection: $size) { ForEach(WorkbenchPlan.sizes, id: \.0) { Text("\($0.1) · \($0.0)").tag($0.0) } }
                    Picker("张数", selection: $count) { ForEach(WorkbenchPlan.counts, id: \.self) { Text("\($0) 张").tag($0) } }
                    Picker("质量", selection: $params.quality) { ForEach(["auto", "high", "medium", "low"], id: \.self) { Text($0).tag($0) } }
                    Picker("格式", selection: $params.outputFormat) { ForEach(["png", "jpeg", "webp"], id: \.self) { Text($0).tag($0) } }
                    Picker("背景", selection: $params.background) { ForEach(["auto", "transparent", "opaque"], id: \.self) { Text($0).tag($0) } }
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 36, height: 36)
                }
                TextField("描述画面…", text: $prompt, axis: .vertical).lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(MolaColor.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    guard let t = task, let p = prompt.nonBlank else { return }
                    app.images.submit(task: t, prompt: p, refs: refs, size: size, count: count, params: params, perImage: perImage)
                    prompt = ""; refs = []
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, prompt.nonBlank == nil ? Color(uiColor: .systemGray3) : MolaColor.accent)
                }
                .disabled(prompt.nonBlank == nil || task == nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

private struct RunCard: View {
    @Environment(AppModel.self) private var app
    let run: ImageRun
    let versions: [ImageVersion]
    let onUse: (String) -> Void
    @State private var index: Int?

    var body: some View {
        let current = min(index ?? (versions.firstIndex { $0.id == run.activeVersionId } ?? max(versions.count - 1, 0)), max(versions.count - 1, 0))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(run.prompt).font(.callout)
                Spacer()
                Text(run.size).font(.caption2.monospaced()).foregroundStyle(MolaColor.tertiaryLabel)
            }
            if versions.indices.contains(current) {
                let v = versions[current]
                switch v.status {
                case .running:
                    HStack { ProgressView(); Text("正在生成…").foregroundStyle(MolaColor.secondaryLabel); Spacer()
                        Button("取消") { app.images.cancel(v.id) }.font(.footnote) }
                        .frame(height: 120)
                case .failed, .canceled:
                    VStack(alignment: .leading, spacing: 6) {
                        Label(v.error ?? "生成失败", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                        Button("重试", systemImage: "arrow.clockwise") { app.images.retry(v, run: run) }.font(.footnote)
                    }
                case .success:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(Array(v.outputs.enumerated()), id: \.offset) { _, o in
                            RemoteOrDataImage(urlString: o.src)
                                .contextMenu {
                                    Button("作为参考图", systemImage: "photo.badge.arrow.down") { onUse(o.src) }
                                    if let img = LocalImages.load(o.src) {
                                        ShareLink(item: Image(uiImage: img), preview: SharePreview("图片", image: Image(uiImage: img)))
                                    }
                                }
                        }
                    }
                }
            }
            HStack {
                if versions.count > 1 {
                    VersionSwitcher(position: current + 1, count: versions.count, disabled: false) { index = $0 - 1 }
                }
                Spacer()
                Button("再次生成", systemImage: "arrow.triangle.2.circlepath") { app.images.regenerate(run); index = nil }
                    .font(.footnote).buttonStyle(.borderless)
                    .disabled(versions.last?.status == .running)
            }
        }
        .padding(12)
        .background(MolaColor.secondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ImageGalleryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let _ = app.images.revision
        let outputs = app.store.allSuccessVersions().flatMap(\.outputs)
        ScrollView {
            if outputs.isEmpty { ContentUnavailableView("还没有图片", systemImage: "photo.on.rectangle").padding(.top, 80) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)], spacing: 4) {
                ForEach(Array(outputs.enumerated()), id: \.offset) { _, o in
                    RemoteOrDataImage(urlString: o.src)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                }
            }
            .padding(4)
        }
        .navigationTitle("画廊")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Base64 / data URL → 图片预览，可保存到相册。
struct Base64ToolView: View {
    @State private var text = ""
    @State private var preview = false

    private var image: UIImage? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = s.firstIndex(of: ","), s.hasPrefix("data:") { s = String(s[s.index(after: comma)...]) }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters).flatMap(UIImage.init(data:))
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).font(.caption.monospaced()).frame(minHeight: 160)
                Button("粘贴", systemImage: "doc.on.clipboard") { text = UIPasteboard.general.string ?? "" }
            } footer: { Text("支持纯 Base64 或 data:image/…;base64, 开头的 Data URL。") }
            if let img = image {
                Section("预览") {
                    Image(uiImage: img).resizable().scaledToFit().onTapGesture { preview = true }
                    Text("\(Int(img.size.width)) × \(Int(img.size.height))").font(.caption)
                }
            } else if !text.isEmpty {
                Section { Text("无法解析为图片").foregroundStyle(.red) }
            }
        }
        .navigationTitle("Base64 图片")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $preview) {
            if let png = image?.pngData() { ImagePreview(urlString: "data:image/png;base64,\(png.base64EncodedString())") }
        }
    }
}
