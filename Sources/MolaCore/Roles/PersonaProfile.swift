import Foundation

// 角色扮演资料（对应安卓 Persona.kt / CharacterCard.kt）。字段名与 Kotlin 属性同名，保证两端 profileJson 互通。

public enum ConversationMode: String, Codable, Sendable, CaseIterable { case chat, atmosphere }
public enum CardCompatibility: String, Codable, Sendable { case spec, sillytavern }

/// 世界书条目插入位置（数值与安卓 LorePosition 序号一致）。
public enum LorePosition: Int, Codable, Sendable, CaseIterable {
    case beforeCharacter = 0, afterCharacter, beforeNote, afterNote, atDepth, beforeExamples, afterExamples, outlet
    public var label: String {
        switch self {
        case .beforeCharacter: return "角色设定前"
        case .afterCharacter: return "角色设定后"
        case .beforeNote: return "角色补充前"
        case .afterNote: return "角色补充后"
        case .atDepth: return "按深度插入"
        case .beforeExamples: return "示例对话前"
        case .afterExamples: return "示例对话后"
        case .outlet: return "出口"
        }
    }
}

public enum SelectiveLogic: Int, Codable, Sendable, CaseIterable {
    case andAny = 0, notAll, notAny, andAll
    public var label: String {
        switch self { case .andAny: return "包含任一"; case .notAll: return "不全包含"; case .notAny: return "都不包含"; case .andAll: return "全部包含" }
    }
}

public enum LoreScanScope: String, Codable, Sendable { case inherit, none, recent, all }

public struct LoreEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String = IDs.generic("lore")
    public var name: String = ""
    public var keys: [String] = []
    public var secondaryKeys: [String] = []
    public var content: String = ""
    public var enabled: Bool = true
    public var constant: Bool = false
    public var selective: Bool = false
    public var selectiveLogic: SelectiveLogic = .andAny
    public var useRegex: Bool = false
    public var caseSensitive: Bool = false
    public var matchWholeWords: Bool = false
    public var position: LorePosition = .afterCharacter
    public var depth: Int = 4
    public var role: String = "system"
    public var outletName: String?
    public var order: Int = 100
    public var selectionPriority: Int = 0
    public var probability: Int = 100
    public var useProbability: Bool = true
    public var ignoreBudget: Bool = false
    public var group: String?
    public var groupWeight: Int = 100
    public var groupOverride: Bool = false
    public var scanDepth: Int?
    public var scanScope: LoreScanScope = .inherit
    public var excludeRecursion: Bool = false
    public var preventRecursion: Bool = false
    public var delayUntilRecursion: Int = 0
    public var delay: Int = 0
    public var sticky: Int = 0
    public var cooldown: Int = 0
    public var cardData: JSONValue?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LoreEntry()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = v(.id, d.id); name = v(.name, ""); keys = v(.keys, []); secondaryKeys = v(.secondaryKeys, []); content = v(.content, "")
        enabled = v(.enabled, true); constant = v(.constant, false); selective = v(.selective, false); selectiveLogic = v(.selectiveLogic, .andAny)
        useRegex = v(.useRegex, false); caseSensitive = v(.caseSensitive, false); matchWholeWords = v(.matchWholeWords, false)
        position = v(.position, .afterCharacter); depth = v(.depth, 4); role = v(.role, "system"); outletName = v(.outletName, nil)
        order = v(.order, 100); selectionPriority = v(.selectionPriority, 0); probability = v(.probability, 100); useProbability = v(.useProbability, true)
        ignoreBudget = v(.ignoreBudget, false); group = v(.group, nil); groupWeight = v(.groupWeight, 100); groupOverride = v(.groupOverride, false)
        scanDepth = v(.scanDepth, nil); scanScope = v(.scanScope, .inherit); excludeRecursion = v(.excludeRecursion, false)
        preventRecursion = v(.preventRecursion, false); delayUntilRecursion = v(.delayUntilRecursion, 0); delay = v(.delay, 0)
        sticky = v(.sticky, 0); cooldown = v(.cooldown, 0); cardData = v(.cardData, nil)
    }
}

public struct Lorebook: Codable, Sendable, Hashable, Identifiable {
    public var id: String = IDs.generic("book")
    public var name: String = "世界书"
    public var description: String?
    public var enabled: Bool = true
    public var scanDepth: Int = 4
    public var tokenBudget: Int = 2048
    public var recursiveScanning: Bool = false
    public var entries: [LoreEntry] = []
    public var cardData: JSONValue?

    public init(name: String = "世界书") { self.name = name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = v(.id, IDs.generic("book")); name = v(.name, "世界书"); description = v(.description, nil); enabled = v(.enabled, true)
        scanDepth = v(.scanDepth, 4); tokenBudget = v(.tokenBudget, 2048); recursiveScanning = v(.recursiveScanning, false)
        entries = v(.entries, []); cardData = v(.cardData, nil)
    }
}

public struct PersonaProfile: Codable, Sendable, Hashable {
    public var mode: ConversationMode?
    public var compatibility: CardCompatibility = .spec
    public var cardSpec: String = "chara_card_v3"
    public var nickname: String?
    public var creator: String?
    public var creatorNotes: String?
    public var characterVersion: String?
    public var tags: [String] = []
    public var summary: String?
    public var description: String = ""
    public var personality: String = ""
    public var scenario: String = ""
    public var userName: String?
    public var useProfileName: Bool = true
    public var userDescription: String = ""
    public var greeting: String = ""
    public var alternateGreetings: [String] = []
    public var exampleDialogue: String = ""
    public var postHistoryInstructions: String = ""
    public var characterNote: String = ""
    public var characterNoteDepth: Int = 4
    public var characterNoteRole: String = "system"
    public var lorebooks: [Lorebook] = []
    public var embeddedLorebookId: String?
    public var sharedLorebookIds: [String] = []
    public var loreBudget: Int = 2048
    public var extensions: JSONValue?
    public var assets: JSONValue?
    public var importNotes: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        mode = v(.mode, nil); compatibility = v(.compatibility, .spec); cardSpec = v(.cardSpec, "chara_card_v3")
        nickname = v(.nickname, nil); creator = v(.creator, nil); creatorNotes = v(.creatorNotes, nil); characterVersion = v(.characterVersion, nil)
        tags = v(.tags, []); summary = v(.summary, nil); description = v(.description, ""); personality = v(.personality, "")
        scenario = v(.scenario, ""); userName = v(.userName, nil); useProfileName = v(.useProfileName, true); userDescription = v(.userDescription, "")
        greeting = v(.greeting, ""); alternateGreetings = v(.alternateGreetings, []); exampleDialogue = v(.exampleDialogue, "")
        postHistoryInstructions = v(.postHistoryInstructions, ""); characterNote = v(.characterNote, ""); characterNoteDepth = v(.characterNoteDepth, 4)
        characterNoteRole = v(.characterNoteRole, "system"); lorebooks = v(.lorebooks, []); embeddedLorebookId = v(.embeddedLorebookId, nil)
        sharedLorebookIds = v(.sharedLorebookIds, []); loreBudget = v(.loreBudget, 2048); extensions = v(.extensions, nil)
        assets = v(.assets, nil); importNotes = v(.importNotes, [])
    }

    /// mode 为空时：有任一角色扮演字段就判为 atmosphere。
    public var defaultMode: ConversationMode {
        if let mode { return mode }
        let rp = [description, personality, scenario, greeting, exampleDialogue].contains { !$0.isEmpty } || !lorebooks.isEmpty
        return rp ? .atmosphere : .chat
    }

    /// 没有任何会进提示词的内容。
    public var isEmpty: Bool {
        [description, personality, scenario, userDescription, greeting, exampleDialogue, postHistoryInstructions, characterNote]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && alternateGreetings.isEmpty && lorebooks.allSatisfy { $0.entries.isEmpty } && sharedLorebookIds.isEmpty
    }
}

extension Persona {
    public var profile: PersonaProfile? {
        get {
            guard let s = profileJson, let d = s.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(PersonaProfile.self, from: d)
        }
        set {
            profileJson = newValue.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
        }
    }

    public var isRolePlay: Bool { profile?.defaultMode == .atmosphere }

    /// 列表预览：summary → description 首行 → systemPrompt 首行。
    public var preview: String {
        let p = profile
        if let s = p?.summary?.nonBlank { return s }
        if let d = p?.description.split(separator: "\n").first.map(String.init)?.nonBlank { return d }
        return systemPrompt.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// 复制为未落库草稿（名称加「 副本」）。
    public func draftCopy(sortOrder: Int) -> Persona {
        var p = self
        p.id = IDs.generic("persona"); p.name = name + " 副本"; p.isBuiltin = false; p.pinned = false
        p.sortOrder = sortOrder; p.createdAt = IDs.nowMs(); p.updatedAt = p.createdAt
        return p
    }
}
