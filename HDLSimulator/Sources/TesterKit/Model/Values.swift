import Foundation

// MARK: - Constant expressions

/// Evaluates Verilog constant expressions such as `WIDTH-1` or `$clog2(DEPTH)`.
struct ExprEval {
    var env: [String: Int]

    func eval(_ text: String) -> Int? {
        let toks = VerilogLexer.lex(text)
        guard !toks.isEmpty else { return nil }
        var p = Parser(toks: toks, env: env)
        guard let v = p.expr(0), p.i == toks.count else { return nil }
        return v
    }

    private struct Parser {
        let toks: [Tok]
        let env: [String: Int]
        var i = 0

        static let binary: [String: Int] = [
            "||": 2, "&&": 3, "|": 4, "^": 5, "~^": 5, "^~": 5, "&": 6,
            "==": 7, "!=": 7, "===": 7, "!==": 7,
            "<": 8, "<=": 8, ">": 8, ">=": 8,
            "<<": 9, ">>": 9, "<<<": 9, ">>>": 9,
            "+": 10, "-": 10, "*": 11, "/": 11, "%": 11, "**": 12,
        ]

        var peek: String { i < toks.count ? toks[i].text : "" }

        mutating func expr(_ minPrec: Int) -> Int? {
            guard var lhs = unary() else { return nil }
            while true {
                let op = peek
                if op == "?" && minPrec <= 1 {
                    i += 1
                    guard let a = expr(0), peek == ":" else { return nil }
                    i += 1
                    guard let b = expr(1) else { return nil }
                    lhs = lhs != 0 ? a : b
                    continue
                }
                guard let prec = Self.binary[op], prec >= minPrec else { break }
                i += 1
                let nextMin = op == "**" ? prec : prec + 1
                guard let rhs = expr(nextMin) else { return nil }
                guard let v = Self.apply(op, lhs, rhs) else { return nil }
                lhs = v
            }
            return lhs
        }

        static func apply(_ op: String, _ a: Int, _ b: Int) -> Int? {
            switch op {
            case "+": return a &+ b
            case "-": return a &- b
            case "*": return a &* b
            case "/": return b == 0 ? nil : a / b
            case "%": return b == 0 ? nil : a % b
            case "**":
                guard b >= 0, b < 63 else { return nil }
                var r = 1
                for _ in 0..<b { r = r &* a }
                return r
            case "<<", "<<<": return b >= 0 && b < 63 ? a << b : nil
            case ">>", ">>>": return b >= 0 && b < 63 ? a >> b : nil
            case "&": return a & b
            case "|": return a | b
            case "^": return a ^ b
            case "~^", "^~": return ~(a ^ b)
            case "==", "===": return a == b ? 1 : 0
            case "!=", "!==": return a != b ? 1 : 0
            case "<": return a < b ? 1 : 0
            case "<=": return a <= b ? 1 : 0
            case ">": return a > b ? 1 : 0
            case ">=": return a >= b ? 1 : 0
            case "&&": return (a != 0 && b != 0) ? 1 : 0
            case "||": return (a != 0 || b != 0) ? 1 : 0
            default: return nil
            }
        }

        mutating func unary() -> Int? {
            switch peek {
            case "-": i += 1; return unary().map { -$0 }
            case "+": i += 1; return unary()
            case "!": i += 1; return unary().map { $0 == 0 ? 1 : 0 }
            case "~": i += 1; return unary().map { ~$0 }
            default: return primary()
            }
        }

        mutating func primary() -> Int? {
            guard i < toks.count else { return nil }
            let t = toks[i]
            switch t.kind {
            case .number:
                i += 1
                return LogicLiteral.parse(t.text)?.intValue
            case .ident:
                i += 1
                return env[t.text]
            case .system:
                i += 1
                guard peek == "(" else { return nil }
                i += 1
                guard let a = expr(0), peek == ")" else { return nil }
                i += 1
                switch t.text {
                case "$clog2":
                    if a <= 1 { return 0 }
                    var r = 0
                    var v = a - 1
                    while v > 0 { r += 1; v >>= 1 }
                    return r
                case "$signed", "$unsigned": return a
                default: return nil
                }
            case .symbol where t.text == "(":
                i += 1
                guard let v = expr(0), peek == ")" else { return nil }
                i += 1
                return v
            default:
                return nil
            }
        }
    }
}

// MARK: - Value literals

/// One bit of a four-state value.
enum Bit: UInt8 {
    case zero, one, x, z

    var char: Character {
        switch self {
        case .zero: return "0"
        case .one: return "1"
        case .x: return "x"
        case .z: return "z"
        }
    }
}

/// A value typed by the user: `0`, `1`, `255`, `-3`, `8'hA5`, `'b1010`, `0x3F`, `0b101`, `x`, `z`.
struct LogicLiteral: Equatable {
    var base: Character        // b o d h
    var digits: String         // lowercase, no underscores
    var negative = false
    var size: Int?

    static func parse(_ raw: String) -> LogicLiteral? {
        var s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        s = s.replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        let lower = s.lowercased()
        if lower == "x" || lower == "z" || lower == "?" {
            return LogicLiteral(base: "b", digits: lower == "?" ? "z" : lower, negative: false)
        }
        if let q = lower.firstIndex(of: "'") {
            let sizeText = lower[..<q]
            var rest = lower[lower.index(after: q)...]
            if rest.first == "s" { rest = rest.dropFirst() }
            guard let b = rest.first, "bodh".contains(b) else { return nil }
            let digits = String(rest.dropFirst()).replacingOccurrences(of: "?", with: "z")
            guard !digits.isEmpty, Self.valid(digits, base: b) else { return nil }
            var size: Int?
            if !sizeText.isEmpty {
                guard let n = Int(sizeText), n > 0 else { return nil }
                size = n
            }
            return LogicLiteral(base: b, digits: digits, negative: negative, size: size)
        }
        if lower.hasPrefix("0x"), lower.count > 2 {
            let d = String(lower.dropFirst(2))
            return valid(d, base: "h") ? LogicLiteral(base: "h", digits: d, negative: negative) : nil
        }
        if lower.hasPrefix("0b"), lower.count > 2 {
            let d = String(lower.dropFirst(2))
            return valid(d, base: "b") ? LogicLiteral(base: "b", digits: d, negative: negative) : nil
        }
        if lower.hasPrefix("0o"), lower.count > 2 {
            let d = String(lower.dropFirst(2))
            return valid(d, base: "o") ? LogicLiteral(base: "o", digits: d, negative: negative) : nil
        }
        if lower.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return LogicLiteral(base: "d", digits: lower, negative: negative)
        }
        return nil
    }

    private static func valid(_ d: String, base: Character) -> Bool {
        let allowed: String
        switch base {
        case "b": allowed = "01xz"
        case "o": allowed = "01234567xz"
        case "d": allowed = "0123456789"
        default: allowed = "0123456789abcdefxz"
        }
        if base == "d" && (d == "x" || d == "z") { return true }
        return d.allSatisfy { allowed.contains($0) }
    }

    var intValue: Int? {
        guard !digits.contains("x"), !digits.contains("z") else { return nil }
        let radix: Int
        switch base {
        case "b": radix = 2
        case "o": radix = 8
        case "h": radix = 16
        default: radix = 10
        }
        guard let v = Int(digits, radix: radix) else { return nil }
        return negative ? -v : v
    }

    /// Verilog source for this value on a signal `width` bits wide (nil = unknown width).
    func verilog(width: Int?) -> String {
        let w = width.map(String.init) ?? ""
        var base = self.base
        var digits = self.digits
        if width == 1, base == "d", let v = Int(digits), v <= 1 {
            base = "b"
            digits = String(v)
        }
        let body = "\(w)'\(base)\(digits)"
        return negative ? "-\(body)" : body
    }

    /// Bits, most significant first, extended or truncated to `width`.
    func bits(width: Int) -> [Bit]? {
        guard width > 0 else { return nil }
        var bits: [Bit] = []
        switch base {
        case "b", "o", "h":
            let per = base == "b" ? 1 : (base == "o" ? 3 : 4)
            for ch in digits {
                if ch == "x" || ch == "z" {
                    bits += Array(repeating: ch == "x" ? .x : .z, count: per)
                } else {
                    guard let v = Int(String(ch), radix: 16) else { return nil }
                    for k in stride(from: per - 1, through: 0, by: -1) {
                        bits.append((v >> k) & 1 == 1 ? .one : .zero)
                    }
                }
            }
        default:
            if digits == "x" || digits == "z" {
                return Array(repeating: digits == "x" ? .x : .z, count: width)
            }
            guard let v = UInt64(digits) else { return nil }
            bits = (0..<64).reversed().map { (v >> UInt64($0)) & 1 == 1 ? .one : .zero }
        }
        // Extend: x / z fill to the left, otherwise zeros.
        if bits.count < width {
            let fill: Bit = (bits.first == .x || bits.first == .z) ? bits.first! : .zero
            bits = Array(repeating: fill, count: width - bits.count) + bits
        } else if bits.count > width {
            bits = Array(bits.suffix(width))
        }
        if negative {
            bits = Self.negate(bits)
        }
        return bits
    }

    static func negate(_ b: [Bit]) -> [Bit] {
        if b.contains(.x) || b.contains(.z) { return Array(repeating: .x, count: b.count) }
        var out = b.map { $0 == .one ? Bit.zero : Bit.one }
        var i = out.count - 1
        while i >= 0 {
            if out[i] == .zero { out[i] = .one; break }
            out[i] = .zero
            i -= 1
        }
        return out
    }
}

enum BitsFormat {
    /// Hex text for a bus value, with x / z nibbles.
    static func hex(_ bits: [Bit]) -> String {
        if bits.allSatisfy({ $0 == .x }) { return "x" }
        if bits.allSatisfy({ $0 == .z }) { return "z" }
        var out = ""
        var end = bits.count
        while end > 0 {
            let start = max(0, end - 4)
            let nib = bits[start..<end]
            if nib.contains(.x) {
                out = "x" + out
            } else if nib.contains(.z) {
                out = "z" + out
            } else {
                var v = 0
                for b in nib { v = v * 2 + (b == .one ? 1 : 0) }
                out = String(v, radix: 16, uppercase: true) + out
            }
            end = start
        }
        return out
    }

    static func uint(_ bits: [Bit]) -> UInt64? {
        guard bits.count <= 64, !bits.contains(.x), !bits.contains(.z) else { return nil }
        var v: UInt64 = 0
        for b in bits { v = (v << 1) | (b == .one ? 1 : 0) }
        return v
    }

    static func bits(_ v: UInt64, width: Int) -> [Bit] {
        (0..<width).reversed().map { $0 < 64 && (v >> UInt64($0)) & 1 == 1 ? .one : .zero }
    }
}

// MARK: - Time

enum TimeUnit: String, Codable, CaseIterable, Identifiable {
    case fs, ps, ns, us, ms, s
    var id: String { rawValue }
    var exponent: Int {
        switch self {
        case .fs: return -15
        case .ps: return -12
        case .ns: return -9
        case .us: return -6
        case .ms: return -3
        case .s: return 0
        }
    }
    var seconds: Double { pow(10, Double(exponent)) }
}

enum Fmt {
    /// Compact number: 10, 2.5, 0.125
    static func num(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        var s = String(format: "%.6f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func frequency(period: Double, unit: TimeUnit) -> String {
        let secs = period * unit.seconds
        guard secs > 0 else { return "" }
        let f = 1 / secs
        let units: [(Double, String)] = [(1e12, "THz"), (1e9, "GHz"), (1e6, "MHz"), (1e3, "kHz"), (1, "Hz")]
        for (scale, name) in units where f >= scale {
            return num((f / scale * 1000).rounded() / 1000) + " " + name
        }
        return num(f) + " Hz"
    }

    /// Makes a legal Verilog identifier.
    static func identifier(_ s: String) -> String {
        var out = s.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" ? $0 : "_" }
        if out.isEmpty { return "tb" }
        if out[0].isNumber { out.insert("_", at: 0) }
        return String(out)
    }

    static func isIdentifier(_ s: String) -> Bool {
        guard let f = s.first, f.isASCII, f.isLetter || f == "_" else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
            && !VerilogParser.keywords.contains(s)
    }
}
