import Foundation

/// 轻量代码高亮：按语言族给出关键字 / 字符串 / 注释 / 数字 / 类型 / 函数调用的区间。
/// 不追求语法完整，只求常见语言下观感接近编辑器；UI 层按 token 着色。
public enum CodeTokenKind: Sendable, Equatable {
    case keyword, string, comment, number, type, function, attribute
}

public struct CodeToken: Sendable, Equatable {
    public let kind: CodeTokenKind
    /// 以 UTF-16 偏移表示，便于 NSAttributedString / AttributedString 使用。
    public let location: Int
    public let length: Int
}

public enum CodeHighlighter {
    struct Lang {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: (String, String)?
        var stringDelims: [Character]
        var hashComment: Bool { lineComments.contains("#") }
    }

    private static let cFamily: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "struct", "union", "enum", "typedef", "const", "static", "extern", "volatile", "sizeof", "void", "int", "char", "float", "double", "long", "short", "unsigned", "signed", "bool", "true", "false", "NULL", "nullptr", "class", "public", "private", "protected", "virtual", "override", "template", "typename", "namespace", "using", "new", "delete", "this", "throw", "try", "catch", "auto", "inline", "constexpr", "include", "define"]
    private static let jsKeys: Set<String> = ["var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "this", "class", "extends", "super", "import", "export", "from", "as", "async", "await", "yield", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "true", "false", "null", "undefined", "void", "delete", "static", "get", "set", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "declare", "namespace", "keyof", "any", "number", "string", "boolean", "never", "unknown"]
    private static let pyKeys: Set<String> = ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "None", "True", "False", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "pass", "break", "continue", "global", "nonlocal", "async", "await", "assert", "del", "self", "match", "case"]
    private static let swiftKeys: Set<String> = ["func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "repeat", "switch", "case", "default", "break", "continue", "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "fileprivate", "internal", "open", "static", "final", "override", "init", "deinit", "self", "Self", "super", "true", "false", "nil", "throws", "throw", "try", "catch", "do", "async", "await", "actor", "some", "any", "where", "typealias", "associatedtype", "inout", "mutating", "lazy", "weak", "unowned", "defer", "is", "as", "nonisolated", "sending", "consuming"]
    private static let kotlinKeys: Set<String> = ["fun", "val", "var", "if", "else", "when", "for", "while", "do", "return", "class", "object", "interface", "data", "sealed", "enum", "open", "abstract", "override", "private", "public", "internal", "protected", "companion", "import", "package", "is", "as", "in", "out", "null", "true", "false", "this", "super", "try", "catch", "finally", "throw", "suspend", "inline", "lateinit", "by", "lazy", "typealias", "init", "constructor", "it"]
    private static let javaKeys: Set<String> = ["public", "private", "protected", "class", "interface", "extends", "implements", "static", "final", "void", "int", "long", "double", "float", "boolean", "char", "byte", "short", "new", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "try", "catch", "finally", "throw", "throws", "import", "package", "this", "super", "null", "true", "false", "abstract", "synchronized", "var", "record", "enum", "instanceof"]
    private static let goKeys: Set<String> = ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "select", "nil", "true", "false", "string", "int", "int64", "float64", "bool", "error", "byte", "rune", "make", "new", "len", "append"]
    private static let rustKeys: Set<String> = ["fn", "let", "mut", "const", "static", "if", "else", "match", "for", "while", "loop", "in", "return", "break", "continue", "struct", "enum", "trait", "impl", "pub", "use", "mod", "crate", "self", "Self", "super", "where", "as", "ref", "move", "async", "await", "dyn", "unsafe", "true", "false", "type", "Some", "None", "Ok", "Err"]
    private static let shellKeys: Set<String> = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "local", "export", "echo", "exit", "source", "cd", "set", "unset", "readonly", "shift", "true", "false", "sudo"]
    private static let sqlKeys: Set<String> = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "index", "primary", "key", "foreign", "references", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "is", "in", "like", "distinct", "count", "sum", "avg", "min", "max", "union", "all", "case", "when", "then", "else", "end", "default", "integer", "text", "real", "blob", "varchar", "int", "exists", "if", "begin", "commit", "pragma", "asc", "desc"]

    static func lang(_ name: String?) -> Lang? {
        let n = (name ?? "").lowercased()
        switch n {
        case "c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "cs", "csharp", "c#", "dart", "php":
            return Lang(keywords: cFamily.union(jsKeys.intersection(["var", "async", "await", "import", "extends", "implements", "function", "static", "readonly", "interface"])), lineComments: n == "php" ? ["//", "#"] : ["//"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'"])
        case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs", "vue", "svelte":
            return Lang(keywords: jsKeys, lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'", "`"])
        case "py", "python", "python3":
            return Lang(keywords: pyKeys, lineComments: ["#"], blockComment: nil, stringDelims: ["\"", "'"])
        case "swift":
            return Lang(keywords: swiftKeys, lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\""])
        case "kt", "kotlin", "kts", "gradle":
            return Lang(keywords: kotlinKeys, lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'"])
        case "java", "scala", "groovy":
            return Lang(keywords: javaKeys, lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'"])
        case "go", "golang":
            return Lang(keywords: goKeys, lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'", "`"])
        case "rs", "rust":
            return Lang(keywords: rustKeys, lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\""])
        case "sh", "bash", "zsh", "shell", "fish", "console", "ps1", "powershell":
            return Lang(keywords: shellKeys, lineComments: ["#"], blockComment: nil, stringDelims: ["\"", "'"])
        case "rb", "ruby", "perl", "r", "yaml", "yml", "toml", "ini", "conf", "dockerfile", "makefile", "cmake", "nix":
            return Lang(keywords: pyKeys.union(shellKeys).union(["end", "begin", "module", "require", "puts", "nil"]), lineComments: ["#"], blockComment: nil, stringDelims: ["\"", "'"])
        case "sql", "sqlite", "mysql", "postgresql", "psql":
            return Lang(keywords: sqlKeys, lineComments: ["--"], blockComment: ("/*", "*/"), stringDelims: ["'", "\""])
        case "json", "jsonc", "json5":
            return Lang(keywords: ["true", "false", "null"], lineComments: n == "json" ? [] : ["//"], blockComment: nil, stringDelims: ["\""])
        case "lua":
            return Lang(keywords: ["local", "function", "end", "if", "then", "else", "elseif", "for", "in", "do", "while", "repeat", "until", "return", "nil", "true", "false", "and", "or", "not", "break"], lineComments: ["--"], blockComment: nil, stringDelims: ["\"", "'"])
        case "html", "xml", "svg", "css", "scss", "less", "markdown", "md", "text", "txt", "plaintext", "latex", "tex":
            return nil
        default:
            // 未知语言：用一个通用 C 风格词表兜底
            return n.isEmpty ? nil : Lang(keywords: cFamily.union(jsKeys).union(pyKeys), lineComments: ["//", "#"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'"])
        }
    }

    public static func tokenize(_ code: String, language: String?) -> [CodeToken] {
        guard let lang = lang(language), code.utf16.count <= 60_000 else { return [] }
        let isSQL = lang.keywords.contains("select")
        let u = Array(code.utf16)
        var tokens: [CodeToken] = []
        var i = 0
        func starts(_ s: String, at k: Int) -> Bool {
            let p = Array(s.utf16)
            guard k + p.count <= u.count else { return false }
            for (o, ch) in p.enumerated() where u[k + o] != ch { return false }
            return true
        }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

        while i < u.count {
            let c = u[i]
            // 注释
            if let lc = lang.lineComments.first(where: { starts($0, at: i) }),
               !(lc == "#" && i + 1 < u.count && u[i + 1] == 33 /* #! 仍算注释 */ && false) {
                var j = i
                while j < u.count, u[j] != 10 { j += 1 }
                tokens.append(.init(kind: .comment, location: i, length: j - i)); i = j; continue
            }
            if let (open, close) = lang.blockComment, starts(open, at: i) {
                var j = i + open.utf16.count
                while j < u.count, !starts(close, at: j) { j += 1 }
                j = min(u.count, j + close.utf16.count)
                tokens.append(.init(kind: .comment, location: i, length: j - i)); i = j; continue
            }
            // 字符串（Python 三引号也覆盖）
            if let d = lang.stringDelims.first(where: { $0.utf16.first == c }) {
                let q = d.utf16.first!
                let triple = i + 2 < u.count && u[i + 1] == q && u[i + 2] == q
                var j = i + (triple ? 3 : 1)
                while j < u.count {
                    if u[j] == 92 { j += 2; continue } // 反斜杠转义
                    if triple {
                        if u[j] == q, j + 2 < u.count, u[j + 1] == q, u[j + 2] == q { j += 3; break }
                    } else {
                        if u[j] == q { j += 1; break }
                        if u[j] == 10 && q != 96 { break }
                    }
                    j += 1
                }
                j = min(j, u.count)
                tokens.append(.init(kind: .string, location: i, length: j - i)); i = j; continue
            }
            // 数字
            if isDigit(c) && (i == 0 || !isIdent(u[i - 1])) {
                var j = i + 1
                while j < u.count, isIdent(u[j]) || u[j] == 46 { j += 1 }
                tokens.append(.init(kind: .number, location: i, length: j - i)); i = j; continue
            }
            // 注解 / 装饰器
            if c == 64, i + 1 < u.count, isIdentStart(u[i + 1]) {
                var j = i + 1
                while j < u.count, isIdent(u[j]) { j += 1 }
                tokens.append(.init(kind: .attribute, location: i, length: j - i)); i = j; continue
            }
            // 标识符
            if isIdentStart(c) {
                var j = i + 1
                while j < u.count, isIdent(u[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(u[i..<j]), count: j - i)
                let key = isSQL ? word.lowercased() : word
                if lang.keywords.contains(key) {
                    tokens.append(.init(kind: .keyword, location: i, length: j - i))
                } else if j < u.count, u[j] == 40 { // (
                    tokens.append(.init(kind: .function, location: i, length: j - i))
                } else if let f = word.utf16.first, f >= 65 && f <= 90, word.count > 1 {
                    tokens.append(.init(kind: .type, location: i, length: j - i))
                }
                i = j; continue
            }
            i += 1
        }
        return tokens
    }
}
