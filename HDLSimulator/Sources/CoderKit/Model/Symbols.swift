import Foundation

enum SymbolKind: String, Codable, Hashable, Sendable {
    case module, entity, architecture, package, interface, program, klass, component
    case port, param, constant, signal, instance, process, function, task, type, block

    var icon: String {
        switch self {
        case .module, .entity: return "cpu"
        case .architecture: return "square.stack.3d.up"
        case .package: return "shippingbox"
        case .interface: return "point.3.connected.trianglepath.dotted"
        case .program, .klass: return "c.square"
        case .component: return "puzzlepiece"
        case .port: return "arrow.left.arrow.right"
        case .param, .constant: return "number"
        case .signal: return "line.diagonal"
        case .instance: return "square.on.square"
        case .process: return "arrow.triangle.2.circlepath"
        case .function: return "function"
        case .task: return "checklist"
        case .type: return "t.square"
        case .block: return "square.dashed"
        }
    }

    var isContainer: Bool {
        switch self {
        case .module, .entity, .architecture, .package, .interface, .program, .klass: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .klass: return "class"
        default: return rawValue
        }
    }
}

struct HDLSymbol: Identifiable, Hashable, Codable, Sendable {
    var kind: SymbolKind
    var name: String
    var detail: String = ""
    var line: Int            // 0-based
    var endLine: Int
    var offset: Int          // UTF-16 offset of the name
    var children: [HDLSymbol] = []
    var dir: String? = nil
    var range: String? = nil
    var dataType: String? = nil
    var value: String? = nil
    var target: String? = nil   // module type of an instance / entity of an architecture

    var id: String { "\(kind.rawValue):\(name):\(line):\(offset)" }

    var ports: [HDLSymbol] { children.filter { $0.kind == .port } }
    var params: [HDLSymbol] { children.filter { $0.kind == .param && $0.dir != "local" } }

    /// All symbols, depth first.
    func flattened() -> [HDLSymbol] {
        [self] + children.flatMap { $0.flattened() }
    }
}

extension Array where Element == HDLSymbol {
    func flattened() -> [HDLSymbol] { flatMap { $0.flattened() } }

    /// The innermost symbols containing `line`, outermost first.
    func path(at line: Int) -> [HDLSymbol] {
        guard let s = first(where: { $0.line <= line && line <= $0.endLine && ($0.kind.isContainer || $0.kind == .process || $0.kind == .function || $0.kind == .task || $0.kind == .instance) }) else { return [] }
        return [s] + s.children.path(at: line)
    }
}

/// Builds the outline of a file from its tokens.
struct SymbolScanner {
    let u: [UInt16]
    let toks: [Token]
    let vhdl: Bool
    var i = 0

    static func scan(_ text: String, language: HDLLanguage) -> [HDLSymbol] {
        let u = Array(text.utf16)
        return scan(u, tokens: Lexer.lex(u, language: language), language: language)
    }

    static func scan(_ u: [UInt16], tokens: [Token], language: HDLLanguage) -> [HDLSymbol] {
        guard language != .plain else { return [] }
        let sig = tokens.filter { $0.kind != .comment && $0.kind != .attribute }
        var s = SymbolScanner(u: u, toks: sig, vhdl: language == .vhdl)
        return s.vhdl ? s.scanVHDL() : s.scanVerilog()
    }

    // MARK: Helpers

    func text(_ t: Token) -> String { Lexer.string(u, t) }
    func word(_ k: Int) -> String {
        guard k < toks.count else { return "" }
        let t = toks[k]
        guard t.kind != .op && t.kind != .string && t.kind != .number else { return "" }
        return vhdl ? text(t).lowercased() : text(t)
    }
    func isOp(_ k: Int, _ ch: Character) -> Bool {
        guard k < toks.count, toks[k].kind == .op else { return false }
        return Character(UnicodeScalar(u[toks[k].start])!) == ch
    }
    func isName(_ k: Int) -> Bool {
        guard k < toks.count else { return false }
        let kd = toks[k].kind
        return kd == .ident || kd == .typeName || kd == .funcName
    }
    func source(_ a: Int, _ b: Int) -> String {
        // Source text from token a through token b (inclusive), whitespace collapsed.
        guard a < toks.count, a <= b else { return "" }
        let s = toks[a].start, e = toks[min(b, toks.count - 1)].end
        let raw = String(utf16CodeUnits: Array(u[s..<e]), count: e - s)
        return raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
    }
    /// Index of the token matching the bracket at `k`.
    func matching(_ k: Int) -> Int {
        guard k < toks.count else { return toks.count }
        let open = u[toks[k].start]
        let close: UInt16 = open == 40 ? 41 : (open == 91 ? 93 : 125)
        var depth = 0
        var j = k
        while j < toks.count {
            if toks[j].kind == .op {
                let c = u[toks[j].start]
                if c == open { depth += 1 } else if c == close {
                    depth -= 1
                    if depth == 0 { return j }
                }
            }
            j += 1
        }
        return toks.count - 1
    }
    /// Next index at depth 0 that is one of the given single-char ops.
    func findTopLevel(from k: Int, _ chars: Set<Character>, limit: Int? = nil) -> Int {
        var depth = 0
        var j = k
        let end = limit ?? toks.count
        while j < end {
            if toks[j].kind == .op {
                let c = Character(UnicodeScalar(u[toks[j].start])!)
                if depth == 0 && chars.contains(c) { return j }
                if c == "(" || c == "[" || c == "{" { depth += 1 }
                if c == ")" || c == "]" || c == "}" { depth = max(0, depth - 1) }
            }
            j += 1
        }
        return end
    }

    // MARK: Verilog

    static let containerEnds: [String: String] = [
        "module": "endmodule", "macromodule": "endmodule", "interface": "endinterface", "program": "endprogram",
        "package": "endpackage", "class": "endclass", "checker": "endchecker", "primitive": "endprimitive",
    ]
    static let netTypes: Set<String> = [
        "wire", "reg", "logic", "bit", "byte", "int", "integer", "shortint", "longint", "real", "realtime",
        "shortreal", "time", "string", "tri", "tri0", "tri1", "triand", "trior", "trireg", "wand", "wor",
        "supply0", "supply1", "uwire", "genvar", "event", "chandle", "var",
    ]

    mutating func scanVerilog() -> [HDLSymbol] {
        var out: [HDLSymbol] = []
        while i < toks.count {
            let w = word(i)
            if let end = Self.containerEnds[w], !(w == "class" && word(i - 1) == "typedef"), !(w == "interface" && word(i - 1) == "virtual") {
                if let s = parseContainer(w, endWord: end) { out.append(s) }
            } else {
                i += 1
            }
        }
        return out
    }

    private func kind(for w: String) -> SymbolKind {
        switch w {
        case "interface": return .interface
        case "program": return .program
        case "package": return .package
        case "class": return .klass
        default: return .module
        }
    }

    mutating func parseContainer(_ w: String, endWord: String) -> HDLSymbol? {
        let startLine = toks[i].line
        i += 1
        while ["static", "automatic", "virtual"].contains(word(i)) { i += 1 }
        guard isName(i) else { return nil }
        var sym = HDLSymbol(kind: kind(for: w), name: text(toks[i]), line: toks[i].line, endLine: startLine, offset: toks[i].start)
        sym.line = startLine
        i += 1
        var ports: [HDLSymbol] = []
        var params: [HDLSymbol] = []
        // header
        while i < toks.count && !isOp(i, ";") {
            if isOp(i, "#") && isOp(i + 1, "(") {
                let close = matching(i + 1)
                params += parseParamList(i + 2, close)
                i = close + 1
            } else if isOp(i, "(") {
                let close = matching(i)
                ports += parsePortList(i + 1, close)
                i = close + 1
            } else if word(i) == endWord {
                break
            } else {
                i += 1
            }
        }
        if isOp(i, ";") { i += 1 }

        var body: [HDLSymbol] = []
        var depth = 0
        while i < toks.count {
            let w2 = word(i)
            if w2 == endWord && depth == 0 {
                sym.endLine = toks[i].line
                i += 1
                if isOp(i, ":") && isName(i + 1) { i += 2 }
                break
            }
            if toks[i].kind == .op {
                let c = u[toks[i].start]
                if c == 40 || c == 91 || c == 123 { depth += 1 }
                else if c == 41 || c == 93 || c == 125 { depth = max(0, depth - 1) }
                i += 1
                continue
            }
            if depth > 0 { i += 1; continue }
            if let e = Self.containerEnds[w2], !(w2 == "class" && word(i - 1) == "typedef"), !(w2 == "interface" && word(i - 1) == "virtual") {
                if let s = parseContainer(w2, endWord: e) { body.append(s) }
                continue
            }
            switch w2 {
            case "input", "output", "inout", "ref":
                let end = findTopLevel(from: i, [";"])
                let decl = parseDecl(i, end, dirWord: w2)
                for d in decl {
                    if let k = ports.firstIndex(where: { $0.name == d.name }) {
                        ports[k].dir = d.dir; ports[k].range = d.range; ports[k].dataType = d.dataType
                        ports[k].detail = d.detail; ports[k].line = d.line; ports[k].endLine = d.endLine; ports[k].offset = d.offset
                    } else {
                        ports.append(d)
                    }
                }
                i = end + 1
            case "parameter", "localparam":
                let end = findTopLevel(from: i, [";"])
                params += parseParamList(i, end).map { var p = $0; if w2 == "localparam" { p.dir = "local"; p.detail = "localparam" + (p.value.map { " = \($0)" } ?? "") }; return p }
                i = end + 1
            case "typedef":
                let end = findTopLevel(from: i, [";"])
                var k = end - 1
                while k > i && !isName(k) { k -= 1 }
                if k > i {
                    let what = word(i + 1)
                    body.append(HDLSymbol(kind: .type, name: text(toks[k]), detail: what, line: toks[i].line, endLine: toks[end < toks.count ? end : k].line, offset: toks[k].start))
                }
                i = end + 1
            case "function", "task":
                body.append(parseRoutine(w2))
            case "always", "always_ff", "always_comb", "always_latch", "initial", "final":
                body.append(parseProcess(w2))
            case "assign", "defparam", "import", "export", "bind", "alias":
                i = findTopLevel(from: i, [";"]) + 1
            case "constraint", "covergroup", "property", "sequence", "clocking", "specify", "config":
                let ends = ["constraint": "}", "covergroup": "endgroup", "property": "endproperty", "sequence": "endsequence",
                            "clocking": "endclocking", "specify": "endspecify", "config": "endconfig"]
                if w2 == "constraint" {
                    while i < toks.count && !isOp(i, "{") { i += 1 }
                    i = matching(i) + 1
                } else {
                    let e = ends[w2]!
                    while i < toks.count && word(i) != e && word(i) != endWord { i += 1 }
                    if word(i) == e { i += 1 }
                }
            default:
                if Self.netTypes.contains(w2) || (w2 == "signed" || w2 == "unsigned") {
                    if word(i - 1) == "typedef" || isOp(i - 1, "(") { i += 1; continue }
                    let end = findTopLevel(from: i, [";"])
                    body += parseDecl(i, end, dirWord: nil)
                    i = end + 1
                } else if toks[i].kind == .ident || toks[i].kind == .typeName, !isOp(i - 1, "."), !(i > 0 && isOp(i - 1, ":") && isOp(i - 2, ":")) {
                    if let inst = tryInstance() {
                        body += inst
                    } else if isName(i + 1), isOp(i + 2, ";") || isOp(i + 2, ",") || isOp(i + 2, "=") || (isOp(i + 2, "[") && !isOp(findTopLevel(from: i + 2, [";", "("]), "(")) {
                        // user-defined type: my_t a, b;
                        let end = findTopLevel(from: i, [";"])
                        body += parseDecl(i, end, dirWord: nil)
                        i = end + 1
                    } else {
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
        }
        if sym.endLine < sym.line { sym.endLine = toks.last?.line ?? sym.line }
        sym.children = ports + params + body
        return sym
    }

    /// `foo #(...) u_foo (...), u_bar (...);`
    mutating func tryInstance() -> [HDLSymbol]? {
        let modTok = i
        var k = i + 1
        var paramText: String? = nil
        if isOp(k, "#") {
            if isOp(k + 1, "(") {
                let close = matching(k + 1)
                paramText = source(k + 2, close - 1)
                k = close + 1
            } else {
                k += 2  // #5
            }
        }
        guard isName(k) else { return nil }
        var j = k + 1
        if isOp(j, "[") { j = matching(j) + 1 }
        guard isOp(j, "(") else { return nil }
        var out: [HDLSymbol] = []
        let module = text(toks[modTok])
        while true {
            guard isName(k) else { break }
            var j2 = k + 1
            if isOp(j2, "[") { j2 = matching(j2) + 1 }
            guard isOp(j2, "(") else { break }
            let close = matching(j2)
            var s = HDLSymbol(kind: .instance, name: text(toks[k]), detail: module, line: toks[modTok].line,
                              endLine: toks[close].line, offset: toks[k].start)
            s.target = module
            s.value = paramText
            // named connections .port(sig)
            var c = j2 + 1
            while c < close {
                if isOp(c, ".") && isName(c + 1) {
                    var p = HDLSymbol(kind: .port, name: text(toks[c + 1]), line: toks[c + 1].line, endLine: toks[c + 1].line, offset: toks[c + 1].start)
                    if isOp(c + 2, "(") {
                        let pc = matching(c + 2)
                        p.detail = source(c + 3, pc - 1)
                        c = pc
                    }
                    s.children.append(p)
                }
                c += 1
            }
            out.append(s)
            k = close + 1
            if isOp(k, ",") { k += 1; continue }
            break
        }
        guard !out.isEmpty else { return nil }
        i = findTopLevel(from: k, [";"]) + 1
        return out
    }

    /// Parses `[dir] [type] [signed] [range] name [= v], name ...` between token indices [a, b).
    func parseDecl(_ a: Int, _ b: Int, dirWord: String?) -> [HDLSymbol] {
        var out: [HDLSymbol] = []
        var k = a
        var dir = dirWord
        var types: [String] = []
        var range = ""
        if dirWord != nil { k += 1 }
        while k < b {
            if isOp(k, "[") {
                let c = matching(k)
                range += source(k, c)
                k = c + 1
                continue
            }
            if isOp(k, "=") {
                k = findTopLevel(from: k, [","], limit: b)
                continue
            }
            if isOp(k, ",") { k += 1; continue }
            let w = word(k)
            if ["input", "output", "inout", "ref"].contains(w) { dir = w; types = []; range = ""; k += 1; continue }
            if Self.netTypes.contains(w) || w == "signed" || w == "unsigned" || w == "const" || w == "static" || w == "automatic" || w == "var" {
                types.append(w); k += 1; continue
            }
            if isName(k) {
                // A name followed by another name is a type name.
                if isName(k + 1) || (isOp(k + 1, ":") && isOp(k + 2, ":")) || isOp(k + 1, ".") {
                    if isOp(k + 1, ":") { types.append(source(k, k + 3)); k += 4; continue }
                    if isOp(k + 1, ".") && isName(k + 2) { types.append(source(k, k + 2)); k += 3; continue }
                    types.append(text(toks[k])); k += 1; continue
                }
                let name = text(toks[k])
                var unpacked = ""
                var e = k + 1
                while isOp(e, "[") { let c = matching(e); unpacked += source(e, c); e = c + 1 }
                let typeStr = types.joined(separator: " ")
                var detail = [dir ?? "", typeStr, range].filter { !$0.isEmpty }.joined(separator: " ")
                if !unpacked.isEmpty { detail += " " + unpacked }
                var s = HDLSymbol(kind: dir == nil ? .signal : .port, name: name, detail: detail, line: toks[k].line, endLine: toks[k].line, offset: toks[k].start)
                s.dir = dir
                s.range = range.isEmpty ? nil : range
                s.dataType = typeStr.isEmpty ? nil : typeStr
                out.append(s)
                k = e
                continue
            }
            k += 1
        }
        return out
    }

    /// `parameter A = 1, B = 2` or `#( parameter int W = 8, localparam X = W*2 )`
    func parseParamList(_ a: Int, _ b: Int) -> [HDLSymbol] {
        var out: [HDLSymbol] = []
        var k = a
        var local = false
        while k < b {
            let itemEnd = findTopLevel(from: k, [","], limit: b)
            // Find name: last identifier before '='
            let eq = findTopLevel(from: k, ["="], limit: itemEnd)
            var n = (eq < itemEnd ? eq : itemEnd) - 1
            while n >= k && isOp(n, "]") { // skip unpacked dims
                var depth = 0
                while n >= k {
                    if isOp(n, "]") { depth += 1 } else if isOp(n, "[") { depth -= 1; if depth == 0 { break } }
                    n -= 1
                }
                n -= 1
            }
            if word(k) == "localparam" { local = true } else if word(k) == "parameter" { local = false }
            if n >= k, isName(n) {
                var p = HDLSymbol(kind: .param, name: text(toks[n]), line: toks[n].line, endLine: toks[n].line, offset: toks[n].start)
                if eq < itemEnd {
                    p.value = source(eq + 1, itemEnd - 1)
                    p.detail = "= " + (p.value ?? "")
                }
                var r = ""
                var t = k
                while t < n { if isOp(t, "[") { let c = matching(t); r += source(t, c); t = c + 1 } else { t += 1 } }
                p.range = r.isEmpty ? nil : r
                if local { p.dir = "local"; p.detail = "localparam " + p.detail }
                out.append(p)
            }
            k = itemEnd + 1
        }
        return out
    }

    /// ANSI or non-ANSI port list contents between [a, b).
    func parsePortList(_ a: Int, _ b: Int) -> [HDLSymbol] {
        var out: [HDLSymbol] = []
        var k = a
        var dir: String? = nil
        var types = ""
        var range = ""
        while k < b {
            let itemEnd = findTopLevel(from: k, [","], limit: b)
            // Does this item restate the type?
            let first = word(k)
            let decl = parseDecl(k, itemEnd, dirWord: nil)
            var hasOwnType = false
            var t = k
            while t < itemEnd {
                let w = word(t)
                if ["input", "output", "inout", "ref"].contains(w) { dir = w; hasOwnType = true }
                if Self.netTypes.contains(w) || isOp(t, "[") || (isName(t) && isName(t + 1)) || (isName(t) && isOp(t + 1, ".")) { hasOwnType = true }
                if isOp(t, "[") { t = matching(t) }
                t += 1
            }
            _ = first
            if var p = decl.last {
                if hasOwnType {
                    types = p.dataType ?? ""
                    range = p.range ?? ""
                } else {
                    p.dataType = types.isEmpty ? nil : types
                    p.range = range.isEmpty ? nil : range
                }
                p.kind = .port
                p.dir = dir
                p.detail = [dir ?? "", p.dataType ?? "", p.range ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                out.append(p)
            }
            k = itemEnd + 1
        }
        return out
    }

    mutating func parseRoutine(_ w: String) -> HDLSymbol {
        let start = toks[i]
        let endWord = w == "function" ? "endfunction" : "endtask"
        // Prototype only? (extern / pure virtual / import "DPI")
        var back = i - 1
        var proto = false
        while back >= 0 && !isOp(back, ";") && toks[i].line - toks[back].line < 2 {
            if ["extern", "pure", "import", "export"].contains(word(back)) { proto = true }
            back -= 1
        }
        let headerEnd = findTopLevel(from: i, [";"])
        var nameIdx = i + 1
        var k = i + 1
        while k < headerEnd {
            if isOp(k, "(") { break }
            if isName(k) { nameIdx = k }
            if isOp(k, "[") { k = matching(k) }
            k += 1
        }
        let name = nameIdx < toks.count ? text(toks[nameIdx]) : w
        var s = HDLSymbol(kind: w == "function" ? .function : .task, name: name, line: start.line, endLine: start.line, offset: nameIdx < toks.count ? toks[nameIdx].start : start.start)
        if nameIdx < toks.count, isOp(nameIdx + 1, "(") {
            let c = matching(nameIdx + 1)
            s.detail = "(" + source(nameIdx + 2, c - 1) + ")"
        }
        if proto {
            i = headerEnd + 1
            return s
        }
        k = headerEnd
        while k < toks.count && word(k) != endWord && !Self.containerEnds.values.contains(word(k)) { k += 1 }
        s.endLine = k < toks.count ? toks[k].line : (toks.last?.line ?? s.line)
        i = (k < toks.count && word(k) == endWord) ? k + 1 : k
        if isOp(i, ":") && isName(i + 1) { i += 2 }
        return s
    }

    mutating func parseProcess(_ w: String) -> HDLSymbol {
        let start = toks[i]
        var k = i + 1
        var detail = w
        if isOp(k, "@") {
            if isOp(k + 1, "(") {
                let c = matching(k + 1)
                detail += " @(" + source(k + 2, c - 1) + ")"
                k = c + 1
            } else {
                detail += " @" + (k + 1 < toks.count ? text(toks[k + 1]) : "")
                k += 2
            }
        }
        var name = detail
        var endLine = start.line
        if word(k) == "begin" {
            if isOp(k + 1, ":") && isName(k + 2) { name = text(toks[k + 2]) }
            // find matching end
            var depth = 0
            var j = k
            while j < toks.count {
                let wj = word(j)
                if wj == "begin" || wj == "fork" || wj == "case" || wj == "casez" || wj == "casex" || wj == "randcase" { depth += 1 }
                else if wj == "end" || wj == "join" || wj == "join_any" || wj == "join_none" || wj == "endcase" {
                    depth -= 1
                    if depth == 0 { break }
                } else if Self.containerEnds.values.contains(wj) { j -= 1; break }
                j += 1
            }
            j = min(j, toks.count - 1)
            endLine = toks[j].line
            i = j + 1
        } else {
            let e = findTopLevel(from: k, [";"])
            endLine = e < toks.count ? toks[e].line : start.line
            i = e + 1
        }
        var s = HDLSymbol(kind: .process, name: name, detail: name == detail ? "" : detail, line: start.line, endLine: endLine, offset: start.start)
        s.dataType = w
        return s
    }

    // MARK: VHDL

    mutating func scanVHDL() -> [HDLSymbol] {
        var out: [HDLSymbol] = []
        while i < toks.count {
            let w = word(i)
            if w == "entity" && isName(i + 1) && word(i + 2) == "is" {
                out.append(parseEntity())
            } else if w == "architecture" && isName(i + 1) && word(i + 2) == "of" {
                out.append(parseArchitecture())
            } else if w == "package" {
                out.append(parsePackage())
            } else {
                i += 1
            }
        }
        // End lines: up to the line before the next design unit.
        for k in out.indices where out[k].endLine < out[k].line {
            out[k].endLine = k + 1 < out.count ? max(out[k].line, out[k + 1].line - 1) : (toks.last?.line ?? out[k].line)
        }
        return out
    }

    func isDesignUnitStart(_ k: Int) -> Bool {
        let w = word(k)
        if w == "entity" && isName(k + 1) && word(k + 2) == "is" { return true }
        if w == "architecture" && isName(k + 1) && word(k + 2) == "of" { return true }
        if w == "package" && (word(k + 1) == "body" || word(k + 2) == "is") && !isOp(k - 1, ":") { return true }
        if w == "configuration" && word(k + 2) == "of" { return true }
        if (w == "library" || w == "context") && (k == 0 || isOp(k - 1, ";")) {
            // only at top level: previous statement ended a unit
            return true
        }
        return false
    }

    mutating func parseEntity() -> HDLSymbol {
        let start = toks[i]
        var s = HDLSymbol(kind: .entity, name: text(toks[i + 1]), line: start.line, endLine: -1, offset: toks[i + 1].start)
        i += 3
        while i < toks.count {
            let w = word(i)
            if (w == "generic" || w == "port") && isOp(i + 1, "(") {
                let close = matching(i + 1)
                s.children += parseVHDLInterface(i + 2, close, port: w == "port")
                i = close + 1
                continue
            }
            if w == "end" {
                s.endLine = toks[i].line
                i = findTopLevel(from: i, [";"]) + 1
                break
            }
            if isDesignUnitStart(i) { break }
            i += 1
        }
        return s
    }

    func parseVHDLInterface(_ a: Int, _ b: Int, port: Bool) -> [HDLSymbol] {
        var out: [HDLSymbol] = []
        var k = a
        while k < b {
            let itemEnd = findTopLevel(from: k, [";"], limit: b)
            let colon = findTopLevel(from: k, [":"], limit: itemEnd)
            if colon < itemEnd {
                var names: [Int] = []
                var t = k
                while t < colon { if isName(t) { names.append(t) }; t += 1 }
                var typeStart = colon + 1
                var dir: String? = nil
                if ["in", "out", "inout", "buffer", "linkage"].contains(word(typeStart)) { dir = word(typeStart); typeStart += 1 }
                let assign = (typeStart..<itemEnd).first { isOp($0, ":") && isOp($0 + 1, "=") } ?? itemEnd
                let typeText = source(typeStart, assign - 1)
                let value = assign < itemEnd ? source(assign + 2, itemEnd - 1) : nil
                for nk in names {
                    var s = HDLSymbol(kind: port ? .port : .param, name: text(toks[nk]), line: toks[nk].line, endLine: toks[nk].line, offset: toks[nk].start)
                    s.dir = port ? (dir ?? "in") : nil
                    s.dataType = typeText
                    s.value = value
                    s.detail = port ? "\(s.dir!) \(typeText)" : typeText + (value.map { " := \($0)" } ?? "")
                    out.append(s)
                }
            }
            k = itemEnd + 1
        }
        return out
    }

    mutating func parseArchitecture() -> HDLSymbol {
        let start = toks[i]
        let arch = text(toks[i + 1])
        let ent = isName(i + 3) ? text(toks[i + 3]) : "?"
        var s = HDLSymbol(kind: .architecture, name: arch, detail: "of \(ent)", line: start.line, endLine: -1, offset: toks[i + 1].start)
        s.target = ent
        i += 4
        s.children = parseVHDLBody(endUnit: true, lastEnd: &s.endLine)
        return s
    }

    mutating func parsePackage() -> HDLSymbol {
        let start = toks[i]
        let isBody = word(i + 1) == "body"
        let nameIdx = isBody ? i + 2 : i + 1
        let name = isName(nameIdx) ? text(toks[nameIdx]) : "package"
        var s = HDLSymbol(kind: .package, name: name, detail: isBody ? "body" : "", line: start.line, endLine: -1, offset: nameIdx < toks.count ? toks[nameIdx].start : start.start)
        i = nameIdx + 1
        s.children = parseVHDLBody(endUnit: true, lastEnd: &s.endLine)
        return s
    }

    /// Declarations and concurrent statements until the next design unit.
    mutating func parseVHDLBody(endUnit: Bool, lastEnd: inout Int) -> [HDLSymbol] {
        var out: [HDLSymbol] = []
        while i < toks.count {
            if isDesignUnitStart(i) { break }
            let w = word(i)
            switch w {
            case "end":
                lastEnd = toks[i].line
                i += 1
            case "signal", "constant", "shared", "variable", "file":
                if w == "variable" || w == "file" || w == "shared" {
                    i = findTopLevel(from: i, [";"]) + 1
                    continue
                }
                let end = findTopLevel(from: i, [";"])
                let colon = findTopLevel(from: i, [":"], limit: end)
                if colon < end {
                    let assign = (colon + 1..<end).first { isOp($0, ":") && isOp($0 + 1, "=") } ?? end
                    let typeText = source(colon + 1, assign - 1)
                    let value = assign < end ? source(assign + 2, end - 1) : nil
                    for nk in (i + 1)..<colon where isName(nk) {
                        var s = HDLSymbol(kind: w == "signal" ? .signal : .constant, name: text(toks[nk]), detail: typeText + (value.map { " := \($0)" } ?? ""), line: toks[nk].line, endLine: toks[nk].line, offset: toks[nk].start)
                        s.dataType = typeText
                        s.value = value
                        out.append(s)
                    }
                }
                i = end + 1
            case "type", "subtype":
                if isName(i + 1) {
                    let end = findTopLevel(from: i, [";"])
                    out.append(HDLSymbol(kind: .type, name: text(toks[i + 1]), detail: source(i + 2, min(end - 1, i + 6)), line: toks[i].line, endLine: end < toks.count ? toks[end].line : toks[i].line, offset: toks[i + 1].start))
                    // skip records/protected bodies
                    if word(i + 3) == "record" || word(i + 3) == "protected" {
                        var k = i + 3
                        while k < toks.count && !(word(k) == "end" && (word(k + 1) == "record" || word(k + 1) == "protected")) { k += 1 }
                        i = findTopLevel(from: k, [";"]) + 1
                    } else {
                        i = end + 1
                    }
                } else { i += 1 }
            case "component":
                guard isName(i + 1) else { i += 1; continue }
                var c = HDLSymbol(kind: .component, name: text(toks[i + 1]), line: toks[i].line, endLine: toks[i].line, offset: toks[i + 1].start)
                var k = i + 2
                while k < toks.count && !(word(k) == "end" && word(k + 1) == "component") {
                    if (word(k) == "port" || word(k) == "generic") && isOp(k + 1, "(") {
                        let close = matching(k + 1)
                        c.children += parseVHDLInterface(k + 2, close, port: word(k) == "port")
                        k = close
                    }
                    k += 1
                }
                c.endLine = k < toks.count ? toks[k].line : c.line
                out.append(c)
                i = findTopLevel(from: k, [";"]) + 1
            case "function", "procedure", "impure", "pure":
                var k = i
                if w == "impure" || w == "pure" { k += 1 }
                guard isName(k + 1) else { i += 1; continue }
                var f = HDLSymbol(kind: .function, name: text(toks[k + 1]), detail: word(k), line: toks[i].line, endLine: toks[i].line, offset: toks[k + 1].start)
                // declaration only?
                var j = k + 2
                if isOp(j, "(") { let c = matching(j); f.detail = word(k) + "(" + source(j + 1, c - 1) + ")"; j = c + 1 }
                while j < toks.count && !isOp(j, ";") && word(j) != "is" { j += 1 }
                if word(j) == "is" {
                    // body until "end function|procedure|name"
                    var depth = 0
                    var e = j + 1
                    while e < toks.count {
                        let we = word(e)
                        if we == "begin" { depth += 1 }
                        if we == "end" {
                            let n1 = word(e + 1)
                            if n1 == "function" || n1 == "procedure" || n1 == f.name.lowercased() || (isOp(e + 1, ";") && depth <= 1) {
                                break
                            }
                            if n1 != "if" && n1 != "loop" && n1 != "case" && n1 != "record" { depth = max(0, depth - 1) }
                        }
                        if isDesignUnitStart(e) { e -= 1; break }
                        e += 1
                    }
                    f.endLine = e < toks.count ? toks[e].line : f.line
                    i = findTopLevel(from: e, [";"]) + 1
                } else {
                    i = j + 1
                }
                out.append(f)
            case "process":
                out.append(parseVHDLProcess(label: nil, at: i))
            default:
                // label : ...
                if isName(i), isOp(i + 1, ":"), !isOp(i + 2, "=") {
                    let label = text(toks[i])
                    let labelIdx = i
                    let w2 = word(i + 2)
                    if w2 == "process" || (w2 == "postponed" && word(i + 3) == "process") {
                        out.append(parseVHDLProcess(label: label, at: w2 == "process" ? i + 2 : i + 3))
                        continue
                    }
                    if w2 == "entity" {
                        // label : entity work.foo(arch)
                        var k = i + 3
                        var target = ""
                        while k < toks.count && !isOp(k, ";") && word(k) != "port" && word(k) != "generic" {
                            if isName(k) { target = text(toks[k]) }
                            if isOp(k, "(") { break }
                            k += 1
                        }
                        out.append(vhdlInstance(label, labelIdx, target: target))
                        continue
                    }
                    if w2 == "component" && isName(i + 3) {
                        out.append(vhdlInstance(label, labelIdx, target: text(toks[i + 3])))
                        continue
                    }
                    if isName(i + 2) && (word(i + 3) == "port" || word(i + 3) == "generic") {
                        out.append(vhdlInstance(label, labelIdx, target: text(toks[i + 2])))
                        continue
                    }
                    if w2 == "for" || w2 == "if" || w2 == "case" {
                        // generate statement label: keep scanning inside
                        let gen = findTopLevel(from: i, [";"])
                        var g = HDLSymbol(kind: .block, name: label, detail: "\(w2) generate", line: toks[i].line, endLine: toks[i].line, offset: toks[i].start)
                        g.endLine = toks[min(gen, toks.count - 1)].line
                        i += 3
                        _ = g
                        continue
                    }
                    if w2 == "block" {
                        i += 3
                        continue
                    }
                }
                i += 1
            }
        }
        return out
    }

    mutating func vhdlInstance(_ label: String, _ labelIdx: Int, target: String) -> HDLSymbol {
        var s = HDLSymbol(kind: .instance, name: label, detail: target, line: toks[labelIdx].line, endLine: toks[labelIdx].line, offset: toks[labelIdx].start)
        s.target = target
        // port map (a => b, ...)
        var k = labelIdx + 2
        let end = findTopLevel(from: k, [";"])
        while k < end {
            if word(k) == "map" && isOp(k + 1, "(") {
                let close = matching(k + 1)
                let isPort = word(k - 1) == "port"
                if isPort {
                    var c = k + 2
                    while c < close {
                        if isName(c) && isOp(c + 1, "=") && isOp(c + 2, ">") {
                            let itemEnd = findTopLevel(from: c, [","], limit: close)
                            var p = HDLSymbol(kind: .port, name: text(toks[c]), detail: source(c + 3, itemEnd - 1), line: toks[c].line, endLine: toks[c].line, offset: toks[c].start)
                            p.dir = nil
                            s.children.append(p)
                            c = itemEnd
                        }
                        c += 1
                    }
                }
                k = close
            }
            k += 1
        }
        s.endLine = end < toks.count ? toks[end].line : s.line
        i = end + 1
        return s
    }

    mutating func parseVHDLProcess(label: String?, at k: Int) -> HDLSymbol {
        var j = k + 1
        var sens = ""
        if isOp(j, "(") {
            let c = matching(j)
            sens = source(j + 1, c - 1)
            j = c + 1
        }
        let detail = "process" + (sens.isEmpty ? "" : " (\(sens))")
        let startIdx = label != nil ? k - 2 : k
        var s = HDLSymbol(kind: .process, name: label ?? detail, detail: label != nil ? detail : "", line: toks[startIdx].line, endLine: toks[k].line, offset: toks[startIdx].start)
        s.dataType = "process"
        while j < toks.count && !(word(j) == "end" && (word(j + 1) == "process" || (word(j + 1) == "postponed" && word(j + 2) == "process"))) {
            if isDesignUnitStart(j) { break }
            j += 1
        }
        s.endLine = j < toks.count ? toks[j].line : s.line
        i = findTopLevel(from: j, [";"]) + 1
        return s
    }
}
