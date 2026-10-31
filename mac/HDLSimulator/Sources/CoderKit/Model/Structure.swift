import Foundation

/// Block structure: matching `begin`/`end`, brackets, and indentation rules.
enum Structure {
    static let verilogOpeners: [String: Set<String>] = [
        "begin": ["end"], "case": ["endcase"], "casez": ["endcase"], "casex": ["endcase"], "randcase": ["endcase"],
        "module": ["endmodule"], "macromodule": ["endmodule"], "function": ["endfunction"], "task": ["endtask"],
        "fork": ["join", "join_any", "join_none"], "generate": ["endgenerate"], "class": ["endclass"],
        "interface": ["endinterface"], "package": ["endpackage"], "program": ["endprogram"],
        "covergroup": ["endgroup"], "property": ["endproperty"], "sequence": ["endsequence"],
        "clocking": ["endclocking"], "specify": ["endspecify"], "primitive": ["endprimitive"],
        "table": ["endtable"], "config": ["endconfig"], "checker": ["endchecker"],
    ]
    static let verilogClosers: Set<String> = Set(verilogOpeners.values.flatMap { $0 })
    /// Openers whose body begins after the header's `;`.
    static let headerOpeners: Set<String> = [
        "module", "macromodule", "function", "task", "class", "interface", "package", "program", "checker",
        "primitive", "covergroup", "property", "sequence", "clocking", "config",
    ]
    static let singleStatementHeads: Set<String> = ["if", "for", "while", "repeat", "foreach", "@", "always", "initial", "forever", "else", "always_ff", "always_comb", "always_latch", "final", "do"]

    /// Word of a keyword-ish token, nil for others.
    static func word(_ u: [UInt16], _ t: Token) -> String? {
        switch t.kind {
        case .keyword, .control, .type: return Lexer.string(u, t)
        default: return nil
        }
    }

    /// Whether the opener keyword at significant-token index `k` really opens a block.
    static func isRealOpener(_ w: String, _ sig: [Token], _ k: Int, _ u: [UInt16]) -> Bool {
        let prev = k > 0 ? (word(u, sig[k - 1]) ?? "") : ""
        switch w {
        case "fork": return prev != "wait" && prev != "disable"
        case "class": return prev != "typedef"
        case "interface": return prev != "virtual" && !(k + 1 < sig.count && sig[k + 1].kind == .keyword && Lexer.string(u, sig[k + 1]) == "class")
        case "property", "sequence":
            return !["assert", "assume", "cover", "expect", "restrict"].contains(prev)
        case "function", "task":
            var j = k - 1
            while j >= 0 && sig[j].line >= sig[k].line - 1 {
                if sig[j].kind == .op && u[sig[j].start] == 59 { break }
                if let pw = word(u, sig[j]), ["extern", "pure", "import", "export"].contains(pw) { return false }
                if sig[j].kind == .string { return false } // import "DPI-C"
                j -= 1
            }
            return true
        default: return true
        }
    }

    /// Pairs of matching tokens (indices into `tokens`), both directions.
    static func pairs(_ tokens: [Token], _ u: [UInt16], language: HDLLanguage) -> [Int: Int] {
        var map: [Int: Int] = [:]
        var bracketStack: [(Int, UInt16)] = []
        var blockStack: [(Int, Set<String>)] = []
        let sigIdx = tokens.indices.filter { tokens[$0].kind != .comment && tokens[$0].kind != .attribute && tokens[$0].kind != .string }
        let sig = sigIdx.map { tokens[$0] }
        let verilog = language.isVerilogFamily
        for (k, t) in sig.enumerated() {
            let ti = sigIdx[k]
            if t.kind == .op {
                let c = u[t.start]
                if c == 40 || c == 91 || c == 123 {
                    bracketStack.append((ti, c == 40 ? 41 : (c == 91 ? 93 : 125)))
                } else if c == 41 || c == 93 || c == 125 {
                    if let idx = bracketStack.lastIndex(where: { $0.1 == c }) {
                        map[ti] = bracketStack[idx].0
                        map[bracketStack[idx].0] = ti
                        bracketStack.removeSubrange(idx...)
                    }
                }
                continue
            }
            guard verilog, let w = word(u, t) else { continue }
            if let closers = verilogOpeners[w] {
                if isRealOpener(w, sig, k, u) { blockStack.append((ti, closers)) }
            } else if verilogClosers.contains(w) {
                if let idx = blockStack.lastIndex(where: { $0.1.contains(w) }) {
                    map[ti] = blockStack[idx].0
                    map[blockStack[idx].0] = ti
                    blockStack.removeSubrange(idx...)
                }
            }
        }
        return map
    }

    /// Line start offsets (UTF-16).
    static func lineStarts(_ u: [UInt16]) -> [Int] {
        var starts = [0]
        starts.reserveCapacity(u.count / 30 + 1)
        for (i, c) in u.enumerated() where c == 10 { starts.append(i + 1) }
        return starts
    }

    /// Indentation level for every line (nil = leave unchanged). Verilog/SystemVerilog only.
    static func indentLevels(_ u: [UInt16], _ tokens: [Token], language: HDLLanguage) -> [Int?] {
        let lineCount = lineStarts(u).count
        var levels = [Int?](repeating: nil, count: lineCount)
        guard language.isVerilogFamily else { return levels }
        let pairMap = pairs(tokens, u, language: language)
        var depth = 0
        var paren = 0
        var pendingHeader = false
        // Extra indentation of statements under `if (...)`, `else`, `always @(...)` without begin.
        var extra = 0
        var pendingExtra: Int? = nil
        // For each open block: the extra indentation its statements start at.
        var blockExtra: [Int] = []
        var ifLevel: [Int: Int] = [:]

        // Lines inside multi-line comments and strings keep their indentation.
        var protected = Set<Int>()
        for t in tokens where (t.kind == .comment || t.kind == .string) && t.length > 0 {
            var endLine = t.line
            for k in 0..<t.length where u[t.start + k] == 10 { endLine += 1 }
            if endLine > t.line { for l in (t.line + 1)...endLine { protected.insert(l) } }
        }
        var lineTokens: [[Int]] = Array(repeating: [], count: lineCount)
        for (i, t) in tokens.enumerated() where t.line < lineCount { lineTokens[t.line].append(i) }

        for line in 0..<lineCount {
            let idxs = lineTokens[line].filter { tokens[$0].kind != .comment || tokens[$0].line == line }
            if let p = pendingExtra { extra = p; pendingExtra = nil }
            if protected.contains(line) { continue }
            guard let firstIdx = idxs.first else {
                levels[line] = 0
                continue
            }
            let first = tokens[firstIdx]
            let base = depth + paren
            let fw = word(u, first) ?? ""
            let underHead = extra > (blockExtra.last ?? 0)
            var lineLevel = base + extra
            if first.kind == .op, [41, 93, 125].contains(u[first.start]) {
                lineLevel -= 1
            } else if verilogClosers.contains(fw), pairMap[firstIdx] != nil {
                lineLevel = depth - 1 + paren + (blockExtra.last ?? 0)
            } else if (fw == "begin" || fw == "fork") && underHead {
                lineLevel -= 1
            } else if fw == "else", let l = ifLevel[depth] {
                lineLevel = l
            }
            if first.kind == .directive, ["`ifdef", "`ifndef", "`else", "`elsif", "`endif", "`define", "`include", "`timescale", "`default_nettype", "`undef", "`resetall"].contains(Lexer.string(u, first)) {
                lineLevel = 0
            }
            lineLevel = max(0, lineLevel)
            levels[line] = lineLevel
            if fw == "if" || (fw == "else" && idxs.count > 1 && word(u, tokens[idxs[1]]) == "if") { ifLevel[depth] = lineLevel }

            var lastSig: Int? = nil
            for ti in idxs {
                let t = tokens[ti]
                if t.kind == .comment || t.kind == .attribute { continue }
                lastSig = ti
                if t.kind == .op {
                    let c = u[t.start]
                    if c == 40 || c == 91 || c == 123 { paren += 1 }
                    else if c == 41 || c == 93 || c == 125 { paren = max(0, paren - 1) }
                    else if c == 59 && paren == 0 {
                        if pendingHeader {
                            blockExtra.append(max(0, lineLevel - depth))
                            depth += 1
                            pendingHeader = false
                        }
                        extra = blockExtra.last ?? 0
                    }
                    continue
                }
                guard let w = word(u, t) else { continue }
                if verilogOpeners[w] != nil, pairMap[ti] != nil || w == "begin" || w == "fork" || w.hasPrefix("case") {
                    if headerOpeners.contains(w) {
                        pendingHeader = true
                    } else {
                        let e = max(0, lineLevel - (depth + paren))
                        blockExtra.append(e)
                        depth += 1
                        extra = e
                    }
                } else if verilogClosers.contains(w), pairMap[ti] != nil {
                    depth = max(0, depth - 1)
                    _ = blockExtra.popLast()
                    extra = blockExtra.last ?? 0
                }
            }
            // Single statement after if (...) / else / always @(...)
            if let ls = lastSig, paren == 0 {
                let t = tokens[ls]
                let w = word(u, t) ?? ""
                var head = false
                if ["else", "always", "initial", "forever", "always_comb", "always_latch", "final", "do"].contains(w) {
                    head = true
                } else if t.kind == .op && u[t.start] == 41, let open = pairMap[ls], open > 0 {
                    var p = open - 1
                    while p >= 0 && tokens[p].kind == .comment { p -= 1 }
                    if p >= 0 {
                        let pt = tokens[p]
                        let pw = word(u, pt) ?? (pt.kind == .op && u[pt.start] == 64 ? "@" : "")
                        if ["if", "for", "while", "repeat", "foreach", "@"].contains(pw) { head = true }
                    }
                } else if t.kind == .op && u[t.start] == 42, ls > 0, tokens[ls - 1].kind == .op, u[tokens[ls - 1].start] == 64 {
                    head = true   // always @*
                }
                if head { pendingExtra = lineLevel - (depth + paren) + 1 }
            }
        }
        return levels
    }
}

/// Text helpers working on NSString ranges.
enum TextUtil {
    static func leadingWhitespace(_ s: String) -> String {
        String(s.prefix { $0 == " " || $0 == "\t" })
    }

    /// Visual width of an indentation string.
    static func indentWidth(_ s: String, tabSize: Int) -> Int {
        var w = 0
        for c in s {
            if c == "\t" { w += tabSize - (w % tabSize) } else if c == " " { w += 1 } else { break }
        }
        return w
    }

    static func makeIndent(_ width: Int, tabSize: Int, useSpaces: Bool) -> String {
        guard width > 0 else { return "" }
        if useSpaces { return String(repeating: " ", count: width) }
        return String(repeating: "\t", count: width / tabSize) + String(repeating: " ", count: width % tabSize)
    }

    /// Code part of a line with any trailing // or -- comment removed (ignores comment markers inside strings).
    static func stripComment(_ line: String, language: HDLLanguage) -> String {
        guard let marker = language.lineComment else { return line }
        var inString = false
        let chars = Array(line)
        let m = Array(marker)
        var i = 0
        while i < chars.count {
            if chars[i] == "\"" { inString.toggle() }
            if !inString && i + 1 < chars.count && chars[i] == m[0] && chars[i + 1] == m[1] {
                return String(chars[..<i])
            }
            if !inString && language.isVerilogFamily && i + 1 < chars.count && chars[i] == "/" && chars[i + 1] == "*" {
                return String(chars[..<i])
            }
            i += 1
        }
        return line
    }

    static func lastWord(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        var out = ""
        for c in t.reversed() {
            if c.isLetter || c.isNumber || c == "_" { out.insert(c, at: out.startIndex) } else { break }
        }
        return out
    }

    static func firstWord(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return String(t.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "`" })
    }

    /// Should the line after `code` be indented one level more?
    static func increasesIndent(_ code: String, language: HDLLanguage) -> Bool {
        let t = code.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        let last = t.last!
        if "([{".contains(last) { return true }
        if language == .vhdl {
            let lw = lastWord(t).lowercased()
            if ["is", "begin", "then", "else", "loop", "generate", "record", "process", "protected", "units"].contains(lw) && !t.hasSuffix(";") { return true }
            if t.hasSuffix("=>") && t.lowercased().hasPrefix("when") { return true }
            let lower = t.lowercased()
            if t.hasSuffix(")") && (lower.hasPrefix("process") || lower.contains(": process") || lower.contains(":process")) { return true }
            return false
        }
        let lw = lastWord(t)
        let fw = firstWord(t)
        if ["begin", "fork", "generate", "specify", "else", "do", "forever", "initial", "always", "always_comb", "always_latch", "final", "table"].contains(lw) && last != ";" { return true }
        if ["case", "casez", "casex", "randcase"].contains(fw) && last == ")" { return true }
        if (fw == "unique" || fw == "priority") && t.contains("case") && last == ")" { return true }
        if Structure.headerOpeners.contains(fw) && last == ";" && fw != "property" && fw != "sequence" { return true }
        if ["virtual", "static", "automatic", "pure", "extern"].contains(fw) && last == ";" && (t.contains("class ") || t.contains("function ") || t.contains("task ")) && !t.contains("extern") && !t.contains("pure") { return true }
        if last == ")" && ["if", "for", "while", "repeat", "foreach", "always", "always_ff", "always_latch", "else"].contains(fw) { return true }
        if last == ")" && t.hasPrefix("end else if") { return true }
        if fw == "always" && t.hasSuffix("@*") { return true }
        return false
    }

    /// Is this a header line that takes a single statement without begin (if (...) / else / always @(...))?
    static func isSingleStatementHead(_ code: String) -> Bool {
        let t = code.trimmingCharacters(in: .whitespaces)
        guard let last = t.last, last != ";" && !t.hasSuffix("begin") else { return false }
        let fw = firstWord(t)
        if ["if", "for", "while", "repeat", "foreach", "always", "always_ff", "always_latch", "always_comb", "initial", "forever", "final"].contains(fw) { return true }
        if fw == "else" || t.hasPrefix("end else") { return true }
        return false
    }
}
