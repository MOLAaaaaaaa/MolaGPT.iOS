import Foundation

// 分享扩展 → 主 App 的收件箱（App Group 共享容器 ShareInbox/<id>/item.json + 附件文件）。
// 扩展只负责落盘，主 App 回到前台或收到 molagpt://share 时取出，新建对话并填好草稿与附件（不自动发送）。

public struct SharedFile: Codable, Sendable, Hashable {
    public var name: String
    public var isImage: Bool
    public init(name: String, isImage: Bool) { self.name = name; self.isImage = isImage }
}

public struct SharedItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var createdAt: Int64
    /// 用户在分享面板里写的话。
    public var prompt: String?
    /// 分享来的纯文本 / 页面标题。
    public var texts: [String]
    public var urls: [String]
    public var files: [SharedFile]

    public init(id: String = UUID().uuidString, createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                prompt: String? = nil, texts: [String] = [], urls: [String] = [], files: [SharedFile] = []) {
        self.id = id; self.createdAt = createdAt; self.prompt = prompt; self.texts = texts; self.urls = urls; self.files = files
    }

    public var isEmpty: Bool {
        (prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && texts.isEmpty && urls.isEmpty && files.isEmpty
    }
}

public enum ShareInbox {
    public static let folderName = "ShareInbox"
    public static let declaredGroup = "group.com.molagpt.app"
    public static let openURL = URL(string: "molagpt://share")!
    /// 单个文件上限（扩展内存有限，也避免把视频塞进对话）。
    public static let maxFileBytes = 50 * 1024 * 1024

    /// 候选 App Group。xtool 个人签名会把 bundle ID 改成 `XTL-xxxx.com.molagpt.app`、组改成 `group.XTL-xxxx.com.molagpt.app`，
    /// 所以以主 App 实际 bundle ID 推导为先，再回退到声明的组名。扩展的 bundle ID 是 `<主 App>.<扩展名>`。
    public static func groupCandidates(bundleID: String?, isExtension: Bool) -> [String] {
        var out: [String] = []
        if var bid = bundleID, !bid.isEmpty {
            if isExtension, let dot = bid.lastIndex(of: ".") { bid = String(bid[..<dot]) }
            out.append("group." + bid)
        }
        if !out.contains(declaredGroup) { out.append(declaredGroup) }
        return out
    }

    /// 组合成对话草稿：用户的话在前，其次分享的文字与链接（去重）。
    public static func composeDraft(_ items: [SharedItem]) -> String {
        var parts: [String] = []
        var seen = Set<String>()
        func add(_ s: String?) {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, seen.insert(t).inserted else { return }
            parts.append(t)
        }
        for i in items { add(i.prompt) }
        for i in items {
            for t in i.texts { add(t) }
            for u in i.urls where !parts.contains(where: { $0.contains(u) }) { add(u) }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 文件读写（Darwin 上才有 App Group 容器）

    public static func root(bundle: Bundle = .main) -> URL? {
        #if canImport(Darwin)
        let isExt = bundle.bundlePath.hasSuffix(".appex")
        for g in groupCandidates(bundleID: bundle.bundleIdentifier, isExtension: isExt) {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) {
                return url.appendingPathComponent(folderName, isDirectory: true)
            }
        }
        #endif
        return nil
    }

    /// 写入一条分享。`files` 为 (文件名, 源文件 URL)，会拷贝进条目目录。
    public static func write(_ item: SharedItem, copying files: [(SharedFile, URL)], to root: URL) throws {
        let dir = root.appendingPathComponent(item.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var item = item
        item.files = []
        for (f, src) in files {
            var name = sanitize(f.name)
            var n = 1
            while item.files.contains(where: { $0.name == name }) { name = "\(n)_" + sanitize(f.name); n += 1 }
            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(name))
            item.files.append(SharedFile(name: name, isImage: f.isImage))
        }
        let data = try JSONEncoder().encode(item)
        // item.json 最后写：主 App 只认有 item.json 的目录，避免读到半成品。
        try data.write(to: dir.appendingPathComponent("item.json"), options: .atomic)
    }

    /// 待处理条目（按时间先后），附带条目目录。
    public static func pending(in root: URL) -> [(item: SharedItem, dir: URL)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> (SharedItem, URL)? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("item.json")),
                  let item = try? JSONDecoder().decode(SharedItem.self, from: data) else { return nil }
            return (item, dir)
        }
        .sorted { $0.0.createdAt < $1.0.createdAt }
    }

    public static func remove(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.prefix(120))
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "file" : trimmed
    }
}
