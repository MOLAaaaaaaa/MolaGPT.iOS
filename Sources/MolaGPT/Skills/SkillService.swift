import Foundation
import Observation
import MolaCore
import MolaStorage

/// 技能仓库：`Documents/skills/<uuid>/`，每个目录里有 SKILL.md 与引用文件（对应安卓 SkillRepository）。
@MainActor
@Observable
final class SkillService {
    @ObservationIgnored unowned let app: AppModel
    private(set) var skills: [SkillInfo] = []

    init(app: AppModel) {
        self.app = app
        reload()
    }

    var root: URL { AppPaths.skills }

    func register(on planner: TurnPlanner) {
        planner.availabilityContributors.append { [unowned self] _, _, a in
            a.skills = self.enabledSkills.map(\.name)
        }
        planner.systemContributors.append(("skills", { [unowned self] _, model in
            model.supportsToolCalling ? SkillFormat.catalog(self.enabledSkills) : nil
        }))
        let rootURL = root
        planner.localHandlers["read_skill"] = { [weak self] call, _ in
            guard let self else { return nil }
            let list = await MainActor.run { self.enabledSkills }
            return Self.read(call, skills: list, root: rootURL)
        }
    }

    var enabledSkills: [SkillInfo] {
        guard app.settings.skillsEnabled else { return [] }
        return skills.filter { !app.settings.disabledSkillIds.contains($0.id) }
    }

    func isEnabled(_ s: SkillInfo) -> Bool { !app.settings.disabledSkillIds.contains(s.id) }

    func setEnabled(_ s: SkillInfo, _ on: Bool) {
        app.settings.disabledSkillIds.removeAll { $0 == s.id }
        if !on { app.settings.disabledSkillIds.append(s.id) }
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        skills = dirs.compactMap { dir in
            guard let md = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8),
                  let fmData = try? SkillFormat.frontmatter(md) else { return nil }
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            return SkillInfo(id: dir.lastPathComponent, name: fmData.name, description: fmData.description,
                             compatibility: fmData.compatibility, installedAt: Int64(created.timeIntervalSince1970 * 1000))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    enum ImportError: LocalizedError {
        case duplicate(String), noSkillFile, tooLarge, unsafePath(String)
        var errorDescription: String? {
            switch self {
            case .duplicate(let n): return "已安装同名技能「\(n)」"
            case .noSkillFile: return "压缩包里找不到 SKILL.md（需在根目录或唯一的一级子目录内）"
            case .tooLarge: return "技能包过大（最多 256 个文件、解压后 16 MB）"
            case .unsafePath(let p): return "压缩包包含不安全的路径：\(p)"
            }
        }
    }

    /// 导入 SKILL.md 文本。
    @discardableResult
    func importMarkdown(_ text: String) throws -> SkillInfo {
        let meta = try SkillFormat.frontmatter(text)
        try checkDuplicate(meta.name)
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        reload()
        return skills.first { $0.id == id }!
    }

    /// 导入文件：以 `PK\x03\x04` 判断 zip，否则按 SKILL.md 处理。
    @discardableResult
    func importFile(_ url: URL) throws -> SkillInfo {
        let data = try Data(contentsOf: url)
        if MiniZip.isZip(data) { return try importZip(data) }
        return try importMarkdown(String(decoding: data, as: UTF8.self))
    }

    func importZip(_ data: Data) throws -> SkillInfo {
        let zip = try MiniZip(data)
        let entries = zip.files
        guard entries.count <= SkillFormat.maxEntries,
              entries.reduce(0, { $0 + $1.uncompressedSize }) <= SkillFormat.maxTotalBytes else { throw ImportError.tooLarge }
        for e in entries where !SkillFormat.isSafeRelative(e.path) { throw ImportError.unsafePath(e.path) }
        // SKILL.md 在根目录，或在唯一的一级子目录内。
        var prefix = ""
        if !entries.contains(where: { $0.path == "SKILL.md" }) {
            let tops = Set(entries.compactMap { $0.path.split(separator: "/").first.map(String.init) })
            guard tops.count == 1, let top = tops.first, entries.contains(where: { $0.path == "\(top)/SKILL.md" }) else { throw ImportError.noSkillFile }
            prefix = top + "/"
        }
        guard let skillEntry = entries.first(where: { $0.path == prefix + "SKILL.md" }) else { throw ImportError.noSkillFile }
        let meta = try SkillFormat.frontmatter(String(decoding: try zip.extract(skillEntry), as: UTF8.self))
        try checkDuplicate(meta.name)
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        do {
            for e in entries where e.path.hasPrefix(prefix) {
                let rel = String(e.path.dropFirst(prefix.count))
                let dest = dir.appendingPathComponent(rel)
                guard dest.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path) else { throw ImportError.unsafePath(e.path) }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try zip.extract(e).write(to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        reload()
        return skills.first { $0.id == id }!
    }

    private func checkDuplicate(_ name: String) throws {
        if skills.contains(where: { $0.name.lowercased() == name.lowercased() }) { throw ImportError.duplicate(name) }
    }

    func delete(_ s: SkillInfo) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(s.id, isDirectory: true))
        app.settings.disabledSkillIds.removeAll { $0 == s.id }
        reload()
    }

    func files(_ s: SkillInfo) -> [String] {
        let dir = root.appendingPathComponent(s.id, isDirectory: true)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { ($0 as? URL) }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1)) }.sorted()
    }

    func text(_ s: SkillInfo, path: String = "SKILL.md") -> String? {
        try? String(contentsOf: root.appendingPathComponent(s.id).appendingPathComponent(path), encoding: .utf8)
    }

    /// read_skill：只读 UTF-8 文本、无 NUL、≤1 MB，每页 16000 字符。
    nonisolated static func read(_ call: PendingToolCall, skills: [SkillInfo], root: URL) -> ToolResult {
        guard let name = call.string("skill"), let skill = skills.first(where: { $0.name == name }) else { return .failure("Skill failed: 未找到技能") }
        let path = call.string("path")?.nonBlank ?? "SKILL.md"
        guard SkillFormat.isSafeRelative(path) else { return .failure("Skill failed: 路径无效") }
        let dir = root.appendingPathComponent(skill.id, isDirectory: true)
        let url = dir.appendingPathComponent(path)
        guard url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path),
              let data = try? Data(contentsOf: url) else { return .failure("Skill failed: 文件不存在：\(path)") }
        guard data.count <= SkillFormat.maxTextFileBytes, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .failure("Skill failed: 只能读取 1 MB 以内的 UTF-8 文本文件")
        }
        return ToolResult(SkillFormat.page(name: skill.name, path: path, text: text, offset: call.int("offset") ?? 0))
    }
}
