import Foundation

/// 函数图像用的表达式引擎（对应安卓 MathExpression.kt）：词法 → 语法树 → 求值。
/// 支持 + - * / ^ ! 、隐式乘法（2x、3(x+1)、x y）、常量 pi/e、常用函数、sum/prod(k=1,n,expr)。
public indirect enum MathNode: Sendable {
    case num(Double)
    case variable(String)
    case unary(Character, MathNode)
    case binary(Character, MathNode, MathNode)
    case call(String, [MathNode])
    case factorial(MathNode)
    case series(isSum: Bool, variable: String, from: MathNode, to: MathNode, body: MathNode)
}

public struct MathExpression: Sendable {
    public let root: MathNode
    public let source: String

    public enum ParseError: Error, LocalizedError {
        case unexpected(String), unknownFunction(String), empty
        public var errorDescription: String? {
            switch self {
            case .unexpected(let s): return "无法解析：\(s)"
            case .unknownFunction(let f): return "未知函数：\(f)"
            case .empty: return "表达式为空"
            }
        }
    }

    static let functions: Set<String> = ["sin", "cos", "tan", "asin", "acos", "atan", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
                                         "sqrt", "cbrt", "abs", "exp", "ln", "log", "lg", "floor", "ceil", "round", "sign", "min", "max", "mod",
                                         "sec", "csc", "cot", "atan2", "pow"]

    public init(_ source: String) throws {
        self.source = source
        var p = Parser(tokens: try Self.tokenize(Self.normalize(source)))
        guard !p.tokens.isEmpty else { throw ParseError.empty }
        root = try p.parseExpression()
        if p.i < p.tokens.count { throw ParseError.unexpected(p.tokens[p.i].text) }
    }

    /// LaTeX 风格的常见写法转成普通记法。
    static func normalize(_ s: String) -> String {
        var t = s
        for (a, b) in [("\\cdot", "*"), ("\\times", "*"), ("\\pi", "pi"), ("π", "pi"), ("θ", "theta"), ("\\theta", "theta"),
                       ("\\left", ""), ("\\right", ""), ("**", "^"), ("·", "*"), ("×", "*"), ("÷", "/"), ("−", "-")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.replacingOccurrences(of: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "(($1)/($2))", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\sqrt\{([^{}]*)\}"#, with: "sqrt($1)", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\", with: "")
        t = t.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        return t
    }

    struct Token { enum Kind { case num, ident, op, lparen, rparen, comma }; let kind: Kind; let text: String; var value: Double = 0 }

    static func tokenize(_ s: String) throws -> [Token] {
        var out: [Token] = []
        let c = Array(s)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            if ch.isNumber || (ch == "." && i + 1 < c.count && c[i + 1].isNumber) {
                var j = i
                while j < c.count, c[j].isNumber || c[j] == "." { j += 1 }
                if j < c.count, c[j] == "e" || c[j] == "E", j + 1 < c.count, c[j + 1].isNumber || ((c[j + 1] == "-" || c[j + 1] == "+") && j + 2 < c.count && c[j + 2].isNumber) {
                    j += 2
                    while j < c.count, c[j].isNumber { j += 1 }
                }
                let text = String(c[i..<j])
                guard let v = Double(text) else { throw ParseError.unexpected(text) }
                out.append(Token(kind: .num, text: text, value: v)); i = j; continue
            }
            if ch.isLetter || ch == "_" {
                var j = i
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                out.append(Token(kind: .ident, text: String(c[i..<j]))); i = j; continue
            }
            switch ch {
            case "(", "[": out.append(Token(kind: .lparen, text: "("))
            case ")", "]": out.append(Token(kind: .rparen, text: ")"))
            case ",": out.append(Token(kind: .comma, text: ","))
            case "+", "-", "*", "/", "^", "!", "=", "%": out.append(Token(kind: .op, text: String(ch)))
            default: throw ParseError.unexpected(String(ch))
            }
            i += 1
        }
        return out
    }

    struct Parser {
        var tokens: [Token]
        var i = 0
        var peek: Token? { i < tokens.count ? tokens[i] : nil }

        mutating func parseExpression() throws -> MathNode {
            var lhs = try parseTerm()
            while let t = peek, t.kind == .op, t.text == "+" || t.text == "-" {
                i += 1
                lhs = .binary(Character(t.text), lhs, try parseTerm())
            }
            return lhs
        }

        mutating func parseTerm() throws -> MathNode {
            var lhs = try parseUnary()
            while let t = peek {
                if t.kind == .op, t.text == "*" || t.text == "/" || t.text == "%" {
                    i += 1
                    lhs = .binary(Character(t.text), lhs, try parseUnary())
                } else if t.kind == .num || t.kind == .ident || t.kind == .lparen {
                    lhs = .binary("*", lhs, try parsePower()) // 隐式乘法
                } else { break }
            }
            return lhs
        }

        mutating func parseUnary() throws -> MathNode {
            if let t = peek, t.kind == .op, t.text == "-" || t.text == "+" {
                i += 1
                let v = try parseUnary()
                return t.text == "-" ? .unary("-", v) : v
            }
            return try parsePower()
        }

        mutating func parsePower() throws -> MathNode {
            let base = try parsePostfix()
            if let t = peek, t.kind == .op, t.text == "^" {
                i += 1
                return .binary("^", base, try parseUnary()) // 右结合，允许 2^-x
            }
            return base
        }

        mutating func parsePostfix() throws -> MathNode {
            var v = try parseAtom()
            while let t = peek, t.kind == .op, t.text == "!" { i += 1; v = .factorial(v) }
            return v
        }

        mutating func parseAtom() throws -> MathNode {
            guard let t = peek else { throw ParseError.unexpected("结尾") }
            i += 1
            switch t.kind {
            case .num: return .num(t.value)
            case .lparen:
                let v = try parseExpression()
                guard peek?.kind == .rparen else { throw ParseError.unexpected("缺少 )") }
                i += 1
                return v
            case .ident:
                let name = t.text.lowercased()
                if peek?.kind == .lparen {
                    if name == "sum" || name == "prod" {
                        i += 1
                        guard let v = peek, v.kind == .ident else { throw ParseError.unexpected("sum 需要 k=起始") }
                        i += 1
                        guard peek?.text == "=" else { throw ParseError.unexpected("sum 需要 k=起始") }
                        i += 1
                        let from = try parseExpression()
                        guard peek?.kind == .comma else { throw ParseError.unexpected("sum 参数") }
                        i += 1
                        let to = try parseExpression()
                        guard peek?.kind == .comma else { throw ParseError.unexpected("sum 参数") }
                        i += 1
                        let body = try parseExpression()
                        guard peek?.kind == .rparen else { throw ParseError.unexpected("缺少 )") }
                        i += 1
                        return .series(isSum: name == "sum", variable: v.text, from: from, to: to, body: body)
                    }
                    guard MathExpression.functions.contains(name) else { throw ParseError.unknownFunction(t.text) }
                    i += 1
                    var args: [MathNode] = []
                    if peek?.kind != .rparen {
                        args.append(try parseExpression())
                        while peek?.kind == .comma { i += 1; args.append(try parseExpression()) }
                    }
                    guard peek?.kind == .rparen else { throw ParseError.unexpected("缺少 )") }
                    i += 1
                    return .call(name, args)
                }
                if MathExpression.functions.contains(name) {
                    // sin x 这类无括号写法：作用于紧随的幂
                    return .call(name, [try parsePower()])
                }
                return .variable(t.text)
            default:
                throw ParseError.unexpected(t.text)
            }
        }
    }

    public func evaluate(_ vars: [String: Double]) -> Double { Self.eval(root, vars) }

    public var variables: Set<String> {
        var out = Set<String>()
        func walk(_ n: MathNode, _ bound: Set<String>) {
            switch n {
            case .variable(let v): if !bound.contains(v) && v != "pi" && v != "e" { out.insert(v) }
            case .unary(_, let a), .factorial(let a): walk(a, bound)
            case .binary(_, let a, let b): walk(a, bound); walk(b, bound)
            case .call(_, let args): args.forEach { walk($0, bound) }
            case .series(_, let v, let f, let t, let b): walk(f, bound); walk(t, bound); walk(b, bound.union([v]))
            case .num: break
            }
        }
        walk(root, [])
        return out
    }

    static func eval(_ n: MathNode, _ vars: [String: Double]) -> Double {
        switch n {
        case .num(let v): return v
        case .variable(let name):
            if let v = vars[name] { return v }
            switch name.lowercased() { case "pi": return .pi; case "e": return M_E; case "tau": return 2 * .pi; default: return .nan }
        case .unary(_, let a): return -eval(a, vars)
        case .binary(let op, let a, let b):
            let x = eval(a, vars), y = eval(b, vars)
            switch op {
            case "+": return x + y
            case "-": return x - y
            case "*": return x * y
            case "/": return x / y
            case "%": return x.truncatingRemainder(dividingBy: y)
            case "^":
                if x < 0, y != y.rounded() {
                    // 负数开奇数次方：(-8)^(1/3) = -2
                    let inv = 1 / y
                    if inv == inv.rounded(), Int(inv) % 2 != 0 { return -pow(-x, y) }
                }
                return pow(x, y)
            default: return .nan
            }
        case .factorial(let a):
            let v = eval(a, vars)
            guard v >= 0, v == v.rounded(), v <= 170 else { return v >= 0 ? tgamma(v + 1) : .nan }
            return (1...max(1, Int(v))).reduce(1.0) { $0 * Double($1) }
        case .call(let f, let args):
            let a = args.map { eval($0, vars) }
            let x = a.first ?? .nan
            switch f {
            case "sin": return sin(x)
            case "cos": return cos(x)
            case "tan": return tan(x)
            case "sec": return 1 / cos(x)
            case "csc": return 1 / sin(x)
            case "cot": return 1 / tan(x)
            case "asin", "arcsin": return asin(x)
            case "acos", "arccos": return acos(x)
            case "atan", "arctan": return a.count == 2 ? atan2(a[0], a[1]) : atan(x)
            case "atan2": return a.count == 2 ? atan2(a[0], a[1]) : .nan
            case "sinh": return sinh(x)
            case "cosh": return cosh(x)
            case "tanh": return tanh(x)
            case "sqrt": return sqrt(x)
            case "cbrt": return cbrt(x)
            case "abs": return abs(x)
            case "exp": return exp(x)
            case "ln": return log(x)
            case "log": return a.count == 2 ? log(a[1]) / log(a[0]) : log10(x)
            case "lg": return log10(x)
            case "floor": return floor(x)
            case "ceil": return ceil(x)
            case "round": return x.rounded()
            case "sign": return x > 0 ? 1 : x < 0 ? -1 : 0
            case "min": return a.min() ?? .nan
            case "max": return a.max() ?? .nan
            case "mod": return a.count == 2 ? a[0] - a[1] * floor(a[0] / a[1]) : .nan
            case "pow": return a.count == 2 ? pow(a[0], a[1]) : .nan
            default: return .nan
            }
        case .series(let isSum, let v, let from, let to, let body):
            let lo = eval(from, vars), hi = eval(to, vars)
            guard lo.isFinite, hi.isFinite else { return .nan }
            let start = Int(lo.rounded()), end = Int(hi.rounded())
            guard end >= start else { return isSum ? 0 : 1 }
            guard end - start < 1000 else { return .nan }
            var acc = isSum ? 0.0 : 1.0
            var local = vars
            for k in start...end {
                local[v] = Double(k)
                let t = eval(body, local)
                acc = isSum ? acc + t : acc * t
            }
            return acc
        }
    }
}
