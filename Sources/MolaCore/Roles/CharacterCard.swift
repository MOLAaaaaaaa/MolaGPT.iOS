import Foundation

/// SillyTavern 角色卡导入（对应安卓 CharacterCardReader）：PNG（tEXt/iTXt 的 ccv3/chara）、JSON（V1/V2/V3）。
/// charX（zip）由 App 层解出 card.json 与头像后调用 `read(json:)`。
public enum CharacterCardReader {
    public struct Result: Sendable {
        public var persona: Persona
        public var avatar: Data?
    }

    public enum CardError: Error, LocalizedError {
        case notCard, unsupportedSpec(String), missingName, tooLarge
        public var errorDescription: String? {
            switch self {
            case .notCard: return "这个文件不是角色卡"
            case .unsupportedSpec(let s): return "不支持的角色卡规格：\(s)"
            case .missingName: return "角色卡缺少名称"
            case .tooLarge: return "文件过大（上限 16 MB）"
            }
        }
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func isPNG(_ d: Data) -> Bool { d.starts(with: pngSignature) }

    /// - Parameter inflate: zlib 解压（iTXt 压缩文本用，平台相关，由调用方提供）。
    public static func read(_ data: Data, inflate: (Data) -> Data? = { _ in nil }) throws -> Result {
        guard data.count <= 16 * 1024 * 1024 else { throw CardError.tooLarge }
        if isPNG(data) {
            guard let json = pngCardJSON(data, inflate: inflate) else { throw CardError.notCard }
            var r = try read(json: json)
            r.avatar = data
            return r
        }
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        return try read(json: d)
    }

    /// 遍历 PNG chunk，取 tEXt/iTXt 中关键字为 ccv3（优先）或 chara 的 base64 JSON。
    public static func pngCardJSON(_ data: Data, inflate: (Data) -> Data?) -> Data? {
        let b = [UInt8](data)
        var i = 8
        var found: [String: Data] = [:]
        while i + 12 <= b.count {
            let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            let start = i + 8, end = start + len
            guard end + 4 <= b.count else { break }
            if type == "tEXt" || type == "iTXt" {
                let chunk = Array(b[start..<end])
                if let nul = chunk.firstIndex(of: 0) {
                    let keyword = String(decoding: chunk[..<nul], as: UTF8.self).lowercased()
                    if keyword == "ccv3" || keyword == "chara" {
                        var text: [UInt8]
                        if type == "tEXt" {
                            text = Array(chunk[(nul + 1)...])
                        } else {
                            // keyword\0 compression_flag compression_method lang\0 translated\0 text
                            guard nul + 2 < chunk.count else { i = end + 4; continue }
                            let compressed = chunk[nul + 1] == 1
                            var p = nul + 3
                            guard let l1 = chunk[p...].firstIndex(of: 0) else { i = end + 4; continue }
                            p = l1 + 1
                            guard let l2 = chunk[p...].firstIndex(of: 0) else { i = end + 4; continue }
                            text = Array(chunk[(l2 + 1)...])
                            if compressed { text = inflate(Data(text)).map { [UInt8]($0) } ?? [] }
                        }
                        if let decoded = decodeBase64(String(decoding: text, as: UTF8.self)) { found[keyword] = decoded }
                    }
                }
            }
            if type == "IEND" { break }
            i = end + 4
        }
        return found["ccv3"] ?? found["chara"]
    }

    static func decodeBase64(_ s: String) -> Data? {
        var t = s.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    public static func read(json: Data) throws -> Result {
        guard let root = JSONValue.parse(json), root.objectValue != nil else { throw CardError.notCard }
        let spec = root["spec"]?.stringValue ?? ""
        let data: JSONValue
        var cardSpec = "chara_card_v1"
        if !spec.isEmpty {
            guard spec == "chara_card_v2" || spec == "chara_card_v3" else { throw CardError.unsupportedSpec(spec) }
            data = root["data"] ?? .object([:])
            cardSpec = spec
        } else {
            guard root["description"] != nil || root["first_mes"] != nil else { throw CardError.notCard }
            data = root
        }
        guard let name = data["name"]?.stringValue?.nonBlank else { throw CardError.missingName }
        func str(_ k: String) -> String { data[k]?.stringValue ?? "" }

        var p = PersonaProfile()
        p.mode = .atmosphere
        p.compatibility = .sillytavern
        p.cardSpec = cardSpec
        p.nickname = data["nickname"]?.stringValue?.nonBlank
        p.creator = data["creator"]?.stringValue?.nonBlank
        p.creatorNotes = data["creator_notes"]?.stringValue?.nonBlank
        p.characterVersion = data["character_version"]?.stringValue?.nonBlank
        p.tags = data["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []
        p.description = str("description")
        p.personality = str("personality")
        p.scenario = str("scenario")
        p.greeting = str("first_mes")
        p.alternateGreetings = data["alternate_greetings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        p.exampleDialogue = str("mes_example")
        p.postHistoryInstructions = str("post_history_instructions")
        let ext = data["extensions"]
        if let dp = ext?["depth_prompt"] {
            p.characterNote = dp["prompt"]?.stringValue ?? ""
            p.characterNoteDepth = dp["depth"]?.intValue ?? 4
            switch dp["role"]?.intValue ?? 0 { case 1: p.characterNoteRole = "user"; case 2: p.characterNoteRole = "assistant"; default: p.characterNoteRole = "system" }
            if let r = dp["role"]?.stringValue { p.characterNoteRole = r }
        }
        if let book = data["character_book"], book.objectValue != nil { p.lorebooks = [lorebook(book, fallbackName: "\(name) 的世界书")] }
        p.extensions = ext
        p.assets = data["assets"]
        var notes: [String] = []
        if let e = ext?.objectValue {
            if e["scripts"] != nil || e["ScriptLink"] != nil { notes.append("脚本扩展（已保留，不运行）") }
            if e["regex_scripts"] != nil { notes.append("局部正则（已保留，不运行）") }
            if e["risuai"] != nil { notes.append("RisuAI 扩展（已保留）") }
            let known: Set<String> = ["depth_prompt", "regex_scripts", "risuai", "scripts", "talkativeness", "fav", "world"]
            if e.keys.contains(where: { !known.contains($0) }) { notes.append("其他扩展（已保留）") }
        }
        if (data["assets"]?.arrayValue?.count ?? 0) > 1 { notes.append("资源清单（仅导入头像）") }
        p.importNotes = notes

        let persona = Persona(name: name, icon: "idea", systemPrompt: str("system_prompt"), profileJson: nil)
        var r = Result(persona: persona, avatar: nil)
        r.persona.profile = p
        return r
    }

    /// V2/V3 character_book（条目字段在 extensions 里）与 SillyTavern 原生导出（entries 为对象）都接受。
    public static func lorebook(_ book: JSONValue, fallbackName: String = "世界书") -> Lorebook {
        var lb = Lorebook(name: book["name"]?.stringValue?.nonBlank ?? fallbackName)
        lb.description = book["description"]?.stringValue
        lb.scanDepth = book["scan_depth"]?.intValue ?? 4
        lb.tokenBudget = book["token_budget"]?.intValue ?? 2048
        lb.recursiveScanning = book["recursive_scanning"]?.boolValue ?? false
        lb.cardData = book
        let raw: [JSONValue] = book["entries"]?.arrayValue ?? book["entries"]?.objectValue.map { Array($0.values) } ?? []
        lb.entries = raw.compactMap { e in
            var x = LoreEntry()
            let ex = e["extensions"]
            func pick(_ keys: String...) -> JSONValue? {
                for k in keys { if let v = e[k], !v.isNull { return v }; if let v = ex?[k], !v.isNull { return v } }
                return nil
            }
            x.name = pick("comment", "name")?.stringValue ?? ""
            x.keys = (pick("keys", "key")?.arrayValue ?? []).compactMap(\.stringValue)
            x.secondaryKeys = (pick("secondary_keys", "keysecondary")?.arrayValue ?? []).compactMap(\.stringValue)
            x.content = pick("content")?.stringValue ?? ""
            if let disable = e["disable"]?.boolValue { x.enabled = !disable } else { x.enabled = pick("enabled")?.boolValue ?? true }
            x.constant = pick("constant")?.boolValue ?? false
            x.selective = pick("selective")?.boolValue ?? false
            x.selectiveLogic = SelectiveLogic(rawValue: pick("selectiveLogic", "selective_logic")?.intValue ?? 0) ?? .andAny
            x.useRegex = pick("use_regex", "useRegex")?.boolValue ?? false
            x.caseSensitive = pick("case_sensitive", "caseSensitive")?.boolValue ?? false
            x.matchWholeWords = pick("match_whole_words", "matchWholeWords")?.boolValue ?? false
            if let pos = ex?["position"]?.intValue ?? e["position"]?.intValue { x.position = LorePosition(rawValue: pos) ?? .afterCharacter }
            else if let s = e["position"]?.stringValue { x.position = s == "before_char" ? .beforeCharacter : .afterCharacter }
            x.depth = pick("depth")?.intValue ?? 4
            switch pick("role")?.intValue ?? 0 { case 1: x.role = "user"; case 2: x.role = "assistant"; default: x.role = "system" }
            x.order = pick("insertion_order", "order")?.intValue ?? 100
            x.selectionPriority = pick("priority")?.intValue ?? 0
            x.probability = pick("probability")?.intValue ?? 100
            x.useProbability = pick("useProbability", "use_probability")?.boolValue ?? true
            x.group = pick("group")?.stringValue?.nonBlank
            x.groupWeight = pick("group_weight", "groupWeight")?.intValue ?? 100
            x.groupOverride = pick("group_override", "groupOverride")?.boolValue ?? false
            x.scanDepth = pick("scan_depth", "scanDepth")?.intValue
            x.excludeRecursion = pick("exclude_recursion", "excludeRecursion")?.boolValue ?? false
            x.preventRecursion = pick("prevent_recursion", "preventRecursion")?.boolValue ?? false
            x.delayUntilRecursion = pick("delay_until_recursion", "delayUntilRecursion")?.intValue ?? 0
            x.delay = pick("delay")?.intValue ?? 0
            x.sticky = pick("sticky")?.intValue ?? 0
            x.cooldown = pick("cooldown")?.intValue ?? 0
            x.cardData = e
            return x.content.isEmpty && x.keys.isEmpty ? nil : x
        }
        return lb
    }
}
