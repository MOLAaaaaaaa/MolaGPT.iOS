import Foundation
import MolaCore

/// 共享世界书（对应安卓 LorebookRepository），整本以 JSON 存储。
extension MolaStore {
    public func lorebooks() -> [Lorebook] {
        (try? db.query("SELECT json FROM lorebooks ORDER BY updated_at DESC") { decodeJSON(Lorebook.self, $0.string(0)) })?.compactMap { $0 } ?? []
    }

    public func upsert(_ b: Lorebook) throws {
        try db.run("INSERT OR REPLACE INTO lorebooks (id,name,json,updated_at) VALUES (?,?,?,?)",
                   [.text(b.id), .text(b.name), .json(b), .of(IDs.nowMs())])
    }

    public func deleteLorebook(_ id: String) throws {
        try db.run("DELETE FROM lorebooks WHERE id = ?", [.text(id)])
    }

    public func duplicate(_ p: Persona) throws -> Persona {
        let maxOrder = (try? db.query("SELECT MAX(sort_order) FROM personas") { $0.int(0) })?.first ?? 0
        let copy = p.draftCopy(sortOrder: maxOrder + 1)
        try upsert(copy)
        return copy
    }

    /// 同名角色自动加序号（`名称 2`）。
    public func uniquePersonaName(_ name: String) -> String {
        let names = Set(personas().map(\.name))
        guard names.contains(name) else { return name }
        var i = 2
        while names.contains("\(name) \(i)") { i += 1 }
        return "\(name) \(i)"
    }
}
