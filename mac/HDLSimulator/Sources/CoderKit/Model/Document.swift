import AppKit
import Observation

struct CaretInfo: Equatable {
    var line = 1
    var column = 1
    var selected = 0
    var selectedLines = 0
    var totalLines = 1
    var numberHint: String?
    var symbolPath: [String] = []
}

/// Global editor preferences (stored in UserDefaults under "editor.*").
struct EditorSettings: Equatable {
    var fontSize: Double = 13
    var fontName = ""
    var tabSize = 4
    var insertSpaces = true
    var wordWrap = false
    var autoClose = true
    var autoEnd = true
    var suggest = true
    var highlightLine = true
    var indentGuides = true
    var inlineDiagnostics = true
    var showInvisibles = false
    var lineHeight: Double = 1.45

    var font: NSFont {
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: fontSize) { return f }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static func load() -> EditorSettings {
        let d = UserDefaults.standard
        var s = EditorSettings()
        if let v = d.object(forKey: "editor.fontSize") as? Double { s.fontSize = min(max(v, 8), 36) }
        s.fontName = d.string(forKey: "editor.fontName") ?? ""
        if let v = d.object(forKey: "editor.tabSize") as? Int { s.tabSize = min(max(v, 1), 16) }
        if let v = d.object(forKey: "editor.insertSpaces") as? Bool { s.insertSpaces = v }
        if let v = d.object(forKey: "editor.wordWrap") as? Bool { s.wordWrap = v }
        if let v = d.object(forKey: "editor.autoClose") as? Bool { s.autoClose = v }
        if let v = d.object(forKey: "editor.autoEnd") as? Bool { s.autoEnd = v }
        if let v = d.object(forKey: "editor.suggest") as? Bool { s.suggest = v }
        if let v = d.object(forKey: "editor.highlightLine") as? Bool { s.highlightLine = v }
        if let v = d.object(forKey: "editor.indentGuides") as? Bool { s.indentGuides = v }
        if let v = d.object(forKey: "editor.inlineDiagnostics") as? Bool { s.inlineDiagnostics = v }
        if let v = d.object(forKey: "editor.showInvisibles") as? Bool { s.showInvisibles = v }
        return s
    }
}

@MainActor
@Observable
final class EditorDocument: Identifiable {
    let id: UUID
    var url: URL? {
        didSet { if url != oldValue { language = HDLLanguage.detect(url) } }
    }
    var untitledName: String
    var language: HDLLanguage {
        didSet { if language != oldValue { _editor?.languageChanged() } }
    }
    var isDirty = false
    var symbols: [HDLSymbol] = []
    var diagnostics: [Diagnostic] = []
    var caret = CaretInfo()
    var useSpaces: Bool
    var tabSize: Int
    var changedOnDisk = false
    var lineEnding = "LF"
    /// Where Save first proposes to put an untitled file.
    var suggestedDirectory: URL?

    @ObservationIgnored var savedText: String
    @ObservationIgnored var diskDate: Date?
    @ObservationIgnored var initialSelection: NSRange?
    @ObservationIgnored private var initialText: String
    @ObservationIgnored private var _editor: EditorController?

    init(url: URL?, text: String, untitledName: String = "Untitled", id: UUID = UUID(), savedText: String? = nil) {
        self.id = id
        self.url = url?.standardizedFileURL
        self.untitledName = untitledName
        self.language = url.map { HDLLanguage.detect($0) } ?? HDLLanguage.detect(URL(fileURLWithPath: untitledName))
        self.initialText = text
        self.savedText = savedText ?? text
        let settings = EditorSettings.load()
        let detected = Self.detectIndent(text)
        self.useSpaces = detected?.spaces ?? settings.insertSpaces
        self.tabSize = detected.flatMap { $0.spaces ? $0.size : nil } ?? settings.tabSize
        self.lineEnding = text.contains("\r\n") ? "CRLF" : "LF"
        if let url { diskDate = Workspace.modDate(url) }
        isDirty = text != self.savedText
        symbols = SymbolScanner.scan(text, language: language)
    }

    var editor: EditorController {
        if let e = _editor { return e }
        let e = EditorController(doc: self, text: initialText)
        _editor = e
        initialText = ""
        return e
    }

    var hasEditor: Bool { _editor != nil }

    var text: String { _editor?.textView.string ?? initialText }

    var key: String { url?.path ?? "untitled:\(id.uuidString)" }

    var name: String { url?.lastPathComponent ?? untitledName }

    var indentUnit: String { useSpaces ? String(repeating: " ", count: tabSize) : "\t" }

    /// Sets the whole text (used when reloading from disk).
    func replaceAll(with text: String, markSaved: Bool) {
        if let e = _editor {
            e.setText(text)
        } else {
            initialText = text
            symbols = SymbolScanner.scan(text, language: language)
        }
        if markSaved {
            savedText = text
            isDirty = false
        }
    }

    /// Guesses the file's indentation: tabs, or spaces with a size.
    static func detectIndent(_ text: String) -> (spaces: Bool, size: Int)? {
        var tabs = 0, spaces = 0
        var widths: [Int: Int] = [:]
        var prev = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2000) {
            guard let f = line.first else { continue }
            if f == "\t" { tabs += 1; continue }
            if f == " " {
                let n = line.prefix { $0 == " " }.count
                if line.dropFirst(n).hasPrefix("*") { continue }  // block comment continuation
                spaces += 1
                let d = abs(n - prev)
                if d >= 2 && d <= 8 { widths[d, default: 0] += 1 }
                prev = n
            } else {
                prev = 0
            }
        }
        if tabs == 0 && spaces == 0 { return nil }
        if tabs > spaces { return (false, 4) }
        let size = widths.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key ?? 4
        return (true, [2, 3, 4, 8].contains(size) ? size : 4)
    }
}
