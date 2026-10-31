import AppKit

/// NSTextView with code-editor typing behavior.
final class CodeTextView: NSTextView {
    weak var controller: EditorController?

    private static let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\""]
    private static let closers: Set<Character> = [")", "]", "}"]
    private static let blockClosers: [String: String] = [
        "begin": "end", "fork": "join", "generate": "endgenerate", "case": "endcase", "casez": "endcase",
        "casex": "endcase", "randcase": "endcase", "function": "endfunction", "task": "endtask",
        "module": "endmodule", "class": "endclass", "interface": "endinterface", "package": "endpackage",
        "program": "endprogram", "specify": "endspecify", "covergroup": "endgroup", "clocking": "endclocking",
    ]

    private var ns: NSString { string as NSString }

    private func char(at i: Int) -> Character? {
        guard i >= 0 && i < ns.length else { return nil }
        guard let s = UnicodeScalar(ns.character(at: i)) else { return nil }
        return Character(s)
    }

    // MARK: Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let c = controller, !hasMarkedText(),
              let s = (string as? String) ?? (string as? NSAttributedString)?.string,
              replacementRange.location == NSNotFound else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let sel = selectedRange()
        c.typing = true
        defer { c.typing = false }

        if s.count == 1, c.settings.autoClose, let ch = s.first {
            let next = char(at: sel.location)
            // Type over an auto-inserted closer
            if sel.length == 0, (Self.closers.contains(ch) || ch == "\""), next == ch {
                if ch != "\"" || c.isInCommentOrString(sel.location) {
                    setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                    c.completion.hide()
                    return
                }
            }
            if sel.length == 0, Self.closers.contains(ch) {
                let lr = ns.lineRange(for: NSRange(location: sel.location, length: 0))
                let before = ns.substring(with: NSRange(location: lr.location, length: sel.location - lr.location))
                if before.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    var j = sel.location
                    while j < ns.length, let cj = char(at: j), cj == " " || cj == "\t" || cj == "\n" { j += 1 }
                    if j > sel.location, char(at: j) == ch, ns.substring(with: NSRange(location: sel.location, length: j - sel.location)).contains("\n") {
                        // remove the blank line and step over the existing closer
                        c.replace(NSRange(location: lr.location, length: j - lr.location), with: ns.substring(with: NSRange(location: ns.lineRange(for: NSRange(location: j, length: 0)).location, length: j - ns.lineRange(for: NSRange(location: j, length: 0)).location)),
                                  select: nil)
                        let after = ns.range(of: String(ch), options: [], range: NSRange(location: lr.location, length: ns.length - lr.location))
                        if after.location != NSNotFound { setSelectedRange(NSRange(location: NSMaxRange(after), length: 0)) }
                        c.completion.hide()
                        return
                    }
                }
            }
            if let close = Self.openers[ch], !(ch == "\"" && c.isInCommentOrString(sel.location)) {
                if sel.length > 0 && !c.selectionIsPlaceholder && ch != "\"" {
                    let inner = ns.substring(with: sel)
                    c.replace(sel, with: "\(ch)\(inner)\(close)", select: NSRange(location: sel.location + 1, length: sel.length))
                    return
                }
                let prev = char(at: sel.location - 1)
                let nextOK = next == nil || next!.isWhitespace || Self.closers.contains(next!) || next == ";" || next == "," || next == ")"
                let prevOK = ch != "\"" || prev == nil || !(prev!.isLetter || prev!.isNumber || prev == "\\" || prev == "\"")
                if sel.length == 0 && nextOK && prevOK && !(ch != "\"" && c.isInCommentOrString(sel.location)) {
                    super.insertText("\(ch)\(close)", replacementRange: replacementRange)
                    setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                    c.completion.hide()
                    return
                }
            }
        }
        super.insertText(string, replacementRange: replacementRange)
        if s.count == 1, let ch = s.first {
            afterTyping(ch)
        } else {
            c.completion.hide()
        }
    }

    private func afterTyping(_ ch: Character) {
        guard let c = controller, let lang = c.doc?.language else { return }
        let sel = selectedRange()
        let lr = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var line = ns.substring(with: lr)
        if line.hasSuffix("\n") { line.removeLast() }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lineEnd = lr.location + (line as NSString).length
        let caretAtEnd = sel.location <= lineEnd
            && ns.substring(with: NSRange(location: sel.location, length: lineEnd - sel.location)).trimmingCharacters(in: .whitespaces).isEmpty

        if ch.isLetter || ch.isNumber || ch == "_" {
            if caretAtEnd { dedentIfCloser(trimmed, lineRange: lr, line: line, lang: lang) }
            if c.settings.suggest { c.completion.update(explicit: false) }
        } else if ch == "$" || ch == "`" {
            if c.settings.suggest { c.completion.update(explicit: false) }
        } else if ch == ")" || ch == "}" || ch == "]" {
            c.completion.hide()
            if trimmed.count == 1 || trimmed == ");" { alignCloser(lineRange: lr, line: line) }
        } else if ch == "." && lang.isVerilogFamily {
            c.completion.hide()
        } else {
            c.completion.hide()
        }
    }

    /// Typing the last letter of `end`, `endcase`, … moves the line to its opener's indentation.
    private func dedentIfCloser(_ trimmed: String, lineRange lr: NSRange, line: String, lang: HDLLanguage) {
        guard let c = controller else { return }
        let lead = TextUtil.leadingWhitespace(line)
        var target: String? = nil
        if lang.isVerilogFamily {
            let word = trimmed
            if Structure.verilogClosers.contains(word) {
                c.relex()
                let off = lr.location + (lead as NSString).length
                if let k = c.tokenIndex(touching: off), let m = c.pairs[k] {
                    let openerLine = c.lineIndex(for: c.tokens[m].start)
                    target = TextUtil.leadingWhitespace(c.lineText(openerLine))
                }
            } else if word == "begin" || word == "else" {
                // `begin` on its own line after `if (...)`: line up with the `if`
                var l = c.lineIndex(for: lr.location) - 1
                while l >= 0 && c.lineText(l).trimmingCharacters(in: .whitespaces).isEmpty { l -= 1 }
                if l >= 0 {
                    let prev = c.lineText(l)
                    let code = TextUtil.stripComment(prev, language: lang)
                    if word == "begin" && TextUtil.isSingleStatementHead(code) {
                        target = TextUtil.leadingWhitespace(prev)
                    }
                }
            }
        } else if lang == .vhdl {
            let w = trimmed.lowercased()
            if ["end", "begin", "else", "elsif", "when"].contains(w) {
                var l = c.lineIndex(for: lr.location) - 1
                while l >= 0 && c.lineText(l).trimmingCharacters(in: .whitespaces).isEmpty { l -= 1 }
                if l >= 0 {
                    let prev = c.lineText(l)
                    let prevLead = TextUtil.leadingWhitespace(prev)
                    let code = TextUtil.stripComment(prev, language: lang)
                    if TextUtil.increasesIndent(code, language: lang) && !(w == "when" && code.lowercased().hasSuffix("=>")) {
                        target = prevLead
                    } else {
                        let width = max(0, TextUtil.indentWidth(prevLead, tabSize: c.tabSize) - c.tabSize)
                        target = TextUtil.makeIndent(width, tabSize: c.tabSize, useSpaces: c.doc?.useSpaces ?? true)
                    }
                }
            }
        }
        guard let target, target != lead,
              TextUtil.indentWidth(target, tabSize: c.tabSize) < TextUtil.indentWidth(lead, tabSize: c.tabSize) else { return }
        let caretFromEnd = NSMaxRange(lr) - selectedRange().location
        c.replace(NSRange(location: lr.location, length: (lead as NSString).length), with: target)
        let newLR = ns.lineRange(for: NSRange(location: lr.location, length: 0))
        setSelectedRange(NSRange(location: NSMaxRange(newLR) - caretFromEnd, length: 0))
    }

    private func alignCloser(lineRange lr: NSRange, line: String) {
        guard let c = controller else { return }
        c.relex()
        let lead = TextUtil.leadingWhitespace(line)
        let off = lr.location + (lead as NSString).length
        guard let k = c.tokenIndex(touching: off), c.tokens[k].start == off, let m = c.pairs[k] else { return }
        let target = TextUtil.leadingWhitespace(c.lineText(c.lineIndex(for: c.tokens[m].start)))
        guard target != lead, c.lineIndex(for: c.tokens[m].start) != c.lineIndex(for: off) else { return }
        let caretFromEnd = NSMaxRange(lr) - selectedRange().location
        c.replace(NSRange(location: lr.location, length: (lead as NSString).length), with: target)
        let newLR = ns.lineRange(for: NSRange(location: lr.location, length: 0))
        setSelectedRange(NSRange(location: NSMaxRange(newLR) - caretFromEnd, length: 0))
    }

    override func insertNewline(_ sender: Any?) {
        guard let c = controller, let lang = c.doc?.language, !hasMarkedText() else {
            super.insertNewline(sender)
            return
        }
        if c.completion.isVisible {
            if c.completion.handle(#selector(NSResponder.insertNewline(_:))) { return }
        }
        let sel = selectedRange()
        let lr = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: lr.location, length: sel.location - lr.location))
        var lineEnd = NSMaxRange(lr)
        if lineEnd > lr.location && ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        let afterStart = NSMaxRange(sel)
        let after = afterStart <= lineEnd ? ns.substring(with: NSRange(location: afterStart, length: lineEnd - afterStart)) : ""
        let indent = TextUtil.leadingWhitespace(before.isEmpty ? ns.substring(with: lr) : before)
        let unit = c.indentUnit
        let code = TextUtil.stripComment(before, language: lang)
        let trimmedCode = code.trimmingCharacters(in: .whitespaces)

        // Caret inside an empty or open bracket pair: put the closer on its own line.
        let prevCh = trimmedCode.last
        let afterTrim = after.drop { $0 == " " || $0 == "\t" }
        if let p = prevCh, let n = afterTrim.first, (p == "(" && n == ")") || (p == "[" && n == "]") || (p == "{" && n == "}") {
            let skip = after.utf16.count - afterTrim.utf16.count
            let ins = "\n" + indent + unit + "\n" + indent
            c.replace(NSRange(location: sel.location, length: sel.length + skip), with: ins,
                      select: NSRange(location: sel.location + 1 + (indent + unit).utf16.count, length: 0))
            return
        }

        var newIndent = indent
        if TextUtil.increasesIndent(code, language: lang) {
            newIndent += unit
        } else if lang.isVerilogFamily, trimmedCode.hasPrefix(")"), trimmedCode.hasSuffix(";"), let header = headerInfo(closeParenAt: lr.location + (indent as NSString).length) {
            newIndent = header.indent + unit
            if c.settings.autoEnd, c.pairs[header.token] == nil, let closer = Self.blockClosers[header.word],
               after.trimmingCharacters(in: .whitespaces).isEmpty {
                let ins = "\n" + newIndent + "\n" + header.indent + closer
                c.replace(NSRange(location: sel.location, length: sel.length + (after as NSString).length), with: ins,
                          select: NSRange(location: sel.location + 1 + (newIndent as NSString).length, length: 0))
                return
            }
        } else if lang.isVerilogFamily, trimmedCode.hasSuffix(";") {
            // After the single statement of `if (...)` without begin, go back out.
            var l = c.lineIndex(for: lr.location) - 1
            while l >= 0 && c.lineText(l).trimmingCharacters(in: .whitespaces).isEmpty { l -= 1 }
            if l >= 0 {
                let prev = c.lineText(l)
                let prevLead = TextUtil.leadingWhitespace(prev)
                if TextUtil.isSingleStatementHead(TextUtil.stripComment(prev, language: lang)),
                   TextUtil.indentWidth(prevLead, tabSize: c.tabSize) < TextUtil.indentWidth(indent, tabSize: c.tabSize) {
                    newIndent = prevLead
                }
            }
        }

        // Remove whitespace-only content before the caret (no trailing spaces left behind).
        var replaceRange = sel
        var prefix = ""
        if before.trimmingCharacters(in: .whitespaces).isEmpty && !before.isEmpty {
            replaceRange = NSRange(location: lr.location, length: sel.location - lr.location + sel.length)
            prefix = ""
        }
        // Drop leading whitespace after the caret (it would end up before the new indent).
        let skipAfter = after.utf16.count - afterTrim.utf16.count
        if skipAfter > 0 { replaceRange.length += skipAfter }

        // Auto-insert the matching `end` keyword.
        if c.settings.autoEnd, lang.isVerilogFamily, afterTrim.trimmingCharacters(in: .whitespaces).isEmpty,
           let closer = closerToInsert(code: trimmedCode, lineRange: lr) {
            let ins = prefix + "\n" + newIndent + "\n" + indent + closer
            let caret = replaceRange.location + (prefix + "\n" + newIndent).utf16.count
            c.replace(replaceRange, with: ins, select: NSRange(location: caret, length: 0))
            return
        }
        let ins = prefix + "\n" + newIndent
        c.replace(replaceRange, with: ins, select: NSRange(location: replaceRange.location + ins.utf16.count, length: 0))
    }

    /// For `);` that ends a module/function header: the header line's indentation.
    private func headerInfo(closeParenAt off: Int) -> (indent: String, word: String, token: Int)? {
        guard let c = controller else { return nil }
        c.relex()
        guard let k = c.tokenIndex(touching: off), c.tokens[k].start == off, let m = c.pairs[k] else { return nil }
        // walk back from the '(' to the start of the statement
        var j = m - 1
        while j >= 0 {
            let t = c.tokens[j]
            if t.kind == .op && c.units[t.start] == 59 { return nil }
            if t.kind == .keyword || t.kind == .control {
                let w = Lexer.string(c.units, t)
                if Structure.headerOpeners.contains(w) {
                    return (TextUtil.leadingWhitespace(c.lineText(c.lineIndex(for: t.start))), w, j)
                }
                if ["begin", "end", "assign", "always", "initial"].contains(w) { return nil }
            }
            j -= 1
        }
        return nil
    }

    /// The closer (`end`, `endcase`, …) to add when Return is pressed after an unmatched opener.
    private func closerToInsert(code: String, lineRange lr: NSRange) -> String? {
        guard let c = controller else { return nil }
        let lw = TextUtil.lastWord(code)
        let fw = TextUtil.firstWord(code)
        var opener: String? = nil
        if ["begin", "fork", "generate", "specify"].contains(lw) { opener = lw }
        else if ["case", "casez", "casex", "randcase"].contains(fw) && code.hasSuffix(")") { opener = fw }
        else if (fw == "unique" || fw == "priority" || fw == "unique0"), code.hasSuffix(")") {
            opener = ["case", "casez", "casex"].first { code.contains($0 + " ") || code.contains($0 + "(") }
        }
        else if ["function", "task", "module", "class", "interface", "package", "program", "covergroup"].contains(fw) && code.hasSuffix(";") { opener = fw }
        else if fw == "virtual" && code.hasSuffix(";") && code.contains("class ") { opener = "class" }
        else if ["static", "automatic"].contains(fw) && code.hasSuffix(";") { opener = code.contains("function") ? "function" : (code.contains("task") ? "task" : nil) }
        guard let o = opener, let closer = Self.blockClosers[o] else { return nil }
        c.relex()
        // Find the opener token on this line and check whether it is already matched.
        var k = c.tokens.index(at: lr.location)
        var found: Int? = nil
        while k < c.tokens.count && c.tokens[k].start < NSMaxRange(lr) {
            let t = c.tokens[k]
            if (t.kind == .keyword || t.kind == .control) && Lexer.string(c.units, t) == o { found = k }
            k += 1
        }
        guard let f = found else { return nil }
        if c.pairs[f] != nil {
            // Matched — but maybe by a closer that belongs to an outer block. Count balance instead.
            let closers = Structure.verilogOpeners[o] ?? [closer]
            var opens = 0, closes = 0
            for t in c.tokens where t.kind == .keyword || t.kind == .control {
                let w = Lexer.string(c.units, t)
                if Structure.verilogOpeners[w]?.isSuperset(of: closers) == true || Structure.verilogOpeners[w] == closers { opens += 1 }
                else if closers.contains(w) { closes += 1 }
            }
            if opens <= closes { return nil }
        }
        return closer
    }

    override func insertTab(_ sender: Any?) {
        guard let c = controller else { super.insertTab(sender); return }
        if c.completion.isVisible { c.completion.accept(); return }
        let sel = selectedRange()
        if c.selectPlaceholder(forward: true) { return }
        if sel.length > 0 && ns.substring(with: sel).contains("\n") {
            c.indentLines(1)
            return
        }
        if c.doc?.useSpaces ?? true {
            let lr = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let before = ns.substring(with: NSRange(location: lr.location, length: sel.location - lr.location))
            let col = TextUtil.indentWidth(before.replacingOccurrences(of: "[^\\t]", with: " ", options: .regularExpression), tabSize: c.tabSize)
            let n = c.tabSize - (col % c.tabSize)
            insertText(String(repeating: " ", count: n), replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard let c = controller else { super.insertBacktab(sender); return }
        if c.selectionIsPlaceholder, c.selectPlaceholder(forward: false) { return }
        c.indentLines(-1)
    }

    override func deleteBackward(_ sender: Any?) {
        guard let c = controller, !hasMarkedText() else { super.deleteBackward(sender); return }
        let sel = selectedRange()
        if sel.length == 0 && sel.location > 0 {
            let prev = char(at: sel.location - 1)
            let next = char(at: sel.location)
            if c.settings.autoClose, let p = prev, let close = Self.openers[p], next == close {
                c.replace(NSRange(location: sel.location - 1, length: 2), with: "", select: NSRange(location: sel.location - 1, length: 0))
                c.completion.update(explicit: false, onlyIfVisible: true)
                return
            }
            // In leading whitespace: delete back to the previous tab stop.
            let lr = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let before = ns.substring(with: NSRange(location: lr.location, length: sel.location - lr.location))
            if !before.isEmpty && before.allSatisfy({ $0 == " " }) && (c.doc?.useSpaces ?? true) {
                let n = before.count % c.tabSize == 0 ? c.tabSize : before.count % c.tabSize
                let del = min(n, before.count)
                c.replace(NSRange(location: sel.location - del, length: del), with: "", select: NSRange(location: sel.location - del, length: 0))
                return
            }
        }
        super.deleteBackward(sender)
        if c.completion.isVisible { c.completion.update(explicit: false, onlyIfVisible: true) }
    }

    override func doCommand(by selector: Selector) {
        if let c = controller, c.completion.isVisible, c.completion.handle(selector) { return }
        if selector == #selector(complete(_:)) {
            controller?.completion.update(explicit: true)
            return
        }
        if selector == #selector(cancelOperation(_:)) {
            // Esc closes the find bar
            if let sv = enclosingScrollView, sv.isFindBarVisible {
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.hideFindInterface.rawValue
                performTextFinderAction(item)
                return
            }
        }
        super.doCommand(by: selector)
    }

    override func complete(_ sender: Any?) {
        controller?.completion.update(explicit: true)
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (126, [.option]): c.moveLines(up: true); return             // ⌥↑
        case (125, [.option]): c.moveLines(up: false); return            // ⌥↓
        case (126, [.option, .shift]): c.duplicateLines(up: true); return
        case (125, [.option, .shift]): c.duplicateLines(up: false); return
        case (49, [.control]): c.completion.update(explicit: true); return  // ⌃Space
        case (53, []):                                                    // Esc
            if c.completion.isVisible { c.completion.hide(); return }
        default: break
        }
        super.keyDown(with: event)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        controller?.completion.hide()
        if event.modifierFlags.contains(.command), let c = controller {
            let p = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: p)
            if let (w, _) = c.word(at: idx), let doc = c.doc {
                setSelectedRange(NSRange(location: idx, length: 0))
                AppModel.shared.goToDefinition(word: w, in: doc, offset: idx)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let c = controller, let doc = c.doc else { return super.menu(for: event) }
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        let sel = selectedRange()
        if sel.length == 0 || idx < sel.location || idx > NSMaxRange(sel) {
            setSelectedRange(NSRange(location: idx, length: 0))
        }
        let m = NSMenu()
        let model = AppModel.shared
        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], _ action: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            item.keyEquivalentModifierMask = mods
            m.addItem(item)
        }
        if let (w, _) = c.word(at: selectedRange().location) {
            add("Go to Definition", String(Character(UnicodeScalar(NSF12FunctionKey)!)), []) { model.goToDefinition(word: w, in: doc, offset: c.textView.selectedRange().location) }
            add("Find All References") { model.findReferences(w) }
            m.addItem(.separator())
        }
        if doc.language != .plain {
            add("Copy Instantiation Template", "i", [.command, .shift]) { model.copyInstantiation() }
            add("Generate Testbench", "g", [.command, .shift]) { model.generateTestbench() }
            add("Insert Snippet…", "j", [.command, .shift]) { model.openPalette(.snippet) }
            m.addItem(.separator())
            add("Toggle Line Comment", "/") { c.toggleComment() }
            if doc.language.isVerilogFamily { add("Reindent Lines", "i", [.control]) { model.reindent() } }
            m.addItem(.separator())
        }
        m.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "x")
        m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        m.addItem(.separator())
        m.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        return m
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let c = controller, let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        let sel = selectedRange()
        // Current line
        if c.settings.highlightLine && sel.length == 0 && window?.firstResponder === self {
            let theme = c.theme
            var r: NSRect
            if sel.location >= (string as NSString).length && (lm.extraLineFragmentTextContainer != nil) {
                r = lm.extraLineFragmentRect
            } else if (string as NSString).length > 0 {
                let g = lm.glyphIndexForCharacter(at: min(sel.location, (string as NSString).length - 1))
                r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                // for wrapped lines, cover the fragment containing the caret
            } else {
                r = NSRect(x: 0, y: 0, width: bounds.width, height: c.lineHeight)
            }
            r.origin.x = 0
            r.size.width = bounds.width
            r.origin.y += origin.y
            NSColor(hex: theme.lineHighlight, alpha: theme.lineHighlightAlpha).setFill()
            r.fill()
        }
        // Indent guides
        if c.settings.indentGuides && c.tokens.count >= 0 {
            let theme = c.theme
            NSColor(hex: theme.indentGuide, alpha: theme.indentGuideAlpha).setFill()
            let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var line = c.lineIndex(for: chars.location)
            let lastLine = c.lineIndex(for: NSMaxRange(chars))
            let tab = c.tabSize
            let step = CGFloat(tab) * c.charWidth
            let x0 = origin.x + tc.lineFragmentPadding
            var prevWidth = 0
            while line <= lastLine && line < c.lineCount {
                let lr = c.lineRange(line)
                guard lr.location < (string as NSString).length || lr.length > 0 else { break }
                var width = 0
                var blank = true
                var i = lr.location
                while i < NSMaxRange(lr) {
                    let u = c.units.count > i ? c.units[i] : 0
                    if u == 32 { width += 1 } else if u == 9 { width += tab - width % tab } else { blank = false; break }
                    i += 1
                }
                if blank {
                    // use the next non-blank line's indentation
                    var n = line + 1
                    var nextW = 0
                    while n < c.lineCount && n < line + 200 {
                        let t = c.lineText(n)
                        if !t.trimmingCharacters(in: .whitespaces).isEmpty { nextW = TextUtil.indentWidth(t, tabSize: tab); break }
                        n += 1
                    }
                    width = min(prevWidth, nextW)
                } else {
                    prevWidth = width
                }
                if width >= tab, lr.location <= (string as NSString).length {
                    let g = lm.glyphIndexForCharacter(at: min(lr.location, max(0, (string as NSString).length - 1)))
                    var fr = (string as NSString).length == 0 ? .zero : lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                    if lr.location >= (string as NSString).length { fr = lm.extraLineFragmentRect }
                    let levels = (width - 1) / tab
                    if levels > 0 {
                        for k in 1...levels {
                            let x = floor(x0 + CGFloat(k) * step) + 0.5
                            NSRect(x: x, y: fr.minY + origin.y, width: 1, height: fr.height).fill()
                        }
                    }
                }
                line += 1
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let c = controller, c.settings.inlineDiagnostics, !c.diagnosticsByLine.isEmpty,
              let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        let len = (string as NSString).length
        let glyphs = lm.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = c.lineIndex(for: chars.location)
        let last = c.lineIndex(for: NSMaxRange(chars))
        let font = NSFont.systemFont(ofSize: max(10, c.font.pointSize - 1.5))
        for (line, d) in c.diagnosticsByLine where line >= first && line <= last && line < c.lineCount {
            let lr = c.lineRange(line)
            var used: NSRect
            if lr.length == 0 {
                guard lr.location < len else { continue }
                let g = lm.glyphIndexForCharacter(at: lr.location)
                used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
                used.size.width = 0
            } else {
                let g = lm.glyphIndexForCharacter(at: NSMaxRange(lr) - 1)
                used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
            }
            let color: NSColor = d.severity == .error ? NSColor(c.theme.error) : (d.severity == .warning ? NSColor(c.theme.warning) : NSColor(c.theme.info))
            var msg = d.message.components(separatedBy: "\n").first ?? d.message
            if msg.count > 160 { msg = String(msg.prefix(157)) + "…" }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(0.85)]
            let size = (msg as NSString).size(withAttributes: attrs)
            let x = origin.x + used.maxX + 28
            let y = origin.y + used.minY + (used.height - size.height) / 2
            let bg = NSRect(x: x - 8, y: origin.y + used.minY + 1, width: size.width + 16, height: used.height - 2)
            color.withAlphaComponent(c.theme.isDark ? 0.10 : 0.08).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
            (msg as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        // The current-line highlight spans the full width.
        super.setNeedsDisplay(NSRect(x: 0, y: invalidRect.minY, width: bounds.width, height: invalidRect.height))
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        if ok, let doc = controller?.doc { AppModel.shared.editorFocused(doc) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        controller?.completion.hide()
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { controller?.didAttach() }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, keyEquivalent: String = "", action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { MainActor.assumeIsolated { handler() } }
}

// MARK: - Gutter

/// Line numbers, the current line, and markers for problems.
final class GutterView: NSRulerView {
    weak var editor: EditorController?
    private var bg = NSColor.black
    private var fg = NSColor.gray
    private var activeFG = NSColor.white
    private var dragStartLine: Int?

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = 44
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @MainActor func updateStyle() {
        guard let e = editor else { return }
        bg = NSColor(e.theme.editor)
        fg = NSColor(hex: e.theme.gutterFG)
        activeFG = NSColor(hex: e.theme.gutterActiveFG)
        needsDisplay = true
    }

    @MainActor func updateThickness() {
        guard let e = editor else { return }
        let digits = max(3, String(e.lineCount).count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, e.font.pointSize - 1), weight: .regular)
        let w = ceil(CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width + 34)
        if abs(ruleThickness - w) > 0.5 { ruleThickness = w }
    }

    override func draw(_ dirtyRect: NSRect) {
        bg.setFill()
        bounds.intersection(dirtyRect).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        MainActor.assumeIsolated { drawNumbers(in: rect) }
    }

    @MainActor private func drawNumbers(in rect: NSRect) {
        guard let e = editor, let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let visible = tv.visibleRect
        let origin = tv.textContainerOrigin
        let length = (tv.string as NSString).length
        let glyphs = lm.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = e.lineIndex(for: tv.selectedRange().location)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, e.font.pointSize - 1), weight: .regular)
        let numberRight = bounds.width - 14
        var line = e.lineIndex(for: chars.location)
        let lastLine = e.lineIndex(for: NSMaxRange(chars))
        while line <= lastLine + 1 && line < e.lineCount {
            let start = e.lineStarts[line]
            var frag: NSRect
            if start >= length {
                guard lm.extraLineFragmentTextContainer != nil || length == 0 else { break }
                frag = lm.extraLineFragmentRect
                if length == 0 { frag = NSRect(x: 0, y: 0, width: 10, height: e.lineHeight) }
            } else {
                let g = lm.glyphIndexForCharacter(at: start)
                frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: frag.minY + origin.y), from: tv).y
            let h = frag.height > 0 ? frag.height : e.lineHeight
            if y > bounds.maxY { break }
            let isActive = line == caretLine
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isActive ? activeFG : fg]
            let s = "\(line + 1)" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: numberRight - size.width, y: y + (h - size.height) / 2), withAttributes: attrs)
            if let d = e.diagnosticsByLine[line] {
                let color: NSColor = d.severity == .error ? NSColor(e.theme.error) : (d.severity == .warning ? NSColor(e.theme.warning) : NSColor(e.theme.info))
                color.setFill()
                let r: CGFloat = 7
                NSBezierPath(ovalIn: NSRect(x: 6, y: y + (h - r) / 2, width: r, height: r)).fill()
            }
            line += 1
        }
    }

    // Click and drag to select lines.
    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let e = editor else { return }
            let line = lineAt(event)
            if event.modifierFlags.contains(.shift) {
                let anchor = e.lineIndex(for: e.textView.selectedRange().location)
                dragStartLine = anchor
                selectLines(anchor, line)
            } else {
                dragStartLine = line
                selectLines(line, line)
            }
            e.focus()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let start = dragStartLine else { return }
            selectLines(start, lineAt(event))
            editor?.textView.autoscroll(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) { dragStartLine = nil }

    @MainActor private func lineAt(_ event: NSEvent) -> Int {
        guard let e = editor, let lm = e.textView.layoutManager else { return 0 }
        let p = e.textView.convert(event.locationInWindow, from: nil)
        let y = p.y - e.textView.textContainerOrigin.y
        let len = (e.textView.string as NSString).length
        if len == 0 { return 0 }
        let g = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: e.container)
        let ch = lm.characterIndexForGlyph(at: g)
        if y > lm.usedRect(for: e.container).maxY { return e.lineCount - 1 }
        return e.lineIndex(for: ch)
    }

    @MainActor private func selectLines(_ a: Int, _ b: Int) {
        guard let e = editor else { return }
        let lo = min(a, b), hi = max(a, b)
        let s = e.lineStarts[lo]
        let end = NSMaxRange(e.lineRange(hi, includingNewline: true))
        e.textView.setSelectedRange(NSRange(location: s, length: end - s))
    }
}
