import AppKit

/// Owns one document's text view, gutter and scroll view, and implements the editing commands.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate, @preconcurrency NSLayoutManagerDelegate {
    weak var doc: EditorDocument?
    let scrollView: NSScrollView
    let textView: CodeTextView
    let gutter: GutterView
    let layoutManager: NSLayoutManager
    let storage: NSTextStorage
    let container: NSTextContainer
    let undo = UndoManager()
    lazy var completion = CompletionController(editor: self)

    private(set) var units: [UInt16] = []
    private(set) var tokens: [Token] = []
    private(set) var lineStarts: [Int] = [0]
    private var pairsCache: [Int: Int]?
    private(set) var textVersion = 0

    private(set) var theme: Theme = ThemeID.current.theme
    private(set) var settings = EditorSettings.load()
    private(set) var palette: SyntaxPalette
    private(set) var font: NSFont
    private(set) var lineHeight: CGFloat = 18
    private(set) var charWidth: CGFloat = 7.8
    private var fontHeight: CGFloat = 15
    private var fontAscender: CGFloat = 12
    var baseAttributes: [NSAttributedString.Key: Any] = [:]

    private var highlighted = NSRange(location: 0, length: 0)
    private var decorRanges: [NSRange] = []
    private(set) var diagnosticsByLine: [Int: Diagnostic] = [:]
    private var symbolTimer: Timer?
    private var dirtyTimer: Timer?
    private var lexTimer: Timer?
    private var pendingReveal: (line: Int, column: Int?, length: Int)?
    private var scrollObserver: NSObjectProtocol?
    var typing = false

    init(doc: EditorDocument, text: String) {
        self.doc = doc
        storage = NSTextStorage()
        layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 6
        layoutManager.addTextContainer(container)
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), textContainer: container)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        gutter = GutterView(scrollView: scrollView, orientation: .verticalRuler)
        palette = SyntaxPalette(theme)
        font = settings.font
        super.init()

        layoutManager.delegate = self
        storage.delegate = self
        textView.controller = self
        textView.delegate = self
        gutter.editor = self
        gutter.clientView = textView

        let tv = textView
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.inlinePredictionType = .no
        tv.writingToolsBehavior = .none
        tv.allowsDocumentBackgroundColorChange = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.clipsToBounds = true

        scrollView.wantsLayer = true
        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.findBarPosition = .aboveContent
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didScroll() }
        }

        applyStyle(theme: theme, settings: settings, force: true)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSAttributedString(string: text, attributes: baseAttributes))
        storage.endEditing()
        relex()
        highlightAll()
        undo.removeAllActions()
        if let sel = doc.initialSelection, NSMaxRange(sel) <= (text as NSString).length {
            tv.setSelectedRange(sel)
        } else {
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
        updateCaret()
    }

    // MARK: Style

    func configure(theme: Theme, settings: EditorSettings) {
        guard theme.id != self.theme.id || settings != self.settings else { return }
        applyStyle(theme: theme, settings: settings, force: false)
    }

    private func applyStyle(theme: Theme, settings: EditorSettings, force: Bool) {
        let themeChanged = force || theme.id != self.theme.id
        let fontChanged = force || settings.font != font || settings.lineHeight != self.settings.lineHeight || settings.tabSize != self.settings.tabSize
        self.theme = theme
        self.settings = settings
        palette = SyntaxPalette(theme)
        font = settings.font
        charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        fontAscender = font.ascender
        fontHeight = ceil(font.ascender - font.descender + font.leading)
        lineHeight = ceil(font.pointSize * CGFloat(settings.lineHeight))
        let tabSize = doc?.tabSize ?? settings.tabSize
        let para = NSMutableParagraphStyle()
        para.defaultTabInterval = charWidth * CGFloat(tabSize)
        para.tabStops = []
        para.lineBreakMode = .byWordWrapping
        baseAttributes = [.font: font, .foregroundColor: palette.fg, .paragraphStyle: para]

        let bg = NSColor(theme.editor)
        textView.backgroundColor = bg
        textView.drawsBackground = true
        scrollView.backgroundColor = bg
        textView.insertionPointColor = NSColor(hex: theme.caret)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(hex: theme.selection, alpha: theme.isDark ? 1 : 1)]
        textView.textColor = palette.fg
        textView.font = font
        textView.typingAttributes = baseAttributes
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        scrollView.appearance = appearance
        gutter.appearance = appearance
        layoutManager.showsInvisibleCharacters = settings.showInvisibles

        if fontChanged || themeChanged {
            let full = NSRange(location: 0, length: storage.length)
            if full.length > 0 {
                storage.beginEditing()
                storage.setAttributes(baseAttributes, range: full)
                storage.endEditing()
            }
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
        applyWrap()
        gutter.updateStyle()
        gutter.updateThickness()
        if themeChanged && !tokens.isEmpty { highlightAll() }
        textView.needsDisplay = true
    }

    func tabSizeChanged() {
        applyStyle(theme: theme, settings: settings, force: true)
        highlightAll()
    }

    private func applyWrap() {
        if settings.wordWrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            let w = max(100, scrollView.contentSize.width)
            container.containerSize = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = w
        } else {
            scrollView.hasHorizontalScroller = true
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
        }
    }

    // Uniform line height with vertically centered text.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        var r = lineFragmentRect.pointee
        r.size.height = lineHeight
        lineFragmentRect.pointee = r
        var u = lineFragmentUsedRect.pointee
        u.size.height = lineHeight
        lineFragmentUsedRect.pointee = u
        baselineOffset.pointee = floor((lineHeight - fontHeight) / 2 + fontAscender)
        return true
    }

    // Typed and pasted text always gets the base attributes.
    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), editedRange.length > 0 else { return }
        textStorage.setAttributes(baseAttributes, range: editedRange)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // MARK: Text changes

    func setText(_ text: String) {
        let sel = textView.selectedRange()
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: NSAttributedString(string: text, attributes: baseAttributes))
        storage.endEditing()
        let len = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        afterChange(immediate: true)
    }

    func languageChanged() {
        relex()
        highlightAll()
        scheduleSymbols(delay: 0)
    }

    func textDidChange(_ notification: Notification) {
        afterChange(immediate: false)
    }

    private func afterChange(immediate: Bool) {
        guard let doc else { return }
        if units.count < 400_000 || immediate {
            relex()
            highlightAll()
        } else {
            lexTimer?.invalidate()
            lexTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.relex(); self?.highlightAll() }
            }
        }
        if !doc.isDirty { doc.isDirty = true }
        dirtyTimer?.invalidate()
        dirtyTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let doc = self.doc else { return }
                let clean = self.textView.string == doc.savedText
                if doc.isDirty == clean { doc.isDirty = !clean }
            }
        }
        scheduleSymbols(delay: 0.25)
        AppModel.shared.textChanged(doc)
        updateCaret()
    }

    private func scheduleSymbols(delay: TimeInterval) {
        symbolTimer?.invalidate()
        symbolTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let doc = self.doc else { return }
                let syms = SymbolScanner.scan(self.units, tokens: self.tokens, language: doc.language)
                if syms != doc.symbols {
                    doc.symbols = syms
                    AppModel.shared.symbolsChanged(doc)
                }
                self.updateCaret()
            }
        }
    }

    func relex() {
        units = Array(textView.string.utf16)
        tokens = Lexer.lex(units, language: doc?.language ?? .verilog)
        lineStarts = Structure.lineStarts(units)
        pairsCache = nil
        textVersion += 1
        gutter.updateThickness()
    }

    /// Fresh tokens even when lexing is deferred (large files).
    func ensureFresh() {
        if units.count != storage.length { relex() }
    }

    var pairs: [Int: Int] {
        if let p = pairsCache { return p }
        let p = Structure.pairs(tokens, units, language: doc?.language ?? .verilog)
        pairsCache = p
        return p
    }

    var lineCount: Int { lineStarts.count }

    func lineIndex(for offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func lineRange(_ line: Int, includingNewline: Bool = false) -> NSRange {
        guard line >= 0 && line < lineStarts.count else { return NSRange(location: units.count, length: 0) }
        let s = lineStarts[line]
        var e = line + 1 < lineStarts.count ? lineStarts[line + 1] : units.count
        if !includingNewline && e > s && e <= units.count && e - 1 < units.count && units[e - 1] == 10 { e -= 1 }
        if !includingNewline && e > s && units[e - 1] == 13 { e -= 1 }
        return NSRange(location: s, length: e - s)
    }

    func lineText(_ line: Int) -> String {
        let r = lineRange(line)
        return (textView.string as NSString).substring(with: r)
    }

    func token(at offset: Int) -> Token? {
        let k = tokens.index(at: offset)
        guard k < tokens.count, tokens[k].start <= offset, offset < tokens[k].end else { return nil }
        return tokens[k]
    }

    /// Token touching the caret (preferring the one ending at it).
    func tokenIndex(touching offset: Int) -> Int? {
        let k = tokens.index(at: offset)
        if k < tokens.count, tokens[k].start <= offset, offset < tokens[k].end { return k }
        if k > 0, tokens[k - 1].end == offset { return k - 1 }
        if k < tokens.count, tokens[k].start == offset { return k }
        return nil
    }

    func isInCommentOrString(_ offset: Int) -> Bool {
        let k = tokens.index(at: max(0, offset - 1))
        guard k < tokens.count else { return false }
        let t = tokens[k]
        guard t.kind == .comment || t.kind == .string else { return false }
        if t.start < offset && offset < t.end { return true }
        // At the end of an unterminated line comment or string.
        if offset == t.end && t.kind == .comment {
            let s = Lexer.string(units, t)
            return s.hasPrefix("//") || s.hasPrefix("--") || !s.hasSuffix("*/")
        }
        if offset == t.end && t.kind == .string && t.length > 0 && (t.length == 1 || units[t.end - 1] != 34) { return true }
        return false
    }

    // MARK: Highlighting

    func visibleCharRange() -> NSRange {
        let rect = scrollView.contentView.bounds
        let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: rect, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    private func targetRange() -> NSRange {
        let len = storage.length
        if len <= 250_000 { return NSRange(location: 0, length: len) }
        let v = visibleCharRange()
        let s = max(0, v.location - 6000)
        let e = min(len, NSMaxRange(v) + 6000)
        return NSRange(location: s, length: e - s)
    }

    func highlightAll() {
        guard tokens.count > 0 || storage.length == 0 || doc?.language == .plain else {
            paint(targetRange())
            return
        }
        paint(targetRange())
    }

    private func didScroll() {
        gutter.needsDisplay = true
        if completion.isVisible { completion.hide() }
        guard storage.length > 250_000 else { return }
        let v = visibleCharRange()
        if v.location < highlighted.location || NSMaxRange(v) > NSMaxRange(highlighted) {
            paint(targetRange())
        }
    }

    private func paint(_ r: NSRange) {
        guard r.length > 0, NSMaxRange(r) <= storage.length else { highlighted = r; return }
        let lm = layoutManager
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: r)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: r)
        var k = tokens.index(at: r.location)
        let end = NSMaxRange(r)
        let len = storage.length
        while k < tokens.count && tokens[k].start < end {
            let t = tokens[k]
            k += 1
            guard t.end <= len else { break }
            let tr = NSRange(location: t.start, length: t.length)
            if t.kind == .placeholder {
                paintPlaceholder(tr)
            } else if let c = palette.color(t.kind) {
                lm.addTemporaryAttribute(.foregroundColor, value: c, forCharacterRange: tr)
            }
        }
        highlighted = r
        decorRanges = []
        applyDiagnostics()
        updateDecorations()
    }

    private func paintPlaceholder(_ r: NSRange) {
        let lm = layoutManager
        lm.addTemporaryAttribute(.backgroundColor, value: NSColor(theme.accent).withAlphaComponent(theme.isDark ? 0.35 : 0.18), forCharacterRange: r)
        lm.addTemporaryAttribute(.foregroundColor, value: palette.fg, forCharacterRange: r)
        if r.length >= 4 {
            let dim = palette.fg.withAlphaComponent(0.35)
            lm.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: r.location, length: 2))
            lm.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: NSMaxRange(r) - 2, length: 2))
        }
    }

    // MARK: Diagnostics

    func setDiagnostics(_ diags: [Diagnostic]) {
        var byLine: [Int: Diagnostic] = [:]
        for d in diags {
            let l = d.line - 1
            if let e = byLine[l], e.severity <= d.severity { continue }
            byLine[l] = d
        }
        diagnosticsByLine = byLine
        applyDiagnostics()
        gutter.needsDisplay = true
        textView.needsDisplay = true
    }

    private func applyDiagnostics() {
        let lm = layoutManager
        let len = storage.length
        let r = highlighted
        guard r.length > 0, NSMaxRange(r) <= len else { return }
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: r)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: r)
        for (line, d) in diagnosticsByLine where line < lineStarts.count {
            let lr = lineRange(line)
            guard lr.length > 0, NSIntersectionRange(lr, r).length > 0 || lr.location == r.location else { continue }
            var target = lr
            if let col = d.column, col - 1 < lr.length {
                let off = lr.location + col - 1
                if let k = tokenIndex(touching: off) {
                    target = NSRange(location: tokens[k].start, length: max(1, tokens[k].length))
                } else {
                    target = NSRange(location: off, length: 1)
                }
            } else {
                // trim leading whitespace and trailing comment-free whitespace
                let s = (textView.string as NSString).substring(with: lr)
                let lead = s.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let trimmed = s.trimmingCharacters(in: .whitespaces).utf16.count
                target = NSRange(location: lr.location + lead, length: max(1, trimmed))
            }
            guard NSMaxRange(target) <= len else { continue }
            let color: NSColor = d.severity == .error ? NSColor(theme.error) : (d.severity == .warning ? NSColor(theme.warning) : NSColor(theme.info))
            let style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
            lm.addTemporaryAttribute(.underlineStyle, value: style, forCharacterRange: target)
            lm.addTemporaryAttribute(.underlineColor, value: color, forCharacterRange: target)
        }
    }

    // MARK: Bracket and word highlights

    func updateDecorations() {
        let lm = layoutManager
        let len = storage.length
        for r in decorRanges where NSMaxRange(r) <= len {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
            // restore placeholders under it
            var k = tokens.index(at: r.location)
            while k < tokens.count && tokens[k].start < NSMaxRange(r) {
                if tokens[k].kind == .placeholder { paintPlaceholder(NSRange(location: tokens[k].start, length: tokens[k].length)) }
                k += 1
            }
        }
        decorRanges = []
        let sel = textView.selectedRange()
        guard sel.length == 0, len > 0 else { return }
        let off = sel.location

        // Matching bracket / begin-end
        var bracket: [NSRange] = []
        for probe in [off - 1, off] where probe >= 0 && probe < len {
            guard let k = tokenIndex(touching: probe) else { continue }
            let t = tokens[k]
            let isBracket = t.kind == .op && [40, 41, 91, 93, 123, 125].contains(units[t.start])
            let isBlock = (t.kind == .keyword || t.kind == .control) && (Structure.verilogOpeners[Lexer.string(units, t)] != nil || Structure.verilogClosers.contains(Lexer.string(units, t)))
            guard isBracket || isBlock else { continue }
            if isBracket && probe == off && off > 0, let pk = tokenIndex(touching: off - 1), pk != k,
               tokens[pk].kind == .op, [40, 41, 91, 93, 123, 125].contains(units[tokens[pk].start]) { continue }
            if let m = pairs[k] {
                bracket = [NSRange(location: t.start, length: t.length), NSRange(location: tokens[m].start, length: tokens[m].length)]
            }
            break
        }
        let bColor = NSColor(hex: theme.isDark ? 0x888888 : 0x777777, alpha: theme.isDark ? 0.32 : 0.22)
        for r in bracket where NSMaxRange(r) <= len {
            lm.addTemporaryAttribute(.backgroundColor, value: bColor, forCharacterRange: r)
            decorRanges.append(r)
        }

        // Other occurrences of the identifier at the caret
        guard let k = tokenIndex(touching: off) else { return }
        let t = tokens[k]
        guard t.kind == .ident || t.kind == .typeName || t.kind == .funcName else { return }
        let vhdl = doc?.language == .vhdl
        var word = Lexer.string(units, t)
        if vhdl { word = word.lowercased() }
        let wl = word.utf16.count
        let wColor = NSColor(hex: theme.isDark ? 0x575757 : 0x575757, alpha: theme.wordHighlightAlpha)
        let area = highlighted
        var ki = tokens.index(at: area.location)
        var count = 0
        while ki < tokens.count && tokens[ki].start < NSMaxRange(area) && count < 400 {
            let o = tokens[ki]
            ki += 1
            guard o.length == wl, o.kind == .ident || o.kind == .typeName || o.kind == .funcName else { continue }
            var w = Lexer.string(units, o)
            if vhdl { w = w.lowercased() }
            guard w == word else { continue }
            let r = NSRange(location: o.start, length: o.length)
            if bracket.contains(r) { continue }
            lm.addTemporaryAttribute(.backgroundColor, value: wColor, forCharacterRange: r)
            decorRanges.append(r)
            count += 1
        }
        if count == 1, let only = decorRanges.last, only.location == t.start {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: only)
            decorRanges.removeLast()
        }
    }

    // MARK: Selection

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCaret()
        updateDecorations()
        textView.needsDisplay = true
        gutter.needsDisplay = true
        if !typing && completion.isVisible { completion.hide() }
    }

    func updateCaret() {
        guard let doc else { return }
        let sel = textView.selectedRange()
        let loc = min(sel.location, units.count)
        let line = lineIndex(for: loc)
        let ls = lineStarts[line]
        var col = 0
        let tab = doc.tabSize
        var i = ls
        while i < loc && i < units.count {
            if units[i] == 9 { col += tab - (col % tab) } else if units[i] & 0xFC00 != 0xDC00 { col += 1 }
            i += 1
        }
        var info = CaretInfo()
        info.line = line + 1
        info.column = col + 1
        info.selected = sel.length
        if sel.length > 0 {
            info.selectedLines = lineIndex(for: NSMaxRange(sel)) - line + 1
        }
        info.totalLines = lineStarts.count
        if let k = tokenIndex(touching: loc), tokens[k].kind == .number {
            info.numberHint = NumberInfo.describe(Lexer.string(units, tokens[k]))
        }
        info.symbolPath = doc.symbols.path(at: line).map { s in
            s.kind == .process ? s.name : s.name
        }
        if info != doc.caret { doc.caret = info }
    }

    // MARK: Navigation

    func reveal(line: Int, column: Int? = nil, length: Int = 0) {
        guard scrollView.window != nil else {
            pendingReveal = (line, column, length)
            return
        }
        ensureFresh()
        let l = min(max(0, line - 1), lineStarts.count - 1)
        let lr = lineRange(l)
        var off = lr.location
        if let c = column { off += min(max(0, c - 1), lr.length) }
        let range = NSRange(location: off, length: min(length, max(0, storage.length - off)))
        textView.setSelectedRange(range)
        center(range)
        textView.window?.makeFirstResponder(textView)
    }

    func select(_ range: NSRange) {
        guard NSMaxRange(range) <= storage.length else { return }
        textView.setSelectedRange(range)
        if scrollView.window == nil {
            pendingReveal = (lineIndex(for: range.location) + 1, range.location - lineStarts[lineIndex(for: range.location)] + 1, range.length)
            return
        }
        center(range)
        textView.window?.makeFirstResponder(textView)
    }

    func center(_ range: NSRange) {
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, NSMaxRange(range) + 1)))
        textView.scrollRangeToVisible(range)
        guard range.location <= storage.length, storage.length > 0 else { return }
        let g = layoutManager.glyphIndexForCharacter(at: min(range.location, storage.length - 1))
        let rect = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let clip = scrollView.contentView
        let vis = clip.bounds
        let y = rect.minY + textView.textContainerOrigin.y
        if y < vis.minY + lineHeight * 2 || y > vis.maxY - lineHeight * 3 {
            let target = max(0, y - vis.height / 3)
            clip.scroll(to: NSPoint(x: vis.minX, y: min(target, max(0, textView.frame.height - vis.height))))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Called once the scroll view is in a window.
    func didAttach() {
        scrollView.tile()
        if settings.wordWrap { applyWrap() }
        gutter.updateThickness()
        if let p = pendingReveal {
            pendingReveal = nil
            DispatchQueue.main.async { [weak self] in self?.reveal(line: p.line, column: p.column, length: p.length) }
        }
        highlightAll()
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Editing primitives

    var string: NSString { textView.string as NSString }

    /// Replaces a range as one undoable edit.
    func replace(_ range: NSRange, with s: String, select: NSRange? = nil) {
        guard textView.shouldChangeText(in: range, replacementString: s) else { return }
        storage.replaceCharacters(in: range, with: s)
        textView.didChangeText()
        if let select, NSMaxRange(select) <= storage.length { textView.setSelectedRange(select) }
        textView.breakUndoCoalescing()
    }

    /// Full lines covered by the selection (including the final newline when present).
    func selectedLinesRange() -> NSRange {
        let sel = textView.selectedRange()
        var r = sel
        if r.length > 0 && NSMaxRange(r) > 0 && NSMaxRange(r) <= string.length && string.character(at: NSMaxRange(r) - 1) == 10 {
            r.length -= 1
        }
        return string.lineRange(for: r)
    }

    var indentUnit: String { doc?.indentUnit ?? "    " }
    var tabSize: Int { doc?.tabSize ?? 4 }

    func leadingWhitespace(ofLineAt offset: Int) -> String {
        let lr = string.lineRange(for: NSRange(location: offset, length: 0))
        return TextUtil.leadingWhitespace(string.substring(with: lr))
    }

    // MARK: Line commands

    func toggleComment() {
        guard let marker = doc?.language.lineComment else { return }
        let block = selectedLinesRange()
        let sel = textView.selectedRange()
        let text = string.substring(with: block)
        let hasNL = text.hasSuffix("\n")
        var lines = (hasNL ? String(text.dropLast()) : text).components(separatedBy: "\n")
        let nonBlank = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonBlank.isEmpty else { return }
        let all = nonBlank.allSatisfy { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
        var delta = 0
        if all {
            for i in nonBlank {
                let l = lines[i]
                let lead = TextUtil.leadingWhitespace(l)
                var rest = String(l.dropFirst(lead.count))
                rest.removeFirst(marker.count)
                var removed = marker.utf16.count
                if rest.hasPrefix(" ") { rest.removeFirst(); removed += 1 }
                lines[i] = lead + rest
                if i == 0 { delta = -removed }
            }
        } else {
            let minIndent = nonBlank.map { TextUtil.leadingWhitespace(lines[$0]).count }.min() ?? 0
            for i in nonBlank {
                let l = lines[i]
                let idx = l.index(l.startIndex, offsetBy: minIndent)
                lines[i] = String(l[..<idx]) + marker + " " + String(l[idx...])
            }
            delta = marker.utf16.count + 1
        }
        let newText = lines.joined(separator: "\n") + (hasNL ? "\n" : "")
        let newSel: NSRange
        if sel.length == 0 {
            newSel = NSRange(location: max(block.location, sel.location + delta), length: 0)
        } else {
            newSel = NSRange(location: block.location, length: newText.utf16.count - (hasNL ? 1 : 0))
        }
        replace(block, with: newText, select: newSel)
    }

    func indentLines(_ dir: Int) {
        let block = selectedLinesRange()
        let sel = textView.selectedRange()
        let text = string.substring(with: block)
        let hasNL = text.hasSuffix("\n")
        var lines = (hasNL ? String(text.dropLast()) : text).components(separatedBy: "\n")
        var firstDelta = 0
        for i in lines.indices {
            let l = lines[i]
            if dir > 0 {
                if l.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { continue }
                lines[i] = indentUnit + l
                if i == 0 { firstDelta = indentUnit.utf16.count }
            } else {
                var removed = 0
                var s = Substring(l)
                if s.hasPrefix("\t") { s = s.dropFirst(); removed = 1 } else {
                    while removed < tabSize && s.hasPrefix(" ") { s = s.dropFirst(); removed += 1 }
                }
                lines[i] = String(s)
                if i == 0 { firstDelta = -removed }
            }
        }
        let newText = lines.joined(separator: "\n") + (hasNL ? "\n" : "")
        let newSel: NSRange
        if sel.length == 0 {
            newSel = NSRange(location: max(block.location, sel.location + firstDelta), length: 0)
        } else {
            newSel = NSRange(location: block.location, length: newText.utf16.count - (hasNL ? 1 : 0))
        }
        replace(block, with: newText, select: newSel)
    }

    func moveLines(up: Bool) {
        let sel = textView.selectedRange()
        let block = selectedLinesRange()
        let len = string.length
        if up {
            guard block.location > 0 else { return }
            let prev = string.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var a = string.substring(with: prev)
            var b = string.substring(with: block)
            if !b.hasSuffix("\n") { b += "\n"; a = String(a.dropLast()) }
            replace(NSRange(location: prev.location, length: prev.length + block.length), with: b + a,
                    select: NSRange(location: sel.location - prev.length, length: sel.length))
        } else {
            guard NSMaxRange(block) < len else { return }
            let next = string.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            var a = string.substring(with: block)
            var c = string.substring(with: next)
            if !c.hasSuffix("\n") { c += "\n"; a = String(a.dropLast()) }
            replace(NSRange(location: block.location, length: block.length + next.length), with: c + a,
                    select: NSRange(location: sel.location + c.utf16.count, length: sel.length))
        }
    }

    func duplicateLines(up: Bool) {
        let sel = textView.selectedRange()
        let block = selectedLinesRange()
        var b = string.substring(with: block)
        if !b.hasSuffix("\n") {
            // last line: insert "\n" + block after it
            let ins = "\n" + b
            replace(NSRange(location: NSMaxRange(block), length: 0), with: ins,
                    select: up ? sel : NSRange(location: sel.location + ins.utf16.count, length: sel.length))
            return
        }
        b = string.substring(with: block)
        replace(NSRange(location: block.location, length: 0), with: b,
                select: up ? sel : NSRange(location: sel.location + b.utf16.count, length: sel.length))
    }

    func deleteLines() {
        var block = selectedLinesRange()
        if NSMaxRange(block) == string.length && block.location > 0 && !(string.substring(with: block).hasSuffix("\n")) {
            block = NSRange(location: block.location - 1, length: block.length + 1)
        }
        let col = textView.selectedRange().location - string.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0)).location
        replace(block, with: "", select: nil)
        let lr = string.lineRange(for: NSRange(location: min(block.location, string.length), length: 0))
        let lineLen = string.substring(with: lr).trimmingCharacters(in: .newlines).utf16.count
        textView.setSelectedRange(NSRange(location: min(lr.location + min(col, lineLen), string.length), length: 0))
    }

    func insertLine(below: Bool) {
        let sel = textView.selectedRange()
        let lr = string.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = string.substring(with: lr)
        var indent = TextUtil.leadingWhitespace(line)
        if below, let lang = doc?.language, TextUtil.increasesIndent(TextUtil.stripComment(line.trimmingCharacters(in: .newlines), language: lang), language: lang) {
            indent += indentUnit
        }
        if below {
            let hasNL = line.hasSuffix("\n")
            let at = hasNL ? NSMaxRange(lr) - 1 : NSMaxRange(lr)
            replace(NSRange(location: at, length: 0), with: "\n" + indent, select: NSRange(location: at + 1 + indent.utf16.count, length: 0))
        } else {
            replace(NSRange(location: lr.location, length: 0), with: indent + "\n", select: NSRange(location: lr.location + indent.utf16.count, length: 0))
        }
    }

    func selectLine() {
        let sel = textView.selectedRange()
        let block = selectedLinesRange()
        if sel == block, NSMaxRange(block) < string.length {
            let next = string.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            textView.setSelectedRange(NSRange(location: block.location, length: NSMaxRange(next) - block.location))
        } else {
            textView.setSelectedRange(block)
        }
    }

    func jumpToMatchingBracket() {
        let off = textView.selectedRange().location
        for probe in [off, off - 1] where probe >= 0 {
            if let k = tokenIndex(touching: probe), let m = pairs[k] {
                let t = tokens[m]
                let target = m > k ? t.start : t.start
                textView.setSelectedRange(NSRange(location: target, length: 0))
                textView.scrollRangeToVisible(NSRange(location: target, length: 0))
                return
            }
        }
    }

    /// Re-indents the selected lines (or the whole file) from the begin/end structure.
    @discardableResult
    func reindent(all: Bool) -> Bool {
        guard let lang = doc?.language, lang.isVerilogFamily else { return false }
        ensureFresh()
        let levels = Structure.indentLevels(units, tokens, language: lang)
        let sel = textView.selectedRange()
        let block = (all || sel.length == 0) ? NSRange(location: 0, length: string.length) : selectedLinesRange()
        let firstLine = lineIndex(for: block.location)
        let text = string.substring(with: block)
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            let li = firstLine + i
            guard li < levels.count, let lvl = levels[li] else { continue }
            let l = lines[i]
            let body = l.drop { $0 == " " || $0 == "\t" }
            if body.isEmpty || body == "\r" { lines[i] = String(body); continue }
            lines[i] = String(repeating: indentUnit, count: lvl) + body
        }
        let newText = lines.joined(separator: "\n")
        guard newText != text else { return true }
        let caretLine = lineIndex(for: sel.location)
        let caretCol = sel.location - lineStarts[caretLine]
        let oldLead = TextUtil.leadingWhitespace(lineText(caretLine)).utf16.count
        replace(block, with: newText, select: nil)
        if sel.length == 0 {
            let lr = lineRange(min(caretLine, lineCount - 1))
            let newLead = TextUtil.leadingWhitespace(string.substring(with: lr)).utf16.count
            let col = max(newLead, caretCol - oldLead + newLead)
            textView.setSelectedRange(NSRange(location: min(lr.location + col, NSMaxRange(lr)), length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: block.location, length: newText.utf16.count))
        }
        return true
    }

    func trimTrailingWhitespace() {
        let text = textView.string
        var lines = text.components(separatedBy: "\n")
        var changed = false
        for i in lines.indices {
            var l = lines[i]
            let cr = l.hasSuffix("\r")
            if cr { l.removeLast() }
            let t = String(l.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
            if t != l { changed = true }
            lines[i] = t + (cr ? "\r" : "")
        }
        guard changed else { return }
        let sel = textView.selectedRange()
        let caretLine = lineIndex(for: sel.location)
        let caretCol = sel.location - lineStarts[caretLine]
        let new = lines.joined(separator: "\n")
        replace(NSRange(location: 0, length: string.length), with: new, select: nil)
        let lr = lineRange(min(caretLine, lineCount - 1))
        textView.setSelectedRange(NSRange(location: min(lr.location + caretCol, NSMaxRange(lr)), length: 0))
    }

    func ensureFinalNewline() {
        guard string.length > 0, string.character(at: string.length - 1) != 10 else { return }
        let sel = textView.selectedRange()
        replace(NSRange(location: string.length, length: 0), with: "\n", select: sel)
    }

    func convertIndentation(toSpaces: Bool) {
        let text = textView.string
        let size = tabSize
        let lines = text.components(separatedBy: "\n").map { l -> String in
            let lead = TextUtil.leadingWhitespace(l)
            let width = TextUtil.indentWidth(lead, tabSize: size)
            return TextUtil.makeIndent(width, tabSize: size, useSpaces: toSpaces) + l.dropFirst(lead.count)
        }
        let new = lines.joined(separator: "\n")
        doc?.useSpaces = toSpaces
        guard new != text else { return }
        replace(NSRange(location: 0, length: string.length), with: new, select: NSRange(location: 0, length: 0))
    }

    // MARK: Snippets & placeholders

    func insertSnippet(_ s: Snippet, replacing range: NSRange? = nil) {
        let r = range ?? textView.selectedRange()
        let base = leadingWhitespace(ofLineAt: r.location)
        insertTemplate(s.expand(baseIndent: base, unit: indentUnit), replacing: r)
    }

    /// Inserts multi-line text and selects its first placeholder.
    func insertTemplate(_ text: String, replacing r: NSRange) {
        replace(r, with: text, select: NSRange(location: r.location + text.utf16.count, length: 0))
        let inserted = NSRange(location: r.location, length: text.utf16.count)
        let found = string.range(of: "<#[^#\\n]*#>", options: .regularExpression, range: inserted)
        if found.location != NSNotFound { textView.setSelectedRange(found) }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Inserts text at the caret, indenting continuation lines like the current line.
    func insertBlock(_ text: String) {
        let r = textView.selectedRange()
        let base = leadingWhitespace(ofLineAt: r.location)
        let lines = text.components(separatedBy: "\n")
        let indented = lines.enumerated().map { $0.offset == 0 || $0.element.isEmpty ? $0.element : base + $0.element }.joined(separator: "\n")
        insertTemplate(indented, replacing: r)
    }

    @discardableResult
    func selectPlaceholder(forward: Bool) -> Bool {
        let len = string.length
        guard len > 0 else { return false }
        let sel = textView.selectedRange()
        let pattern = "<#[^#\\n]*#>"
        var found: NSRange
        if forward {
            let from = NSMaxRange(sel)
            found = string.range(of: pattern, options: .regularExpression, range: NSRange(location: from, length: len - from))
            if found.location == NSNotFound {
                found = string.range(of: pattern, options: .regularExpression, range: NSRange(location: 0, length: min(len, sel.location)))
            }
        } else {
            found = string.range(of: pattern, options: [.regularExpression, .backwards], range: NSRange(location: 0, length: sel.location))
            if found.location == NSNotFound {
                let from = NSMaxRange(sel)
                found = string.range(of: pattern, options: [.regularExpression, .backwards], range: NSRange(location: from, length: len - from))
            }
        }
        guard found.location != NSNotFound, found != sel else { return false }
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        return true
    }

    var selectionIsPlaceholder: Bool {
        let sel = textView.selectedRange()
        guard sel.length >= 4 else { return false }
        let s = string.substring(with: sel)
        return s.hasPrefix("<#") && s.hasSuffix("#>") && !s.contains("\n")
    }

    // MARK: Words

    /// Identifier (or `macro / $task) at an offset.
    func word(at offset: Int) -> (String, NSRange)? {
        guard let k = tokenIndex(touching: offset) else { return nil }
        let t = tokens[k]
        switch t.kind {
        case .ident, .typeName, .funcName, .directive, .system, .type, .keyword, .control:
            return (Lexer.string(units, t), NSRange(location: t.start, length: t.length))
        default: return nil
        }
    }

    var selectedOrCaretWord: String? {
        let sel = textView.selectedRange()
        if sel.length > 0 && sel.length < 200 { return string.substring(with: sel) }
        return word(at: sel.location)?.0
    }

    // MARK: Find bar

    func performFind(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.window?.makeFirstResponder(textView)
        textView.performTextFinderAction(item)
    }
}
