import Foundation

enum HDLLanguage: String, Codable, CaseIterable, Identifiable {
    case verilog, systemVerilog, vhdl, plain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .verilog: return "Verilog"
        case .systemVerilog: return "SystemVerilog"
        case .vhdl: return "VHDL"
        case .plain: return "Plain Text"
        }
    }

    var isVerilogFamily: Bool { self == .verilog || self == .systemVerilog }

    var lineComment: String? {
        switch self {
        case .verilog, .systemVerilog: return "//"
        case .vhdl: return "--"
        case .plain: return nil
        }
    }

    var icon: String {
        switch self {
        case .verilog, .systemVerilog: return "chevron.left.forwardslash.chevron.right"
        case .vhdl: return "curlybraces"
        case .plain: return "doc.text"
        }
    }

    static func detect(_ url: URL?) -> HDLLanguage {
        guard let ext = url?.pathExtension.lowercased() else { return .verilog }
        switch ext {
        case "v", "vh", "vlog", "verilog", "vg": return .verilog
        case "sv", "svh", "svi", "svp": return .systemVerilog
        case "vhd", "vhdl", "vho", "vht": return .vhdl
        default: return .plain
        }
    }

    static let hdlExtensions: Set<String> = ["v", "vh", "sv", "svh", "vhd", "vhdl", "vlog", "verilog", "vg", "svi", "vho", "vht"]
}

enum TokKind: UInt8 {
    case keyword, control, type, comment, string, number, system, directive, attribute, ident, op, placeholder, typeName, funcName
}

struct Token {
    var kind: TokKind
    var start: Int      // UTF-16 offset
    var length: Int
    var line: Int       // 0-based
    var end: Int { start + length }
}

enum Keywords {
    static let verilogControl: Set<String> = [
        "if", "else", "case", "casez", "casex", "endcase", "for", "while", "repeat", "forever", "do", "foreach",
        "return", "break", "continue", "default", "wait", "disable", "fork", "join", "join_any", "join_none",
        "unique", "unique0", "priority", "randcase", "iff", "inside",
    ]

    static let verilogTypes: Set<String> = [
        "wire", "reg", "logic", "bit", "byte", "int", "integer", "shortint", "longint", "real", "realtime", "shortreal",
        "time", "string", "signed", "unsigned", "tri", "tri0", "tri1", "triand", "trior", "trireg", "wand", "wor",
        "supply0", "supply1", "uwire", "genvar", "void", "chandle", "event", "enum", "struct", "union", "packed", "var",
        "parameter", "localparam", "defparam", "specparam", "const", "type",
    ]

    static let verilogKeywords: Set<String> = [
        "module", "endmodule", "macromodule", "input", "output", "inout", "ref", "assign", "deassign", "force", "release",
        "always", "always_ff", "always_comb", "always_latch", "initial", "final", "begin", "end", "posedge", "negedge",
        "edge", "or", "and", "nand", "nor", "xor", "xnor", "not", "buf", "bufif0", "bufif1", "notif0", "notif1",
        "function", "endfunction", "task", "endtask", "automatic", "static", "generate", "endgenerate",
        "primitive", "endprimitive", "table", "endtable", "specify", "endspecify", "config", "endconfig",
        "library", "design", "instance", "cell", "use", "liblist", "include", "pullup", "pulldown", "scalared", "vectored",
        "small", "medium", "large", "strong0", "strong1", "pull0", "pull1", "weak0", "weak1", "highz0", "highz1",
        "interface", "endinterface", "modport", "package", "endpackage", "import", "export", "typedef", "class",
        "endclass", "extends", "implements", "virtual", "pure", "extern", "new", "this", "super", "null", "local",
        "protected", "rand", "randc", "constraint", "solve", "before", "with", "program", "endprogram", "clocking",
        "endclocking", "covergroup", "endgroup", "coverpoint", "cross", "bins", "illegal_bins", "ignore_bins",
        "property", "endproperty", "sequence", "endsequence", "assert", "assume", "cover", "expect", "restrict",
        "checker", "endchecker", "let", "alias", "bind", "context", "timeunit", "timeprecision", "nettype",
        "interconnect", "soft", "matches", "tagged", "within", "throughout", "intersect", "first_match", "dist",
        "global", "s_always", "s_eventually", "eventually", "nexttime", "s_nexttime", "until", "s_until",
        "until_with", "s_until_with", "implies", "accept_on", "reject_on", "sync_accept_on", "sync_reject_on",
        "strong", "weak", "untyped", "forkjoin", "randomize", "randsequence", "wait_order", "triggered",
        "genvar_unused", "highz", "rtran", "rtranif0", "rtranif1", "tran", "tranif0", "tranif1", "cmos", "rcmos",
        "nmos", "pmos", "rnmos", "rpmos", "showcancelled", "noshowcancelled", "pulsestyle_onevent",
        "pulsestyle_ondetect", "ifnone", "endtable_unused",
    ]

    static let verilogAll: Set<String> = verilogKeywords.union(verilogTypes).union(verilogControl)

    static let vhdlControl: Set<String> = [
        "if", "then", "else", "elsif", "case", "when", "loop", "for", "while", "exit", "next", "return", "wait",
        "until", "others", "select", "after", "report", "severity", "assert",
    ]

    static let vhdlTypes: Set<String> = [
        "std_logic", "std_ulogic", "std_logic_vector", "std_ulogic_vector", "bit", "bit_vector", "boolean",
        "integer", "natural", "positive", "real", "time", "string", "character", "signed", "unsigned", "line",
        "text", "severity_level", "file_open_kind", "delay_length", "sfixed", "ufixed", "float", "unresolved_signed",
        "unresolved_unsigned", "u_signed", "u_unsigned", "boolean_vector", "integer_vector", "real_vector", "time_vector",
    ]

    static let vhdlKeywords: Set<String> = [
        "abs", "access", "alias", "all", "and", "architecture", "array", "attribute", "begin", "block", "body",
        "buffer", "bus", "component", "configuration", "constant", "disconnect", "downto", "end", "entity", "file",
        "function", "generate", "generic", "group", "guarded", "impure", "in", "inertial", "inout", "is", "label",
        "library", "linkage", "literal", "map", "mod", "nand", "new", "nor", "not", "null", "of", "on", "open", "or",
        "out", "package", "port", "postponed", "procedure", "process", "pure", "range", "record", "register",
        "reject", "rem", "return", "rol", "ror", "shared", "signal", "sla", "sll", "sra", "srl", "subtype", "to",
        "transport", "type", "units", "use", "variable", "xnor", "xor", "context", "force", "release", "parameter",
        "protected", "sequence", "property", "vunit", "vmode", "vprop", "default", "fairness", "strong", "assume",
        "cover", "restrict",
    ]

    static let vhdlAll: Set<String> = vhdlKeywords.union(vhdlControl)

    static let systemTasks: [String] = [
        "$display", "$write", "$strobe", "$monitor", "$monitoron", "$monitoroff", "$displayb", "$displayh", "$displayo",
        "$finish", "$stop", "$time", "$stime", "$realtime", "$random", "$urandom", "$urandom_range", "$dumpfile",
        "$dumpvars", "$dumpon", "$dumpoff", "$dumpall", "$dumpflush", "$readmemh", "$readmemb", "$writememh",
        "$writememb", "$fopen", "$fclose", "$fdisplay", "$fwrite", "$fscanf", "$sscanf", "$fgets", "$feof",
        "$signed", "$unsigned", "$clog2", "$bits", "$size", "$high", "$low", "$left", "$right", "$increment",
        "$countones", "$onehot", "$onehot0", "$isunknown", "$rose", "$fell", "$stable", "$past", "$changed",
        "$error", "$warning", "$info", "$fatal", "$sformatf", "$sformat", "$itor", "$rtoi", "$realtobits",
        "$bitstoreal", "$timeformat", "$printtimescale", "$value$plusargs", "$test$plusargs", "$cast", "$floor",
        "$ceil", "$sqrt", "$pow", "$ln", "$log10", "$exp", "$sin", "$cos", "$abs", "$shortrealtobits",
    ]

    static let directives: [String] = [
        "`timescale", "`define", "`undef", "`ifdef", "`ifndef", "`elsif", "`else", "`endif", "`include",
        "`default_nettype", "`resetall", "`celldefine", "`endcelldefine", "`line", "`pragma", "`unconnected_drive",
        "`nounconnected_drive", "`begin_keywords", "`end_keywords", "`__FILE__", "`__LINE__",
    ]
}

enum Lexer {
    @inline(__always) static func isIdStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }
    @inline(__always) static func isIdChar(_ c: UInt16) -> Bool {
        isIdStart(c) || (c >= 48 && c <= 57) || c == 36
    }
    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) static func isHexish(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) || c == 95 || c == 120 || c == 88 || c == 122 || c == 90 || c == 63
    }
    @inline(__always) static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 || c == 12 }

    static func lex(_ text: String, language: HDLLanguage) -> [Token] {
        lex(Array(text.utf16), language: language)
    }

    static func lex(_ u: [UInt16], language: HDLLanguage) -> [Token] {
        switch language {
        case .vhdl: return lexVHDL(u)
        case .plain: return []
        default: return lexVerilog(u, sv: language == .systemVerilog)
        }
    }

    static func string(_ u: [UInt16], _ t: Token) -> String {
        String(utf16CodeUnits: Array(u[t.start..<t.end]), count: t.length)
    }

    // MARK: Verilog / SystemVerilog

    static func lexVerilog(_ u: [UInt16], sv: Bool) -> [Token] {
        var toks: [Token] = []
        toks.reserveCapacity(u.count / 4)
        let n = u.count
        var i = 0
        var line = 0

        func add(_ k: TokKind, _ s: Int, _ e: Int, _ l: Int) { toks.append(Token(kind: k, start: s, length: e - s, line: l)) }

        while i < n {
            let c = u[i]
            if c == 10 { line += 1; i += 1; continue }
            if isSpace(c) { i += 1; continue }
            let start = i
            let startLine = line
            // Comments
            if c == 47 /* / */ && i + 1 < n {
                if u[i + 1] == 47 {
                    while i < n && u[i] != 10 { i += 1 }
                    add(.comment, start, i, startLine)
                    continue
                }
                if u[i + 1] == 42 {
                    i += 2
                    while i < n && !(u[i] == 42 && i + 1 < n && u[i + 1] == 47) {
                        if u[i] == 10 { line += 1 }
                        i += 1
                    }
                    i = min(n, i + 2)
                    add(.comment, start, i, startLine)
                    continue
                }
            }
            // Attribute (* ... *), but not @(*)
            if c == 40 && i + 1 < n && u[i + 1] == 42 && !(i + 2 < n && u[i + 2] == 41) {
                var j = i + 2
                var ok = false
                while j + 1 < n && u[j] != 10 {
                    if u[j] == 42 && u[j + 1] == 41 { ok = true; break }
                    j += 1
                }
                if ok && j > i + 2 {
                    i = j + 2
                    add(.attribute, start, i, startLine)
                    continue
                }
            }
            // Placeholder <#name#>
            if c == 60 && i + 1 < n && u[i + 1] == 35 {
                var j = i + 2
                while j + 1 < n && u[j] != 10 && !(u[j] == 35 && u[j + 1] == 62) { j += 1 }
                if j + 1 < n && u[j] == 35 && u[j + 1] == 62 {
                    i = j + 2
                    add(.placeholder, start, i, startLine)
                    continue
                }
            }
            // String
            if c == 34 {
                i += 1
                while i < n && u[i] != 34 && u[i] != 10 {
                    if u[i] == 92 { i += 1 }
                    i += 1
                }
                i = min(n, i + 1)
                add(.string, start, i, startLine)
                continue
            }
            // Directive
            if c == 96 {
                i += 1
                while i < n && isIdChar(u[i]) { i += 1 }
                add(.directive, start, i, startLine)
                continue
            }
            // System task
            if c == 36 && i + 1 < n && isIdStart(u[i + 1]) {
                i += 1
                while i < n && isIdChar(u[i]) { i += 1 }
                add(.system, start, i, startLine)
                continue
            }
            // Numbers: 12, 8'hFF, 'b101, 1.5e3, 10ns, '0
            if isDigit(c) || (c == 39 && i + 1 < n && (isBase(u[i + 1]) || u[i + 1] == 48 || u[i + 1] == 49 || u[i + 1] == 120 || u[i + 1] == 122 || u[i + 1] == 88 || u[i + 1] == 90 || u[i + 1] == 115 || u[i + 1] == 83)) {
                if isDigit(c) {
                    while i < n && (isDigit(u[i]) || u[i] == 95) { i += 1 }
                    if i + 1 < n && u[i] == 46 && isDigit(u[i + 1]) {
                        i += 1
                        while i < n && (isDigit(u[i]) || u[i] == 95) { i += 1 }
                    }
                    if i < n && (u[i] == 101 || u[i] == 69), i + 1 < n, isDigit(u[i + 1]) || ((u[i + 1] == 45 || u[i + 1] == 43) && i + 2 < n && isDigit(u[i + 2])) {
                        i += 2
                        while i < n && isDigit(u[i]) { i += 1 }
                    }
                    // time units
                    if i + 1 < n, [115, 109, 117, 110, 112, 102].contains(u[i]), u[i + 1] == 115, !(i + 2 < n && isIdChar(u[i + 2])) {
                        i += 2
                    } else if i < n, u[i] == 115, !(i + 1 < n && isIdChar(u[i + 1])) {
                        i += 1
                    }
                    // skip spaces before a base: 8 'hFF
                    var j = i
                    while j < n && (u[j] == 32 || u[j] == 9) { j += 1 }
                    if j < n && u[j] == 39 { i = j }
                }
                if i < n && u[i] == 39 {
                    i += 1
                    if i < n && (u[i] == 115 || u[i] == 83) { i += 1 }
                    if i < n && isBase(u[i]) {
                        i += 1
                        while i < n && (u[i] == 32 || u[i] == 9) { i += 1 }
                        while i < n && isHexish(u[i]) { i += 1 }
                    } else if i < n && (u[i] == 48 || u[i] == 49 || u[i] == 120 || u[i] == 88 || u[i] == 122 || u[i] == 90) {
                        i += 1
                    }
                }
                add(.number, start, i, startLine)
                continue
            }
            // Identifiers and keywords
            if isIdStart(c) {
                i += 1
                while i < n && isIdChar(u[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(u[start..<i]), count: i - start)
                let kind: TokKind
                if Keywords.verilogControl.contains(word) { kind = .control }
                else if Keywords.verilogTypes.contains(word) { kind = .type }
                else if Keywords.verilogKeywords.contains(word) { kind = .keyword }
                else { kind = .ident }
                add(kind, start, i, startLine)
                continue
            }
            // Escaped identifier
            if c == 92 {
                i += 1
                while i < n && !isSpace(u[i]) && u[i] != 10 { i += 1 }
                add(.ident, start, i, startLine)
                continue
            }
            // Operators / punctuation, one char each
            i += 1
            add(.op, start, i, startLine)
        }
        markNames(&toks, u, vhdl: false)
        return toks
    }

    @inline(__always) static func isBase(_ c: UInt16) -> Bool {
        c == 98 || c == 66 || c == 111 || c == 79 || c == 100 || c == 68 || c == 104 || c == 72
    }

    // MARK: VHDL

    static func lexVHDL(_ u: [UInt16]) -> [Token] {
        var toks: [Token] = []
        toks.reserveCapacity(u.count / 4)
        let n = u.count
        var i = 0
        var line = 0
        func add(_ k: TokKind, _ s: Int, _ e: Int, _ l: Int) { toks.append(Token(kind: k, start: s, length: e - s, line: l)) }

        while i < n {
            let c = u[i]
            if c == 10 { line += 1; i += 1; continue }
            if isSpace(c) { i += 1; continue }
            let start = i
            let startLine = line
            if c == 45 && i + 1 < n && u[i + 1] == 45 {
                while i < n && u[i] != 10 { i += 1 }
                add(.comment, start, i, startLine)
                continue
            }
            if c == 47 && i + 1 < n && u[i + 1] == 42 {
                i += 2
                while i < n && !(u[i] == 42 && i + 1 < n && u[i + 1] == 47) {
                    if u[i] == 10 { line += 1 }
                    i += 1
                }
                i = min(n, i + 2)
                add(.comment, start, i, startLine)
                continue
            }
            if c == 60 && i + 1 < n && u[i + 1] == 35 {
                var j = i + 2
                while j + 1 < n && u[j] != 10 && !(u[j] == 35 && u[j + 1] == 62) { j += 1 }
                if j + 1 < n && u[j] == 35 && u[j + 1] == 62 {
                    i = j + 2
                    add(.placeholder, start, i, startLine)
                    continue
                }
            }
            if c == 34 {
                i += 1
                while i < n && u[i] != 10 {
                    if u[i] == 34 {
                        if i + 1 < n && u[i + 1] == 34 { i += 2; continue }
                        break
                    }
                    i += 1
                }
                i = min(n, i + 1)
                add(.string, start, i, startLine)
                continue
            }
            if c == 39 {
                let prev = toks.last
                let afterName = prev.map { ($0.kind == .ident || $0.kind == .type || ($0.kind == .op && (u[$0.start] == 41 || u[$0.start] == 93))) && $0.end == i } ?? false
                if !afterName && i + 2 < n && u[i + 2] == 39 {
                    i += 3
                    add(.string, start, i, startLine)
                    continue
                }
                if afterName && i + 1 < n && isIdStart(u[i + 1]) {
                    i += 1
                    while i < n && isIdChar(u[i]) && u[i] != 36 { i += 1 }
                    add(.system, start, i, startLine)
                    continue
                }
            }
            if isDigit(c) {
                while i < n && (isDigit(u[i]) || u[i] == 95) { i += 1 }
                if i < n && u[i] == 35 {
                    i += 1
                    while i < n && u[i] != 35 && u[i] != 10 && (isHexish(u[i]) || u[i] == 46) { i += 1 }
                    if i < n && u[i] == 35 { i += 1 }
                } else {
                    if i + 1 < n && u[i] == 46 && isDigit(u[i + 1]) {
                        i += 1
                        while i < n && (isDigit(u[i]) || u[i] == 95) { i += 1 }
                    }
                    if i < n && (u[i] == 101 || u[i] == 69), i + 1 < n, isDigit(u[i + 1]) || u[i + 1] == 45 || u[i + 1] == 43 {
                        i += 2
                        while i < n && isDigit(u[i]) { i += 1 }
                    }
                    // sized bit string 8x"FF"
                    if i + 1 < n, [98, 66, 111, 79, 120, 88, 100, 68].contains(u[i]), u[i + 1] == 34 {
                        i += 2
                        while i < n && u[i] != 34 && u[i] != 10 { i += 1 }
                        i = min(n, i + 1)
                    }
                }
                add(.number, start, i, startLine)
                continue
            }
            if isIdStart(c) {
                // bit string literal x"FF", b"0101", ux"..", sx".."
                var j = i
                if j + 1 < n, [117, 85, 115, 83].contains(u[j]), [98, 66, 111, 79, 120, 88].contains(u[j + 1]), j + 2 < n, u[j + 2] == 34 { j += 1 }
                if j + 1 < n, [98, 66, 111, 79, 120, 88, 100, 68].contains(u[j]), u[j + 1] == 34, j == i || j == i + 1 {
                    i = j + 2
                    while i < n && u[i] != 34 && u[i] != 10 { i += 1 }
                    i = min(n, i + 1)
                    add(.number, start, i, startLine)
                    continue
                }
                i += 1
                while i < n && isIdChar(u[i]) && u[i] != 36 { i += 1 }
                let word = String(utf16CodeUnits: Array(u[start..<i]), count: i - start).lowercased()
                let kind: TokKind
                if Keywords.vhdlControl.contains(word) { kind = .control }
                else if Keywords.vhdlTypes.contains(word) { kind = .type }
                else if Keywords.vhdlKeywords.contains(word) { kind = .keyword }
                else if word == "true" || word == "false" { kind = .number }
                else { kind = .ident }
                add(kind, start, i, startLine)
                continue
            }
            if c == 92 {
                i += 1
                while i < n && u[i] != 92 && u[i] != 10 { i += 1 }
                i = min(n, i + 1)
                add(.ident, start, i, startLine)
                continue
            }
            i += 1
            add(.op, start, i, startLine)
        }
        markNames(&toks, u, vhdl: true)
        return toks
    }

    /// Colors declared names: module/entity names, module types of instances, function names.
    private static func markNames(_ toks: inout [Token], _ u: [UInt16], vhdl: Bool) {
        let declKeywords: Set<String> = vhdl
            ? ["entity", "architecture", "package", "component", "configuration", "body", "of"]
            : ["module", "macromodule", "interface", "program", "package", "class", "extends", "primitive", "checker"]
        let funcKeywords: Set<String> = vhdl ? ["function", "procedure"] : ["function", "task"]
        func isOp(_ t: Token?, _ ch: UInt16) -> Bool { t.map { $0.kind == .op && u[$0.start] == ch } ?? false }
        var depth = 0
        var prev: Token?
        var prev2: Token?
        var prev3: Token?
        for k in toks.indices {
            let t = toks[k]
            if t.kind == .comment || t.kind == .attribute { continue }
            if t.kind == .op {
                if u[t.start] == 40 { depth += 1 } else if u[t.start] == 41 { depth = max(0, depth - 1) }
            }
            if t.kind == .ident {
                let next = nextSig(toks, k + 1)
                let nextTok = next.map { toks[$0] }
                if let p = prev, p.kind == .keyword || p.kind == .type {
                    let w = vhdl ? string(u, p).lowercased() : string(u, p)
                    if declKeywords.contains(w) { toks[k].kind = .typeName }
                    else if funcKeywords.contains(w) { toks[k].kind = .funcName }
                } else if vhdl {
                    if isOp(prev, 46), let p3 = prev3, p3.kind == .keyword, string(u, p3).lowercased() == "entity" {
                        toks[k].kind = .typeName      // u1: entity work.foo
                    } else if isOp(prev, 58), let nt = nextTok, nt.kind == .keyword,
                              ["port", "generic"].contains(string(u, nt).lowercased()) {
                        toks[k].kind = .typeName      // u1: foo port map
                    }
                } else if depth == 0, prev?.kind != .ident, prev?.kind != .typeName, !isOp(prev, 46), let nt = nextTok {
                    if isOp(nt, 35) {
                        toks[k].kind = .typeName      // foo #(...) u (...)
                    } else if nt.kind == .ident, let n2 = nextSig(toks, next! + 1), isOp(toks[n2], 40) || isOp(toks[n2], 91) {
                        toks[k].kind = .typeName      // foo u (...)
                    } else if isOp(nt, 40) {
                        toks[k].kind = .funcName
                    }
                } else if !vhdl, let nt = nextTok, isOp(nt, 40), !isOp(prev, 46), prev?.kind != .ident, prev?.kind != .typeName {
                    toks[k].kind = .funcName          // f(x)
                }
            }
            prev3 = prev2
            prev2 = prev
            prev = toks[k]
        }
    }

    @inline(__always) private static func isDot(_ u: [UInt16], _ t: Token) -> Bool {
        t.kind == .op && u[t.start] == 46
    }

    @inline(__always) static func nextSig(_ toks: [Token], _ from: Int) -> Int? {
        var j = from
        while j < toks.count {
            if toks[j].kind != .comment && toks[j].kind != .attribute { return j }
            j += 1
        }
        return nil
    }
}

extension Array where Element == Token {
    /// Index of the token containing or starting at/after `offset`.
    func index(at offset: Int) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].end <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
