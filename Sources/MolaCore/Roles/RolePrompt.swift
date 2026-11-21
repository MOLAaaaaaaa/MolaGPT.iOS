import Foundation

// 世界书匹配（安卓 LorebookMatcher）与角色提示词组装（RolePromptBuilder / applyRolePlan）。

public struct LoreHit: Sendable, Hashable {
    public var entry: LoreEntry
    public var bookId: String
}

public enum LorebookMatcher {
    public static func estimateTokens(_ s: String) -> Int {
        Int(s.unicodeScalars.reduce(0.0) { $0 + ($1.isASCII ? 0.25 : 1.0) }.rounded(.up))
    }

    /// `draw(key)` = SHA-256(generationId:key) 前 4 字节小端 / 2^32（同一轮生成可复现）。
    public static func draw(_ generationId: String, _ key: String) -> Double {
        let h = SHA256.hash("\(generationId):\(key)")
        let v = UInt32(h[0]) | UInt32(h[1]) << 8 | UInt32(h[2]) << 16 | UInt32(h[3]) << 24
        return Double(v) / 4_294_967_296
    }

    /// 解析内容开头的 `@@` 控制行。返回 nil = 含不支持的控制项（条目出局）。
    static func controls(_ content: String) -> (content: String, activate: Bool, dontActivate: Bool, depth: Int?, role: String?, scanDepth: Int?, position: LorePosition?)? {
        var lines = content.components(separatedBy: "\n")
        var activate = false, dont = false, depth: Int?, role: String?, scan: Int?, pos: LorePosition?
        while let first = lines.first, first.hasPrefix("@@") {
            let parts = first.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
            switch parts.first ?? "" {
            case "activate": activate = true
            case "dont_activate": dont = true
            case "depth": depth = parts.count > 1 ? Int(parts[1]) : nil
            case "role": role = parts.count > 1 ? parts[1] : nil
            case "scan_depth": scan = parts.count > 1 ? Int(parts[1]) : nil
            case "position": pos = parts.count > 1 && parts[1] == "before_desc" ? .beforeCharacter : .afterCharacter
            default: return nil
            }
            lines.removeFirst()
        }
        return (lines.joined(separator: "\n"), activate, dont, depth, role, scan, pos)
    }

    static func matches(_ key: String, in text: String, entry: LoreEntry) -> Bool {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return false }
        if k.hasPrefix("/"), let close = k.lastIndex(of: "/"), close > k.startIndex {
            let pattern = String(k[k.index(after: k.startIndex)..<close])
            let flags = k[k.index(after: close)...]
            var opts: NSRegularExpression.Options = []
            for f in flags {
                switch f { case "i": opts.insert(.caseInsensitive); case "m": opts.insert(.anchorsMatchLines); case "s": opts.insert(.dotMatchesLineSeparators); case "g", "u": break; default: return false }
            }
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        if entry.matchWholeWords {
            let esc = NSRegularExpression.escapedPattern(for: k)
            let opts: NSRegularExpression.Options = entry.caseSensitive ? [] : [.caseInsensitive]
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])\(esc)(?![\\p{L}\\p{N}_])", options: opts) else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return entry.caseSensitive ? text.contains(k) : text.lowercased().contains(k.lowercased())
    }

    /// - Parameters:
    ///   - messages: 扫描文本（历史里非 system 的消息正文，按时间顺序）。
    ///   - sillyTavern: SillyTavern 档（整轮预算、constant 语义）；否则规范档（每本书预算）。
    public static func evaluate(books: [Lorebook], messages: [String], interpolate: (String) -> String,
                                generationId: String, sillyTavern: Bool, globalBudget: Int) -> [LoreHit] {
        var adopted: [LoreHit] = []
        var adoptedIds = Set<String>()
        var usedGroups = Set<String>()
        var recursionText = ""
        var tokens = 0
        var bookTokens: [String: Int] = [:]
        var overflow = false
        var round = 0
        let enabledBooks = books.filter(\.enabled)

        while round < 8 {
            var candidates: [(LoreHit, String)] = []
            var waiting: [Int] = []
            for book in enabledBooks {
                for entry in book.entries where entry.enabled && !adoptedIds.contains(entry.id) {
                    guard let ctl = controls(entry.content), !ctl.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !ctl.dontActivate else { continue }
                    if messages.count < entry.delay { continue }
                    if round < entry.delayUntilRecursion { waiting.append(entry.delayUntilRecursion); continue }
                    if round > 0 && (!book.recursiveScanning || entry.excludeRecursion) { continue }
                    let depth = ctl.scanDepth ?? entry.scanDepth ?? book.scanDepth
                    let scope = entry.scanScope == .inherit ? (depth == 0 ? LoreScanScope.none : depth >= Int.max / 2 ? .all : .recent) : entry.scanScope
                    var text: String
                    switch scope {
                    case .none: text = ""
                    case .all: text = messages.joined(separator: "\n")
                    default: text = messages.suffix(max(depth, 0)).joined(separator: "\n")
                    }
                    if round > 0 { text += "\n" + recursionText }
                    var triggered = ctl.activate || (entry.constant && (sillyTavern || !entry.useRegex))
                    if !triggered {
                        let primary = entry.keys.map(interpolate).contains { matches($0, in: text, entry: entry) }
                        if primary {
                            triggered = true
                            if entry.selective && !entry.secondaryKeys.isEmpty {
                                let hit = entry.secondaryKeys.map(interpolate).filter { matches($0, in: text, entry: entry) }.count
                                let total = entry.secondaryKeys.count
                                switch entry.selectiveLogic {
                                case .andAny: triggered = hit > 0
                                case .andAll: triggered = hit == total
                                case .notAny: triggered = hit == 0
                                case .notAll: triggered = hit < total
                                }
                            }
                        }
                    }
                    guard triggered else { continue }
                    var e = entry
                    e.content = ctl.content
                    if let d = ctl.depth { e.depth = d; e.position = .atDepth }
                    if let r = ctl.role { e.role = r }
                    if let p = ctl.position { e.position = p }
                    candidates.append((LoreHit(entry: e, bookId: book.id), book.id))
                }
            }
            // 排序：SillyTavern 档按 order 降序，规范档按 selectionPriority 降序
            candidates.sort { a, b in
                sillyTavern ? a.0.entry.order > b.0.entry.order : a.0.entry.selectionPriority > b.0.entry.selectionPriority
            }
            // 分组：每组只留一条（override 取 order 最大，否则按权重抽签）
            var grouped: [String: [(LoreHit, String)]] = [:]
            var result: [(LoreHit, String)] = []
            for c in candidates {
                if let g = c.0.entry.group { if !usedGroups.contains(g) { grouped[g, default: []].append(c) } } else { result.append(c) }
            }
            for (g, list) in grouped {
                let pick: (LoreHit, String)
                if let o = list.filter({ $0.0.entry.groupOverride }).max(by: { $0.0.entry.order < $1.0.entry.order }) { pick = o }
                else {
                    let total = list.reduce(0) { $0 + max($1.0.entry.groupWeight, 0) }
                    var r = draw(generationId, "group:\(g):\(round)") * Double(max(total, 1))
                    pick = list.first { r -= Double(max($0.0.entry.groupWeight, 0)); return r < 0 } ?? list[0]
                }
                usedGroups.insert(g)
                result.append(pick)
            }
            var added: [LoreHit] = []
            for (hit, bookId) in result {
                let e = hit.entry
                if e.useProbability && e.probability < 100 {
                    if e.probability <= 0 || draw(generationId, e.id) * 100 >= Double(e.probability) { continue }
                }
                let t = estimateTokens(e.content)
                if sillyTavern {
                    if overflow && !e.ignoreBudget { continue }
                    if tokens + t >= globalBudget && !e.ignoreBudget { overflow = true; continue }
                } else if let book = enabledBooks.first(where: { $0.id == bookId }) {
                    if (bookTokens[bookId] ?? 0) + t > book.tokenBudget && !e.ignoreBudget { continue }
                    bookTokens[bookId, default: 0] += t
                }
                tokens += t
                adopted.append(hit); adoptedIds.insert(e.id); added.append(hit)
            }
            let recursive = added.filter { !$0.entry.preventRecursion }
            if recursive.isEmpty {
                guard let next = waiting.filter({ $0 > round }).min() else { break }
                round = next
                continue
            }
            recursionText += "\n" + recursive.map(\.entry.content).joined(separator: "\n")
            round += 1
        }
        return adopted.sorted { $0.entry.order < $1.entry.order }
    }
}

/// 一轮的角色计划：system、示例对话、按深度插入。
public struct RolePlan: Sendable {
    public struct Insertion: Sendable { public var depth: Int; public var role: Role; public var order: Int; public var content: String }
    public var system: String
    public var examples: [WireMessage]
    public var insertions: [Insertion]
}

public enum RolePromptBuilder {
    /// 宏替换：`{{char}}` `{{user}}` `{{date}}` 等；未知宏原样保留。
    public static func macros(_ s: String, values: [String: String]) -> String {
        guard s.contains("{{"), let re = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_]\w*)\s*\}\}"#) else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            out += values[key] ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        return out + ns.substring(from: cursor)
    }

    public static func build(persona: Persona, profile: PersonaProfile, conversationPrompt: String?, appendMode: Bool,
                             userName: String, model: String, provider: String, history: [String], sharedBooks: [Lorebook],
                             generationId: String, now: Date = Date()) -> RolePlan {
        let charName = profile.nickname?.nonBlank ?? persona.name
        let user = (profile.useProfileName ? userName.nonBlank : profile.userName?.nonBlank) ?? profile.userName?.nonBlank ?? userName.nonBlank ?? "用户"
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN"); df.dateFormat = "yyyy年M月d日 EEEE"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "zh_CN"); tf.dateFormat = "HH:mm"
        var values: [String: String] = [
            "date": df.string(from: now), "time": tf.string(from: now), "datetime": df.string(from: now) + " " + tf.string(from: now),
            "model": model, "model_id": model, "provider": provider, "user": user, "username": user, "char": charName, "character": charName,
            "original": persona.systemPrompt, "description": profile.description, "personality": profile.personality,
            "scenario": profile.scenario, "persona": profile.userDescription, "charprompt": persona.systemPrompt,
            "charjailbreak": profile.postHistoryInstructions,
        ]
        let expand: (String) -> String = { macros($0, values: values) }

        var books = profile.lorebooks
        for b in sharedBooks where profile.sharedLorebookIds.contains(b.id) && !books.contains(where: { $0.id == b.id }) { books.append(b) }
        let hits = LorebookMatcher.evaluate(books: books, messages: history, interpolate: expand, generationId: generationId,
                                            sillyTavern: profile.compatibility == .sillytavern, globalBudget: profile.loreBudget)
        func lore(_ p: LorePosition) -> [String] { hits.filter { $0.entry.position == p }.map { expand($0.entry.content) } }
        for h in hits where h.entry.position == .outlet { if let n = h.entry.outletName?.lowercased() { values[n] = expand(h.entry.content) } }

        var main = persona.systemPrompt
        if let c = conversationPrompt?.nonBlank { main = appendMode ? main + "\n\n" + c : c }
        var parts: [String] = []
        parts.append(expand(main))
        parts += lore(.beforeCharacter)
        parts.append("角色：\n\(charName)")
        if let d = profile.description.nonBlank { parts.append("角色资料：\n" + expand(d)) }
        if let p = profile.personality.nonBlank { parts.append("性格与表达：\n" + expand(p)) }
        if let s = profile.scenario.nonBlank { parts.append("场景：\n" + expand(s)) }
        if let u = profile.userDescription.nonBlank { parts.append("用户身份：\n" + expand(u)) }
        parts += lore(.afterCharacter)
        let system = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")

        // 示例对话：BEFORE_EXAMPLES + mes_example + AFTER_EXAMPLES
        var examples: [WireMessage] = []
        for t in lore(.beforeExamples) { examples.append(.text(.user, t)) }
        examples += parseExamples(expand(profile.exampleDialogue), charName: charName, personaName: persona.name, userName: user)
        for t in lore(.afterExamples) { examples.append(.text(.user, t)) }
        while examples.first?.role == .assistant { examples.removeFirst() }

        var ins: [RolePlan.Insertion] = []
        func role(_ s: String, depth: Int) -> Role {
            switch s.lowercased() { case "user": return .user; case "assistant": return depth == 0 ? .system : .assistant; default: return .system }
        }
        for h in hits where h.entry.position == .atDepth {
            ins.append(.init(depth: h.entry.depth, role: role(h.entry.role, depth: h.entry.depth), order: h.entry.order, content: expand(h.entry.content)))
        }
        let noteParts = lore(.beforeNote) + [expand(profile.characterNote)].filter { !$0.isEmpty } + lore(.afterNote)
        if !noteParts.isEmpty {
            let note = noteParts.joined(separator: "\n")
            ins.append(.init(depth: profile.characterNoteDepth, role: role(profile.characterNoteRole, depth: profile.characterNoteDepth), order: 1, content: note))
        }
        if let post = profile.postHistoryInstructions.nonBlank { ins.append(.init(depth: 0, role: .system, order: .max, content: expand(post))) }
        ins.sort { $0.depth != $1.depth ? $0.depth > $1.depth : $0.order < $1.order }
        return RolePlan(system: system, examples: examples, insertions: ins)
    }

    /// `<START>` 分块；行首「名字:」切换说话人，不认识的名字续行。
    public static func parseExamples(_ text: String, charName: String, personaName: String, userName: String) -> [WireMessage] {
        guard text.nonBlank != nil else { return [] }
        let blocks = text.components(separatedBy: "<START>").flatMap { $0.components(separatedBy: "<start>") }
        let assistantNames = Set(["assistant", "char", "{{char}}", charName.lowercased(), personaName.lowercased()])
        let userNames = Set(["user", "{{user}}", userName.lowercased(), "用户"])
        var out: [WireMessage] = []
        for block in blocks {
            var current: (Role, String)?
            for line in block.components(separatedBy: "\n") {
                if let idx = line.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                    let name = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                    let role: Role? = assistantNames.contains(name) ? .assistant : userNames.contains(name) ? .user : nil
                    if let role {
                        if let c = current, c.1.nonBlank != nil { out.append(.text(c.0, c.1.trimmingCharacters(in: .whitespacesAndNewlines))) }
                        current = (role, String(line[line.index(after: idx)...]))
                        continue
                    }
                }
                if current == nil, line.nonBlank != nil { current = (.system, line) } else if current != nil { current!.1 += "\n" + line }
            }
            if let c = current, c.1.nonBlank != nil { out.append(.text(c.0 == .system ? .user : c.0, c.1.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        return out
    }

    /// 深度 d 插在「距末尾第 d 条之前」；d > count 放最前。注入的 system 以 user 身份发出（保持位置）。
    public static func apply(_ plan: RolePlan, to history: [WireMessage]) -> [WireMessage] {
        var out = history
        for ins in plan.insertions {
            let pos = max(0, out.count - ins.depth)
            let role: Role = ins.role == .system ? .user : ins.role
            let text = ins.role == .system ? "[系统提示]\n\(ins.content)" : ins.content
            out.insert(.text(role, text), at: min(pos, out.count))
        }
        // 合并相邻同角色（插入可能造成连续 user）
        var merged: [WireMessage] = []
        for m in out {
            if var last = merged.last, last.role == m.role, last.native == nil, m.native == nil {
                last.parts.append(contentsOf: m.parts); merged[merged.count - 1] = last
            } else { merged.append(m) }
        }
        return plan.examples + merged
    }

    /// 开场白：[greeting] + alternateGreetings，过滤空白并展开宏。
    public static func greetings(_ profile: PersonaProfile, persona: Persona, userName: String) -> [String] {
        let charName = profile.nickname?.nonBlank ?? persona.name
        let values = ["char": charName, "character": charName, "user": userName, "username": userName]
        return ([profile.greeting] + profile.alternateGreetings).filter { $0.nonBlank != nil }.map { macros($0, values: values) }
    }
}
