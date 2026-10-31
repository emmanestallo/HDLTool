import AppKit
import Observation
import SwiftUI

struct CompletionItem: Identifiable, Equatable {
    enum Kind { case keyword, snippet, symbol, module, system, directive, instance }
    let id = UUID()
    let label: String
    let detail: String
    let kind: Kind
    let symbolKind: SymbolKind?
    let insert: String
    var snippet: Snippet? = nil
    var module: HDLSymbol? = nil
    var score = 0

    static func == (a: CompletionItem, b: CompletionItem) -> Bool { a.id == b.id }

    var icon: String {
        switch kind {
        case .keyword: return "textformat"
        case .snippet: return "text.badge.plus"
        case .symbol: return symbolKind?.icon ?? "character"
        case .module: return "cpu"
        case .instance: return "square.on.square"
        case .system: return "dollarsign"
        case .directive: return "number"
        }
    }
}

@MainActor
final class CompletionModel {
    weak var owner: CompletionController?
    var items: [CompletionItem] = [] { didSet { owner?.refreshView() } }
    var selected = 0 { didSet { if selected != oldValue { owner?.refreshView() } } }
}

/// Fuzzy matching shared by completion and the command palette.
enum Fuzzy {
    /// Higher is better; nil when `query` is not a subsequence of `text`.
    static func score(_ query: String, _ text: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        let orig = Array(text)
        var qi = 0
        var score = 0
        var last = -2
        var firstMatch = -1
        for (i, c) in t.enumerated() where qi < q.count {
            if c == q[qi] {
                if firstMatch < 0 { firstMatch = i }
                var s = 1
                if i == last + 1 { s += 8 }
                if i == 0 { s += 8 }
                else {
                    let p = orig[i - 1]
                    if p == "_" || p == "/" || p == "." || p == " " || p == "-" || (orig[i].isUppercase && p.isLowercase) { s += 6 }
                }
                score += s
                last = i
                qi += 1
            }
        }
        guard qi == q.count else { return nil }
        if text.lowercased().hasPrefix(query.lowercased()) { score += 20 }
        if text.hasPrefix(query) { score += 5 }
        score -= max(0, t.count - q.count) / 8
        score -= max(0, firstMatch) / 4
        return score
    }
}

@MainActor
final class CompletionController {
    unowned let editor: EditorController
    let model = CompletionModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<CompletionList>?
    private var prefixRange = NSRange(location: 0, length: 0)
    /// Return accepts only after the user picked from the list (arrows) or asked for it (⌃Space).
    private var engaged = false
    private var identCache: (version: Int, time: Date, words: [String: SymbolKind?])?

    init(editor: EditorController) {
        self.editor = editor
        model.owner = self
    }

    func refreshView() {
        guard let panel else { return }
        let h = NSHostingView(rootView: makeList())
        panel.contentView = h
        hosting = h
    }

    private func makeList() -> CompletionList {
        CompletionList(items: model.items, selected: model.selected, theme: editor.theme, rowHeight: 22) { [weak self] i in
            self?.model.selected = i
            self?.accept()
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Recomputes the suggestions for the word before the caret.
    func update(explicit: Bool, onlyIfVisible: Bool = false) {
        if onlyIfVisible && !isVisible { return }
        guard let doc = editor.doc, doc.language != .plain || explicit else { hide(); return }
        let tv = editor.textView
        let sel = tv.selectedRange()
        guard sel.length == 0 else { hide(); return }
        let ns = tv.string as NSString
        var start = sel.location
        while start > 0 {
            let c = ns.character(at: start - 1)
            if Lexer.isIdChar(c) || c == 96 /* ` */ { start -= 1 } else { break }
            if c == 96 || c == 36 { break }
        }
        let prefix = ns.substring(with: NSRange(location: start, length: sel.location - start))
        if !explicit {
            let isSpecial = prefix.hasPrefix("$") || prefix.hasPrefix("`")
            if prefix.count < (isSpecial ? 1 : 2) { hide(); return }
            if editor.isInCommentOrString(sel.location) { hide(); return }
            if let f = prefix.first, f.isNumber { hide(); return }
        }
        // after a '.' inside an instance → port names would be nicer; keep generic
        prefixRange = NSRange(location: start, length: sel.location - start)
        let lineStart = ns.lineRange(for: NSRange(location: start, length: 0)).location
        let atLineStart = ns.substring(with: NSRange(location: lineStart, length: start - lineStart)).trimmingCharacters(in: .whitespaces).isEmpty
        let items = candidates(prefix: prefix, language: doc.language, atLineStart: atLineStart)
        guard !items.isEmpty, !(items.count == 1 && items[0].label == prefix && items[0].kind != .snippet && items[0].kind != .instance) else {
            hide()
            return
        }
        if explicit { engaged = true } else if !isVisible { engaged = false }
        model.items = items
        model.selected = 0
        show()
    }

    private func identifiers() -> [String: SymbolKind?] {
        if let c = identCache, c.version == editor.textVersion || Date().timeIntervalSince(c.time) < 0.8 { return c.words }
        var words: [String: SymbolKind?] = [:]
        let u = editor.units
        let caret = editor.textView.selectedRange().location
        for t in editor.tokens where t.kind == .ident || t.kind == .typeName || t.kind == .funcName {
            if t.end == caret { continue }  // the word being typed
            words[Lexer.string(u, t)] = .some(nil)
        }
        if let doc = editor.doc {
            for s in doc.symbols.flattened() where s.kind != .instance || true {
                words[s.name] = s.kind
            }
        }
        identCache = (editor.textVersion, Date(), words)
        return words
    }

    private func candidates(prefix: String, language: HDLLanguage, atLineStart: Bool) -> [CompletionItem] {
        var out: [CompletionItem] = []
        func add(_ item: CompletionItem) {
            guard let s = Fuzzy.score(prefix, item.label) else { return }
            var it = item
            it.score = s
            out.append(it)
        }
        if prefix.hasPrefix("$") {
            for t in Keywords.systemTasks { add(CompletionItem(label: t, detail: "system task", kind: .system, symbolKind: nil, insert: t)) }
        } else if prefix.hasPrefix("`") {
            for d in Keywords.directives { add(CompletionItem(label: d, detail: "directive", kind: .directive, symbolKind: nil, insert: d)) }
            // user macros
            let re = try? NSRegularExpression(pattern: "`define\\s+([A-Za-z_][A-Za-z0-9_]*)")
            let text = editor.textView.string
            for m in re?.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? [] {
                let name = "`" + (text as NSString).substring(with: m.range(at: 1))
                add(CompletionItem(label: name, detail: "macro", kind: .directive, symbolKind: nil, insert: name))
            }
        } else {
            var seen = Set<String>()
            for (w, k) in identifiers() where !seen.contains(w) {
                seen.insert(w)
                add(CompletionItem(label: w, detail: k?.label ?? "", kind: .symbol, symbolKind: k ?? nil, insert: w))
            }
            let kw: Set<String> = language == .vhdl ? Keywords.vhdlAll.union(Keywords.vhdlTypes) : Keywords.verilogAll
            for w in kw where !seen.contains(w) {
                add(CompletionItem(label: w, detail: "keyword", kind: .keyword, symbolKind: nil, insert: w))
            }
            for s in Snippet.available(for: language) {
                add(CompletionItem(label: s.prefix, detail: s.title, kind: .snippet, symbolKind: nil, insert: s.body, snippet: s))
            }
            for (_, m) in AppModel.shared.workspace.allModules where m.kind == .module || m.kind == .entity || m.kind == .interface {
                if atLineStart {
                    add(CompletionItem(label: m.name, detail: "instantiate \(m.kind.label)", kind: .instance, symbolKind: m.kind, insert: m.name, module: m))
                } else if !seen.contains(m.name) {
                    add(CompletionItem(label: m.name, detail: m.kind.label, kind: .module, symbolKind: m.kind, insert: m.name))
                }
            }
        }
        let rank: (CompletionItem) -> Int = { i in
            switch i.kind {
            case .symbol: return 3
            case .instance, .module: return 2
            case .snippet: return 1
            default: return 0
            }
        }
        out.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if rank(a) != rank(b) { return rank(a) > rank(b) }
            return a.label.count < b.label.count
        }
        return Array(out.prefix(40))
    }

    private func show() {
        let tv = editor.textView
        guard let window = tv.window else { return }
        let theme = editor.theme
        let rows = min(model.items.count, 10)
        let rowH: CGFloat = 22
        let size = NSSize(width: 420, height: CGFloat(rows) * rowH + 8)
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.hidesOnDeactivate = true
            let h = NSHostingView(rootView: makeList())
            p.contentView = h
            hosting = h
            panel = p
        }
        _ = theme
        hosting?.rootView = makeList()
        guard let panel else { return }
        let caret = tv.firstRect(forCharacterRange: NSRange(location: prefixRange.location, length: 0), actualRange: nil)
        var origin = NSPoint(x: caret.minX - 26, y: caret.minY - size.height - 2)
        if let screen = window.screen, origin.y < screen.visibleFrame.minY {
            origin.y = caret.maxY + 2
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible || panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    /// Handles navigation keys while the list is shown.
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            engaged = true
            model.selected = (model.selected - 1 + model.items.count) % max(1, model.items.count)
        case #selector(NSResponder.moveDown(_:)):
            engaged = true
            model.selected = (model.selected + 1) % max(1, model.items.count)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            model.selected = max(0, model.selected - 9)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            model.selected = min(model.items.count - 1, model.selected + 9)
        case #selector(NSResponder.insertNewline(_:)):
            // Return makes a new line unless the user is choosing from the list.
            if !engaged {
                hide()
                return false
            }
            if let item = model.items[safe: model.selected], item.kind != .snippet, item.kind != .instance,
               item.insert == (editor.textView.string as NSString).substring(with: NSRange(location: prefixRange.location, length: max(0, editor.textView.selectedRange().location - prefixRange.location))) {
                hide()
                return false
            }
            accept()
        case #selector(NSResponder.insertTab(_:)):
            accept()
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            hide()
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            hide()
            return false
        default:
            return false
        }
        return true
    }

    func accept() {
        guard model.items.indices.contains(model.selected) else { hide(); return }
        let item = model.items[model.selected]
        hide()
        let tv = editor.textView
        let sel = tv.selectedRange()
        let range = NSRange(location: prefixRange.location, length: sel.location - prefixRange.location)
        guard NSMaxRange(range) <= (tv.string as NSString).length else { return }
        switch item.kind {
        case .snippet:
            if let s = item.snippet { editor.insertSnippet(s, replacing: range) }
        case .instance:
            if let m = item.module, let lang = editor.doc?.language {
                let base = editor.leadingWhitespace(ofLineAt: range.location)
                let text = Templates.instance(of: m, language: lang, unit: editor.indentUnit)
                    .components(separatedBy: "\n").enumerated()
                    .map { $0.offset == 0 ? $0.element : base + $0.element }.joined(separator: "\n")
                editor.replace(range, with: text, select: NSRange(location: range.location + text.utf16.count, length: 0))
                // select the instance name for renaming
                let ns = tv.string as NSString
                let found = ns.range(of: "u_\(m.name)", options: [], range: NSRange(location: range.location, length: text.utf16.count))
                if found.location != NSNotFound { tv.setSelectedRange(found) }
            }
        case .system:
            let needsArgs = !["$time", "$stime", "$realtime", "$finish", "$stop", "$random", "$urandom"].contains(item.insert)
            if needsArgs && (tv.string as NSString).length > NSMaxRange(range) && (tv.string as NSString).character(at: NSMaxRange(range)) == 40 {
                editor.replace(range, with: item.insert, select: NSRange(location: range.location + item.insert.utf16.count, length: 0))
            } else if needsArgs {
                let text = item.insert + "(<#args#>)"
                editor.insertTemplate(text, replacing: range)
            } else {
                editor.replace(range, with: item.insert, select: NSRange(location: range.location + item.insert.utf16.count, length: 0))
            }
        default:
            editor.replace(range, with: item.insert, select: NSRange(location: range.location + item.insert.utf16.count, length: 0))
        }
    }
}

struct CompletionList: View {
    let items: [CompletionItem]
    let selected: Int
    let theme: Theme
    let rowHeight: CGFloat
    let onPick: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == selected)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(i) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selected) { _, s in proxy.scrollTo(s) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.widgetBG))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.isDark ? Color(hex: 0x454545) : Color(hex: 0xC8C8C8), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func color(_ item: CompletionItem) -> Color {
        switch item.kind {
        case .keyword: return theme.synKeyword
        case .snippet: return theme.dimFG
        case .system: return theme.synSystem
        case .directive: return theme.synDirective
        case .module, .instance: return theme.symbolColor(.module)
        case .symbol: return item.symbolKind.map { theme.symbolColor($0) } ?? theme.synIdent
        }
    }

    private func row(_ item: CompletionItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 11))
                .foregroundStyle(color(item))
                .frame(width: 16)
            Text(item.label)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(selected ? (theme.isDark ? Color.white : theme.fg) : theme.fg)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(theme.dimFG)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(selected ? theme.listSelection : Color.clear)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
