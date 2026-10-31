import Foundation

// MARK: - Parsed design info

enum PortDir: String, Codable, CaseIterable {
    case input, output, bidir = "inout"
}

struct PortRange: Codable, Hashable {
    var msb: String
    var lsb: String
}

struct PortInfo: Codable, Hashable, Identifiable {
    var name: String
    var dir: PortDir
    /// Packed ranges, outermost first (`[3:0][7:0]` gives two).
    var ranges: [PortRange] = []
    var isSigned = false
    /// Declared type words, e.g. "wire", "reg", "logic", "integer".
    var dataType = ""
    /// Why this port cannot be driven from a generated testbench (interface, unpacked array, …).
    var unsupported: String? = nil

    var id: String { name }

    /// Width of the built-in type when no range is given.
    var baseWidth: Int {
        let words = Set(dataType.split(separator: " ").map(String.init))
        if words.contains("longint") || words.contains("time") { return 64 }
        if words.contains("integer") || words.contains("int") { return 32 }
        if words.contains("shortint") { return 16 }
        if words.contains("byte") { return 8 }
        return 1
    }

    var isIntegerType: Bool {
        let words = Set(dataType.split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["integer", "int", "shortint", "longint", "byte"])
    }
}

struct ParamInfo: Codable, Hashable, Identifiable {
    var name: String
    /// Default value expression as written in the source.
    var value: String
    var isLocal: Bool
    var id: String { name }
}

struct ModuleInfo: Identifiable, Hashable {
    var name: String
    var ports: [PortInfo]
    var params: [ParamInfo]
    var instantiates: [String]
    var file: URL
    var line: Int
    var warnings: [String]

    var id: String { file.path + "::" + name }
    var inputs: [PortInfo] { ports.filter { $0.dir == .input } }
    var outputs: [PortInfo] { ports.filter { $0.dir != .input } }
}

// MARK: - Preprocessor

/// Handles `define / `ifdef / `include well enough to read port lists.
struct Preprocessor {
    var defines: [String: String] = [:]
    private var functionMacros: Set<String> = []
    private var includeDepth = 0

    init(defines: [String: String] = [:]) {
        self.defines = defines
    }

    static func stripComments(_ b: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        let n = b.count
        var inStr = false
        while i < n {
            let c = b[i]
            if inStr {
                out.append(c)
                if c == 92, i + 1 < n { out.append(b[i + 1]); i += 2; continue }
                if c == 34 || c == 10 { inStr = false }
                i += 1
                continue
            }
            if c == 34 { inStr = true; out.append(c); i += 1; continue }
            if c == 47, i + 1 < n, b[i + 1] == 47 {
                while i < n && b[i] != 10 { i += 1 }
                continue
            }
            if c == 47, i + 1 < n, b[i + 1] == 42 {
                i += 2
                while i < n && !(b[i] == 42 && i + 1 < n && b[i + 1] == 47) {
                    if b[i] == 10 { out.append(10) }
                    i += 1
                }
                i += 2
                out.append(32)
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Returns the source with comments and directives removed and macros expanded.
    /// Line numbers are preserved.
    mutating func process(_ text: String, fileDir: URL?) -> String {
        let stripped = String(decoding: Self.stripComments(Array(text.utf8)), as: UTF8.self)
        let lines = stripped.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var stack: [(active: Bool, taken: Bool)] = []
        var active: Bool { stack.allSatisfy { $0.active } }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("`") {
                let word = String(trimmed.prefix { !$0.isWhitespace })
                let rest = String(trimmed.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
                var handled = true
                switch word {
                case "`define":
                    var body = rest
                    var extra = 0
                    while body.hasSuffix("\\"), i + extra + 1 < lines.count {
                        body.removeLast()
                        extra += 1
                        body += " " + lines[i + extra].trimmingCharacters(in: .whitespaces)
                    }
                    if active { define(body) }
                    for _ in 0...extra { out.append("") }
                    i += 1 + extra
                    continue
                case "`undef":
                    if active { defines[firstWord(rest)] = nil }
                case "`ifdef", "`ifndef":
                    var cond = defines[firstWord(rest)] != nil
                    if word == "`ifndef" { cond.toggle() }
                    stack.append((cond, cond))
                case "`elsif":
                    if var last = stack.popLast() {
                        if last.taken {
                            last.active = false
                        } else {
                            let cond = defines[firstWord(rest)] != nil
                            last.active = cond
                            last.taken = cond
                        }
                        stack.append(last)
                    }
                case "`else":
                    if var last = stack.popLast() {
                        last.active = !last.taken
                        last.taken = true
                        stack.append(last)
                    }
                case "`endif":
                    _ = stack.popLast()
                case "`include":
                    if active, let dir = fileDir { include(rest, dir: dir) }
                case "`timescale", "`default_nettype", "`resetall", "`celldefine", "`endcelldefine",
                     "`pragma", "`line", "`begin_keywords", "`end_keywords", "`unconnected_drive",
                     "`nounconnected_drive", "`undefineall":
                    break
                default:
                    handled = false
                }
                if handled {
                    out.append("")
                    i += 1
                    continue
                }
            }
            out.append(active ? substitute(line) : "")
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private func firstWord(_ s: String) -> String {
        String(s.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })
    }

    private mutating func define(_ body: String) {
        let name = firstWord(body)
        guard !name.isEmpty else { return }
        let after = body.dropFirst(name.count)
        if after.first == "(" {
            functionMacros.insert(name)
            return
        }
        defines[name] = after.trimmingCharacters(in: .whitespaces)
    }

    private mutating func include(_ spec: String, dir: URL) {
        guard includeDepth < 8 else { return }
        let name = spec.trimmingCharacters(in: CharacterSet(charactersIn: "\"<> "))
        let url = dir.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        includeDepth += 1
        _ = process(text, fileDir: url.deletingLastPathComponent())
        includeDepth -= 1
    }

    /// Replaces `NAME with its definition.
    func substitute(_ line: String) -> String {
        guard line.contains("`") else { return line }
        var s = line
        for _ in 0..<8 {
            guard s.contains("`") else { break }
            var result = ""
            var changed = false
            var idx = s.startIndex
            while idx < s.endIndex {
                let c = s[idx]
                if c == "`" {
                    var j = s.index(after: idx)
                    while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_" { j = s.index(after: j) }
                    let name = String(s[s.index(after: idx)..<j])
                    if let body = defines[name] {
                        result += body
                        changed = true
                    } else {
                        result += s[idx..<j]
                    }
                    idx = j
                } else {
                    result.append(c)
                    idx = s.index(after: idx)
                }
            }
            s = result
            if !changed { break }
        }
        return s
    }
}

// MARK: - Lexer

enum TokKind {
    case ident, number, string, system, symbol, macro
}

struct Tok {
    var kind: TokKind
    var text: String
    var start: Int
    var end: Int
    var line: Int
}

enum VerilogLexer {
    private static let threeSym: Set<String> = ["<<<", ">>>", "===", "!==", "<<=", ">>=", "==?", "!=?"]
    private static let twoSym: Set<String> = ["**", "<<", ">>", "==", "!=", "<=", ">=", "&&", "||", "::", "+:", "-:",
                                              "~&", "~|", "~^", "^~", "->", "++", "--", "+=", "-=", "'{", "|=", "&=", "^="]

    static func isIdStart(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
    static func isIdChar(_ c: UInt8) -> Bool { isIdStart(c) || (c >= 48 && c <= 57) || c == 36 }
    static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    static func isBaseChar(_ c: UInt8) -> Bool {
        // b o d h B O D H s S
        [98, 111, 100, 104, 66, 79, 68, 72, 115, 83].contains(c)
    }
    static func isValueDigit(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) || c == 120 || c == 88 || c == 122 || c == 90
            || c == 63 || c == 95
    }

    static func lex(_ text: String) -> [Tok] { lex(Array(text.utf8)) }

    static func lex(_ b: [UInt8]) -> [Tok] {
        var toks: [Tok] = []
        var i = 0
        var line = 1
        let n = b.count
        func str(_ s: Int, _ e: Int) -> String { String(decoding: b[s..<e], as: UTF8.self) }

        while i < n {
            let c = b[i]
            if c == 10 { line += 1; i += 1; continue }
            if c == 32 || c == 9 || c == 13 || c == 12 { i += 1; continue }
            let s = i
            if isIdStart(c) {
                while i < n && isIdChar(b[i]) { i += 1 }
                toks.append(Tok(kind: .ident, text: str(s, i), start: s, end: i, line: line))
                continue
            }
            if c == 92 { // escaped identifier
                i += 1
                while i < n && !(b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13) { i += 1 }
                toks.append(Tok(kind: .ident, text: str(s, i), start: s, end: i, line: line))
                continue
            }
            if c == 36 { // $system
                i += 1
                while i < n && isIdChar(b[i]) { i += 1 }
                toks.append(Tok(kind: .system, text: str(s, i), start: s, end: i, line: line))
                continue
            }
            if c == 96 { // `macro left unexpanded
                i += 1
                while i < n && isIdChar(b[i]) { i += 1 }
                toks.append(Tok(kind: .macro, text: str(s, i), start: s, end: i, line: line))
                continue
            }
            if c == 34 { // "string"
                i += 1
                while i < n && b[i] != 34 && b[i] != 10 {
                    if b[i] == 92 { i += 1 }
                    i += 1
                }
                i = min(i + 1, n)
                toks.append(Tok(kind: .string, text: str(s, i), start: s, end: i, line: line))
                continue
            }
            if isDigit(c) || (c == 39 && i + 1 < n && isBaseChar(b[i + 1])) {
                var sized = c == 39
                if isDigit(c) {
                    while i < n && (isDigit(b[i]) || b[i] == 95) { i += 1 }
                    if i + 1 < n && b[i] == 46 && isDigit(b[i + 1]) {
                        i += 1
                        while i < n && (isDigit(b[i]) || b[i] == 95) { i += 1 }
                    }
                    if i < n && (b[i] == 101 || b[i] == 69),
                       i + 1 < n, isDigit(b[i + 1]) || ((b[i + 1] == 45 || b[i + 1] == 43) && i + 2 < n && isDigit(b[i + 2])) {
                        i += 2
                        while i < n && isDigit(b[i]) { i += 1 }
                    }
                    var j = i
                    while j < n && (b[j] == 32 || b[j] == 9) { j += 1 }
                    if j + 1 < n && b[j] == 39 && isBaseChar(b[j + 1]) {
                        i = j
                        sized = true
                    }
                }
                if sized {
                    i += 1 // '
                    if i < n && (b[i] == 115 || b[i] == 83) { i += 1 }
                    if i < n { i += 1 } // base
                    while i < n && (b[i] == 32 || b[i] == 9) { i += 1 }
                    while i < n && isValueDigit(b[i]) { i += 1 }
                }
                toks.append(Tok(kind: .number, text: str(s, i), start: s, end: i, line: line))
                continue
            }
            if c == 39, i + 1 < n, [48, 49, 120, 88, 122, 90].contains(b[i + 1]) { // '0 '1 'x 'z
                i += 2
                toks.append(Tok(kind: .number, text: str(s, i), start: s, end: i, line: line))
                continue
            }
            if i + 3 <= n, threeSym.contains(str(i, i + 3)) {
                i += 3
            } else if i + 2 <= n, twoSym.contains(str(i, i + 2)) {
                i += 2
            } else {
                i += 1
            }
            toks.append(Tok(kind: .symbol, text: str(s, i), start: s, end: i, line: line))
        }
        return toks
    }
}

// MARK: - Parser

struct VerilogParser {
    static let directionWords: Set<String> = ["input", "output", "inout"]
    static let typeWords: Set<String> = [
        "wire", "reg", "logic", "bit", "var", "tri", "tri0", "tri1", "triand", "trior", "trireg", "wand", "wor",
        "uwire", "supply0", "supply1", "integer", "int", "byte", "shortint", "longint", "time", "real",
        "realtime", "shortreal", "signed", "unsigned", "string", "const", "interconnect",
    ]
    static let keywords: Set<String> = [
        "always", "always_comb", "always_ff", "always_latch", "and", "assert", "assign", "assume", "automatic",
        "begin", "bit", "buf", "bufif0", "bufif1", "byte", "case", "casex", "casez", "cmos", "const", "cover",
        "deassign", "default", "defparam", "disable", "do", "edge", "else", "end", "endcase", "endfunction",
        "endgenerate", "endmodule", "endtask", "enum", "event", "final", "for", "force", "forever", "fork",
        "function", "generate", "genvar", "highz0", "highz1", "if", "iff", "import", "initial", "inout", "input",
        "int", "integer", "join", "join_any", "join_none", "large", "localparam", "logic", "longint",
        "macromodule", "medium", "module", "nand", "negedge", "nmos", "nor", "not", "notif0", "notif1", "or",
        "output", "parameter", "pmos", "posedge", "primitive", "pull0", "pull1", "pulldown", "pullup", "rcmos",
        "real", "realtime", "reg", "release", "repeat", "return", "rnmos", "rpmos", "rtran", "rtranif0",
        "rtranif1", "scalared", "shortint", "signed", "small", "specify", "specparam", "static", "strong0",
        "strong1", "struct", "supply0", "supply1", "table", "task", "time", "tran", "tranif0", "tranif1", "tri",
        "tri0", "tri1", "triand", "trior", "trireg", "typedef", "union", "unique", "unique0", "priority",
        "unsigned", "vectored", "wait", "wand", "weak0", "weak1", "while", "wire", "wor", "xnor", "xor", "var",
        "void", "break", "continue", "uwire", "string", "class", "package", "interface", "program", "property",
        "sequence", "endproperty", "endsequence", "covergroup", "endgroup", "modport", "clocking",
        "endclocking", "let", "constraint", "virtual", "extern", "export", "ref", "type",
    ]

    let toks: [Tok]
    let text: [UInt8]
    let file: URL

    struct Result {
        var modules: [ModuleInfo]
        var errors: [String]
    }

    /// Parses every module in a file.
    static func parse(file: URL) -> Result {
        guard let data = try? Data(contentsOf: file) else {
            return Result(modules: [], errors: ["Could not read \(file.lastPathComponent)"])
        }
        let raw = String(decoding: data, as: UTF8.self)
        return parse(text: raw, file: file)
    }

    static func parse(text raw: String, file: URL) -> Result {
        var pre = Preprocessor()
        let processed = pre.process(raw, fileDir: file.deletingLastPathComponent())
        let bytes = Array(processed.utf8)
        let p = VerilogParser(toks: VerilogLexer.lex(bytes), text: bytes, file: file)
        return p.run()
    }

    private func run() -> Result {
        var modules: [ModuleInfo] = []
        var errors: [String] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t.kind == .ident, t.text == "module" || t.text == "macromodule" {
                if let (m, next) = parseModule(at: i) {
                    modules.append(m)
                    i = next
                    continue
                } else {
                    errors.append("Line \(t.line): could not read the module header")
                }
            }
            i += 1
        }
        return Result(modules: modules, errors: errors)
    }

    // MARK: Helpers

    private func tx(_ i: Int) -> String { i < toks.count ? toks[i].text : "" }

    /// Index of the bracket closing the one at `i`.
    private func matching(_ i: Int) -> Int {
        var depth = 0
        var k = i
        while k < toks.count {
            switch toks[k].text {
            case "(", "[", "{", "'{": depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth == 0 { return k }
            default: break
            }
            k += 1
        }
        return toks.count - 1
    }

    /// Splits [a, b) at commas that are not nested in brackets.
    private func splitItems(_ a: Int, _ b: Int, separator: String = ",") -> [(Int, Int)] {
        var items: [(Int, Int)] = []
        var depth = 0
        var s = a
        var k = a
        while k < b {
            switch toks[k].text {
            case "(", "[", "{", "'{": depth += 1
            case ")", "]", "}": depth -= 1
            case separator where depth == 0:
                if k > s { items.append((s, k)) }
                s = k + 1
            default: break
            }
            k += 1
        }
        if b > s { items.append((s, b)) }
        return items
    }

    /// Source text of tokens [a, b), whitespace collapsed.
    func source(_ a: Int, _ b: Int) -> String {
        guard a < b, b <= toks.count else { return "" }
        let s = String(decoding: text[toks[a].start..<toks[b - 1].end], as: UTF8.self)
        return s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
    }

    private func parseRange(_ open: Int) -> (PortRange?, Int) {
        let close = matching(open)
        let parts = splitItems(open + 1, close, separator: ":")
        if parts.count == 2 {
            return (PortRange(msb: source(parts[0].0, parts[0].1), lsb: source(parts[1].0, parts[1].1)), close + 1)
        }
        // [N] style: N bits, N-1:0
        if parts.count == 1 {
            let e = source(parts[0].0, parts[0].1)
            return (PortRange(msb: "(\(e))-1", lsb: "0"), close + 1)
        }
        return (nil, close + 1)
    }

    /// Index of the declared name in [a, b): the last identifier outside brackets before `=`.
    private func nameIndex(_ a: Int, _ b: Int) -> Int? {
        var depth = 0
        var last: Int?
        var k = a
        while k < b {
            let t = toks[k]
            switch t.text {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case "=" where depth == 0: return last
            default:
                if depth == 0, t.kind == .ident, !Self.directionWords.contains(t.text), !Self.typeWords.contains(t.text),
                   !(k + 1 < b && (toks[k + 1].text == "." || toks[k + 1].text == "::")) {
                    last = k
                }
            }
            k += 1
        }
        return last
    }

    // MARK: Module

    private func parseModule(at start: Int) -> (ModuleInfo, Int)? {
        var i = start + 1
        if tx(i) == "automatic" || tx(i) == "static" { i += 1 }
        guard i < toks.count, toks[i].kind == .ident else { return nil }
        let name = toks[i].text
        let line = toks[i].line
        i += 1
        var warnings: [String] = []

        while tx(i) == "import" {
            while i < toks.count && tx(i) != ";" { i += 1 }
            i += 1
        }

        var params: [ParamInfo] = []
        var headerParams = false
        if tx(i) == "#", tx(i + 1) == "(" {
            let close = matching(i + 1)
            params = parseParamItems(i + 2, close, defaultLocal: false)
            headerParams = true
            i = close + 1
        }

        var ports: [PortInfo] = []
        var nonAnsiNames: [String] = []
        var ansi = true
        if tx(i) == "(" {
            let close = matching(i)
            (ports, nonAnsiNames, ansi) = parsePortList(i + 1, close, warnings: &warnings)
            i = close + 1
        }
        if tx(i) == ";" { i += 1 }

        // Body
        var end = i
        while end < toks.count && tx(end) != "endmodule" { end += 1 }

        var nonAnsiPorts: [String: PortInfo] = [:]
        var netDecls: [String: (ranges: [PortRange], type: String, signed: Bool)] = [:]
        var instantiates: [String] = []
        var k = i
        var stmtStart = true
        while k < end {
            let t = toks[k]
            if t.text == "function" || t.text == "task" {
                let closer = t.text == "function" ? "endfunction" : "endtask"
                while k < end && tx(k) != closer { k += 1 }
                k += 1
                stmtStart = true
                continue
            }
            if stmtStart && t.kind == .ident {
                if Self.directionWords.contains(t.text) {
                    var semi = k
                    while semi < end && tx(semi) != ";" { semi += 1 }
                    if !ansi {
                        for p in parseDeclaration(k, semi, dir: PortDir(rawValue: t.text)) {
                            nonAnsiPorts[p.name] = p
                        }
                    }
                    k = semi + 1
                    stmtStart = true
                    continue
                }
                if t.text == "parameter" || t.text == "localparam" {
                    var semi = k
                    while semi < end && tx(semi) != ";" { semi += 1 }
                    let local = t.text == "localparam" || headerParams
                    for p in parseParamItems(k, semi, defaultLocal: local) where !params.contains(where: { $0.name == p.name }) {
                        params.append(p)
                    }
                    k = semi + 1
                    stmtStart = true
                    continue
                }
                if !ansi, Self.typeWords.contains(t.text) {
                    var semi = k
                    while semi < end && tx(semi) != ";" { semi += 1 }
                    for p in parseDeclaration(k, semi, dir: nil) {
                        netDecls[p.name] = (p.ranges, p.dataType, p.isSigned)
                    }
                    k = semi + 1
                    stmtStart = true
                    continue
                }
                if !Self.keywords.contains(t.text), k + 1 < end {
                    let n1 = toks[k + 1]
                    if n1.text == "#" || (n1.kind == .ident && tx(k + 2) == "(") || (n1.kind == .ident && tx(k + 2) == "[") {
                        if !instantiates.contains(t.text) { instantiates.append(t.text) }
                    }
                }
            }
            stmtStart = [";", "begin", "end", "generate", "endgenerate", "else", ")", "endcase", "endfunction", "endtask"]
                .contains(t.text)
                || (k >= 2 && tx(k - 1) == ":" && ["begin", "end", "fork"].contains(tx(k - 2))) // `begin : label`
            k += 1
        }

        if !ansi {
            for n in nonAnsiNames {
                if var p = nonAnsiPorts[n] {
                    if let decl = netDecls[n] {
                        if p.ranges.isEmpty { p.ranges = decl.ranges }
                        if !decl.type.isEmpty { p.dataType = p.dataType.isEmpty ? decl.type : p.dataType + " " + decl.type }
                        p.isSigned = p.isSigned || decl.signed
                    }
                    ports.append(p)
                } else {
                    ports.append(PortInfo(name: n, dir: .bidir, unsupported: "no input/output declaration found"))
                    warnings.append("Port \(n) has no direction")
                }
            }
        }

        for p in ports where p.unsupported != nil {
            warnings.append("Port \(p.name): \(p.unsupported!)")
        }

        let m = ModuleInfo(name: name, ports: ports, params: params, instantiates: instantiates,
                           file: file, line: line, warnings: warnings)
        return (m, end + 1)
    }

    private func parseParamItems(_ a: Int, _ b: Int, defaultLocal: Bool) -> [ParamInfo] {
        var out: [ParamInfo] = []
        var local = defaultLocal
        for (s, e) in splitItems(a, b) {
            var j = s
            if tx(j) == "parameter" { local = defaultLocal; j += 1 } else if tx(j) == "localparam" { local = true; j += 1 }
            if tx(j) == "type" { continue }
            var eq: Int?
            var depth = 0
            for q in j..<e {
                switch tx(q) {
                case "(", "[", "{": depth += 1
                case ")", "]", "}": depth -= 1
                case "=" where depth == 0 && eq == nil: eq = q
                default: break
                }
            }
            guard let ni = nameIndex(j, eq ?? e) else { continue }
            let value = eq.map { source($0 + 1, e) } ?? ""
            out.append(ParamInfo(name: toks[ni].text, value: value, isLocal: local))
        }
        return out
    }

    /// Reads type words and packed ranges in [a, b).
    private func readType(_ a: Int, _ b: Int) -> (type: String, signed: Bool, ranges: [PortRange], userType: String?) {
        var type: [String] = []
        var signed = false
        var ranges: [PortRange] = []
        var user: [String] = []
        var k = a
        while k < b {
            let t = tx(k)
            if Self.directionWords.contains(t) {
                k += 1
            } else if t == "signed" {
                signed = true
                k += 1
            } else if t == "unsigned" {
                k += 1
            } else if Self.typeWords.contains(t) {
                type.append(t)
                k += 1
            } else if t == "[" {
                let (r, next) = parseRange(k)
                if let r { ranges.append(r) }
                k = next
            } else {
                user.append(t)
                k += 1
            }
        }
        return (type.joined(separator: " "), signed, ranges, user.isEmpty ? nil : user.joined())
    }

    private func parsePortList(_ a: Int, _ b: Int, warnings: inout [String]) -> ([PortInfo], [String], Bool) {
        let items = splitItems(a, b)
        guard !items.isEmpty else { return ([], [], true) }

        let first = toks[items[0].0]
        let looksAnsi = items.contains { (s, e) in
            let t = toks[s].text
            if Self.directionWords.contains(t) || Self.typeWords.contains(t) { return true }
            // user type / interface: two identifiers in a row, or `if.modport name`
            return e - s >= 2 && toks[s].kind == .ident && (toks[s + 1].kind == .ident || toks[s + 1].text == "." || toks[s + 1].text == "::")
        }
        if !looksAnsi {
            var names: [String] = []
            for (s, e) in items {
                if tx(s) == ".", s + 1 < e { names.append(tx(s + 1)); continue }
                if let n = (s..<e).first(where: { toks[$0].kind == .ident }) { names.append(toks[n].text) }
            }
            _ = first
            return ([], names, false)
        }

        var ports: [PortInfo] = []
        var prev: PortInfo?
        for (s, e) in items {
            guard let ni = nameIndex(s, e) else { continue }
            let name = toks[ni].text
            let hasDir = Self.directionWords.contains(tx(s))
            let (type, signed, ranges, user) = readType(s, ni)
            var p: PortInfo
            if !hasDir && type.isEmpty && ranges.isEmpty && user == nil && !signed, let prev {
                p = prev
                p.name = name
            } else {
                let dir = hasDir ? PortDir(rawValue: tx(s))! : (prev?.dir ?? .bidir)
                p = PortInfo(name: name, dir: dir, ranges: ranges, isSigned: signed, dataType: type)
                if let user {
                    p.dataType = user
                    if user.contains(".") || !hasDir {
                        p.unsupported = "interface port (\(user))"
                    } else {
                        p.unsupported = "user-defined type \(user)"
                    }
                }
                if type.contains("real") || type.contains("string") {
                    p.unsupported = "\(type) ports are not supported"
                }
                if !hasDir && prev == nil && user == nil {
                    p.unsupported = "no direction"
                }
            }
            // Unpacked dimensions after the name
            if tx(ni + 1) == "[" {
                p.unsupported = "unpacked array port"
            }
            ports.append(p)
            prev = p
        }
        return (ports, [], true)
    }

    /// `input [7:0] a, b;` → ports a and b.
    private func parseDeclaration(_ a: Int, _ b: Int, dir: PortDir?) -> [PortInfo] {
        let items = splitItems(a, b)
        guard let firstItem = items.first, let ni = nameIndex(firstItem.0, firstItem.1) else { return [] }
        let (type, signed, ranges, user) = readType(firstItem.0, ni)
        var out: [PortInfo] = []
        for (idx, (s, e)) in items.enumerated() {
            let n = idx == 0 ? ni : (nameIndex(s, e) ?? s)
            guard n < toks.count, toks[n].kind == .ident else { continue }
            var p = PortInfo(name: toks[n].text, dir: dir ?? .bidir, ranges: ranges, isSigned: signed, dataType: type)
            if let user { p.unsupported = "user-defined type \(user)" }
            if tx(n + 1) == "[" { p.unsupported = "unpacked array port" }
            out.append(p)
        }
        return out
    }
}
