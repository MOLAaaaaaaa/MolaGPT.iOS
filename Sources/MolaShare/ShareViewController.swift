import UIKit
import SwiftUI
import UniformTypeIdentifiers
import MolaCore

/// 分享扩展入口（Info.plist `NSExtensionPrincipalClass` = MolaShareViewController）。
/// 读出分享内容 → 预览 + 可选补充一句话 → 落盘到 App Group 收件箱 → 尝试打开 MolaGPT；打不开时下次进入 App 自动接收。
@objc(MolaShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareComposeView(model: model, onCancel: { [weak self] in self?.cancel() },
                                    onSend: { [weak self] in self?.send() })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await model.load(items) }
    }

    private func cancel() {
        model.cleanup()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func send() {
        guard let root = ShareInbox.root() else {
            model.error = "无法访问共享存储（App Group 未生效），请重新安装 MolaGPT。"
            return
        }
        do {
            try model.save(to: root)
        } catch {
            model.error = "保存失败：\(error.localizedDescription)"
            return
        }
        model.cleanup()
        openHostApp(ShareInbox.openURL)
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// 分享扩展没有公开的打开宿主 App 接口；沿响应链找到 UIApplication 调用 open。失败也无妨，App 下次回到前台会接收。
    private func openHostApp(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
    }
}

// MARK: - 数据

@MainActor @Observable
final class ShareModel {
    struct Attachment: Identifiable {
        let id = UUID()
        let file: SharedFile
        let url: URL
        let thumbnail: UIImage?
    }

    var loading = true
    var texts: [String] = []
    var urls: [URL] = []
    var attachments: [Attachment] = []
    var prompt = ""
    var error: String?
    var skipped: [String] = []

    private let temp = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)

    var canSend: Bool {
        !loading && (!texts.isEmpty || !urls.isEmpty || !attachments.isEmpty || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func load(_ items: [NSExtensionItem]) async {
        defer { loading = false }
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        for item in items {
            if let t = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { texts.append(t) }
            for provider in item.attachments ?? [] { await load(provider) }
        }
        texts = texts.reduce(into: []) { acc, t in if !acc.contains(t) { acc.append(t) } }
    }

    private func load(_ p: NSItemProvider) async {
        // 网页链接（文件 URL 走附件分支）
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                if !urls.contains(url) { urls.append(url) }
                return
            }
        }
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let a = await copyFile(p, type: .image, isImage: true) { attachments.append(a); return }
            // 有些 App 只给 UIImage
            if let img = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier) as? UIImage, let data = img.jpegData(compressionQuality: 0.9) {
                let url = temp.appendingPathComponent("image_\(attachments.count + 1).jpg")
                if (try? data.write(to: url)) != nil {
                    attachments.append(Attachment(file: SharedFile(name: url.lastPathComponent, isImage: true), url: url, thumbnail: thumb(img)))
                }
                return
            }
        }
        if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: t), url.scheme?.hasPrefix("http") == true, !t.contains(" ") { if !urls.contains(url) { urls.append(url) } }
                else if !t.isEmpty { texts.append(t) }
                return
            }
        }
        // 其他文件：取第一个能落成文件的类型
        let type = p.registeredContentTypes.first { $0.conforms(to: .data) || $0.conforms(to: .content) } ?? .data
        if let a = await copyFile(p, type: type, isImage: type.conforms(to: .image)) { attachments.append(a) }
    }

    private func copyFile(_ p: NSItemProvider, type: UTType, isImage: Bool) async -> Attachment? {
        let temp = self.temp
        let suggested = p.suggestedName
        let result: (URL, Int)? = await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url else { cont.resume(returning: nil); return }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= ShareInbox.maxFileBytes else { cont.resume(returning: (url, size)); return }
                var name = suggested ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                if !ext.isEmpty, !name.lowercased().hasSuffix("." + ext.lowercased()) { name += "." + ext }
                let dest = temp.appendingPathComponent(UUID().uuidString.prefix(6) + "_" + name)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: (dest, size))
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
        guard let (url, size) = result else { return nil }
        if size > ShareInbox.maxFileBytes {
            skipped.append("\(suggested ?? url.lastPathComponent)（超过 50 MB）")
            return nil
        }
        let displayName = String(url.lastPathComponent.drop { $0 != "_" }.dropFirst())
        let thumbnail = isImage ? UIImage(contentsOfFile: url.path).flatMap(thumb) : nil
        return Attachment(file: SharedFile(name: displayName.isEmpty ? url.lastPathComponent : displayName, isImage: isImage),
                          url: url, thumbnail: thumbnail)
    }

    private func thumb(_ img: UIImage) -> UIImage? {
        img.preparingThumbnail(of: CGSize(width: 160, height: 160))
    }

    func save(to root: URL) throws {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = SharedItem(prompt: p.isEmpty ? nil : p, texts: texts, urls: urls.map(\.absoluteString))
        try ShareInbox.write(item, copying: attachments.map { ($0.file, $0.url) }, to: root)
    }

    func cleanup() { try? FileManager.default.removeItem(at: temp) }
}

// MARK: - 界面

private let accent = Color(red: 0xBE / 255, green: 0x72 / 255, blue: 0x7F / 255)

struct ShareComposeView: View {
    @Bindable var model: ShareModel
    let onCancel: () -> Void
    let onSend: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("想让 MolaGPT 做什么？（可选）", text: $model.prompt, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($focused)
                } footer: {
                    Text("将在 MolaGPT 中新建对话，确认后再发送。")
                }
                if model.loading {
                    Section { HStack { ProgressView(); Text("正在读取分享内容…").foregroundStyle(.secondary) } }
                }
                if !model.attachments.isEmpty {
                    Section("附件") {
                        let images = model.attachments.filter { $0.thumbnail != nil }
                        if !images.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(images) { a in
                                        Image(uiImage: a.thumbnail!)
                                            .resizable().scaledToFill()
                                            .frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                }
                            }
                        }
                        ForEach(model.attachments.filter { $0.thumbnail == nil }) { a in
                            Label(a.file.name, systemImage: a.file.isImage ? "photo" : "doc").lineLimit(1)
                        }
                    }
                }
                if !model.urls.isEmpty {
                    Section("链接") {
                        ForEach(model.urls, id: \.self) { u in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(u.host() ?? u.absoluteString).lineLimit(1)
                                    Text(u.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } icon: { Image(systemName: "link") }
                        }
                    }
                }
                if !model.texts.isEmpty {
                    Section("文字") {
                        ForEach(model.texts, id: \.self) { t in Text(t).lineLimit(6).font(.callout) }
                    }
                }
                if !model.skipped.isEmpty {
                    Section { Text("已跳过：" + model.skipped.joined(separator: "、")).font(.footnote).foregroundStyle(.secondary) }
                }
                if let e = model.error {
                    Section { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("MolaGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续", action: onSend).bold().disabled(!model.canSend)
                }
            }
        }
        .tint(accent)
    }
}
