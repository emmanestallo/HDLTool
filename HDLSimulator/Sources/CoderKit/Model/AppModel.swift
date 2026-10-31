import AppKit
import HDLShell
import Observation
import UniformTypeIdentifiers

enum SidebarMode: String, CaseIterable {
    case explorer, search, outline, hierarchy, snippets

    var title: String {
        switch self {
        case .explorer: return "EXPLORER"
        case .search: return "SEARCH"
        case .outline: return "OUTLINE"
        case .hierarchy: return "DESIGN HIERARCHY"
        case .snippets: return "SNIPPETS"
        }
    }

    var icon: String {
        switch self {
        case .explorer: return "doc.on.doc"
        case .search: return "magnifyingglass"
        case .outline: return "list.bullet.indent"
        case .hierarchy: return "point.3.filled.connected.trianglepath.dotted"
        case .snippets: return "text.badge.plus"
        }
    }

    var help: String {
        switch self {
        case .explorer: return "Explorer (⇧⌘E)"
        case .search: return "Search (⇧⌘F)"
        case .outline: return "Outline"
        case .hierarchy: return "Design Hierarchy"
        case .snippets: return "Snippets"
        }
    }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case problems, output
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum PaletteMode: Equatable {
    case files, commands, symbols, line, modules, instance, snippet, theme, newFile, language

    var placeholder: String {
        switch self {
        case .files: return "Search files by name (type > for commands, @ for symbols, : for a line, # for modules)"
        case .commands: return "Type a command"
        case .symbols: return "Go to symbol in file"
        case .line: return "Type a line number"
        case .modules: return "Go to module or entity in the workspace"
        case .instance: return "Choose a module to instantiate at the cursor"
        case .snippet: return "Choose a snippet to insert"
        case .theme: return "Select a color theme"
        case .newFile: return "Choose a template for the new file"
        case .language: return "Select the language of this file"
        }
    }

    var prefix: String {
        switch self {
        case .commands: return ">"
        case .symbols: return "@"
        case .line: return ":"
        case .modules: return "#"
        default: return ""
        }
    }
}

struct AppCommand: Identifiable {
    let id: String
    let title: String
    let shortcut: String
    let action: @MainActor () -> Void
}

struct NavLocation: Equatable {
    var path: String?
    var docID: UUID
    var offset: Int
}

struct SearchState {
    var options = SearchOptions()
    var replace = ""
    var showReplace = false
    var results: [SearchFileResult] = []
    var running = false
    var collapsed: Set<String> = []
    var searched = false
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let tools = Tools()
    let workspace = Workspace()
    var docs: [EditorDocument] = []
    var activeID: UUID?
    var sidebarMode: SidebarMode? = .explorer
    var showPanel = false
    var panelTab: PanelTab = .problems
    var problemsByOwner: [String: [Diagnostic]] = [:]
    var linting: Set<String> = []
    var lastLintTool: String?
    var output: [LogLine] = []
    var runStatus: RunStatus = .idle
    var process: Process?
    var lastVCD: URL?
    var lastRunSeconds: Double?
    var paletteMode: PaletteMode?
    var paletteText = ""
    var toast: String?
    var recentFolders: [String]
    var recentFiles: [String]
    var search = SearchState()
    var openWaveformsInViewer: Bool {
        didSet { UserDefaults.standard.set(openWaveformsInViewer, forKey: "openWaveformsInViewer") }
    }

    @ObservationIgnored var sessionEnabled = true
    @ObservationIgnored private var lastSession: Data?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var lintTimers: [UUID: Timer] = [:]
    @ObservationIgnored private var lintGen: [UUID: Int] = [:]
    @ObservationIgnored private var toastTimer: Timer?
    @ObservationIgnored private var navBack: [NavLocation] = []
    @ObservationIgnored private var navForward: [NavLocation] = []
    @ObservationIgnored private var untitledCounter = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private init() {
        recentFolders = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        recentFiles = UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []
        openWaveformsInViewer = UserDefaults.standard.object(forKey: "openWaveformsInViewer") as? Bool ?? true
    }

    func start() {
        tools.detect()
        registerWithShell()
        if sessionEnabled { restoreSession() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.onTimer() }
        }
    }

    var active: EditorDocument? {
        guard let activeID else { return nil }
        return docs.first { $0.id == activeID }
    }

    var activeEditor: EditorController? { active?.editor }

    var languageStandard: String { UserDefaults.standard.string(forKey: "languageStandard") ?? "-g2012" }

    // MARK: Documents

    func activate(_ doc: EditorDocument) {
        activeID = doc.id
        if let url = doc.url { workspace.reveal(url) }
    }

    @discardableResult
    func newFile(kind: Templates.Kind = .empty, name: String? = nil, text: String? = nil, language: HDLLanguage? = nil) -> EditorDocument {
        untitledCounter += 1
        let n = name ?? "Untitled-\(untitledCounter)"
        let fileName = n.contains(".") ? n : n + "." + (language == .vhdl ? "vhd" : (language == .systemVerilog ? "sv" : kind.ext))
        let body = text ?? Templates.newFile(kind, name: kind == .empty ? "" : (n.contains(".") ? (n as NSString).deletingPathExtension : n), unit: indentUnitSetting)
        let doc = EditorDocument(url: nil, text: body, untitledName: fileName, savedText: "")
        if let language { doc.language = language }
        doc.isDirty = !body.isEmpty
        replaceEmptyUntitled()
        docs.append(doc)
        activate(doc)
        scheduleLint(doc, delay: 0.3)
        return doc
    }

    var indentUnitSetting: String {
        let s = EditorSettings.load()
        return s.insertSpaces ? String(repeating: " ", count: s.tabSize) : "\t"
    }

    /// Removes a single untouched empty untitled tab before opening something else.
    private func replaceEmptyUntitled() {
        if docs.count == 1, let only = docs.first, only.url == nil, only.text.isEmpty, !only.isDirty {
            docs = []
        }
    }

    func open(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { openFolder(url) } else { openFile(url) }
        }
    }

    @discardableResult
    func openFile(_ url: URL, line: Int? = nil, column: Int? = nil, length: Int = 0, recordHistory: Bool = true) -> EditorDocument? {
        let url = url.standardizedFileURL
        let ext = url.pathExtension.lowercased()
        if ext == "vcd" || ext == "fst" || ext == "lxt" || ext == "ghw" {
            Simulator.openInViewer(url)
            return nil
        }
        if ext == "hdltest" {
            Shell.shared.openInTester?([url])
            Shell.shared.show(.tester)
            return nil
        }
        if recordHistory { recordNav() }
        if let existing = docs.first(where: { $0.url?.path == url.path }) {
            activate(existing)
            if let line { existing.editor.reveal(line: line, column: column, length: length) }
            return existing
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            alert("Could not open “\(url.lastPathComponent)”", "The file could not be read.")
            return nil
        }
        if data.prefix(8192).contains(0) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let doc = EditorDocument(url: url, text: text)
        replaceEmptyUntitled()
        docs.append(doc)
        activate(doc)
        addRecentFile(url.path)
        if let root = workspace.root, url.path.hasPrefix(root.path + "/") {
            // indexed with the folder
        } else if !workspace.extraFiles.contains(url.path), doc.language != .plain {
            workspace.extraFiles.append(url.path)
            workspace.scan()
        }
        if let line { doc.editor.reveal(line: line, column: column, length: length) }
        scheduleLint(doc, delay: 0.2)
        return doc
    }

    func openFolder(_ url: URL) {
        workspace.setRoot(url)
        addRecentFolder(url.path)
        sidebarMode = .explorer
    }

    func closeFolder() {
        workspace.setRoot(nil)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose HDL files or a project folder"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a project folder"
        if panel.runModal() == .OK, let u = panel.url { openFolder(u) }
    }

    @discardableResult
    func close(_ doc: EditorDocument) -> Bool {
        if doc.isDirty && !(doc.url == nil && doc.text.isEmpty) {
            let a = NSAlert()
            a.messageText = "Do you want to save the changes you made to “\(doc.name)”?"
            a.informativeText = "Your changes will be lost if you don’t save them."
            a.addButton(withTitle: "Save")
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Don’t Save")
            switch a.runModal() {
            case .alertFirstButtonReturn:
                activeID = doc.id
                guard save(doc) else { return false }
            case .alertSecondButtonReturn:
                return false
            default: break
            }
        }
        guard let i = docs.firstIndex(where: { $0.id == doc.id }) else { return true }
        doc.editor.completion.hide()
        docs.remove(at: i)
        problemsByOwner[doc.key] = nil
        refreshDiagnostics()
        if let p = doc.url?.path { workspace.dropLive(path: p) }
        if activeID == doc.id {
            activeID = docs.isEmpty ? nil : docs[min(i, docs.count - 1)].id
        }
        return true
    }

    func closeActive() { if let a = active { close(a) } }

    func closeOthers(_ keep: EditorDocument) {
        for d in docs where d.id != keep.id { if !close(d) { return } }
    }

    func closeAll() {
        for d in docs { if !close(d) { return } }
    }

    // MARK: Saving

    @discardableResult
    func save(_ doc: EditorDocument, as saveAs: Bool = false) -> Bool {
        var url = doc.url
        if saveAs || url == nil {
            let panel = NSSavePanel()
            var name = doc.name
            if doc.url == nil, let m = doc.symbols.first(where: { $0.kind.isContainer }) {
                name = m.name + "." + (doc.untitledName as NSString).pathExtension
            }
            panel.nameFieldStringValue = name
            panel.directoryURL = doc.url?.deletingLastPathComponent() ?? doc.suggestedDirectory ?? workspace.root
            panel.allowsOtherFileTypes = true
            guard panel.runModal() == .OK, let u = panel.url else { return false }
            url = u
        }
        guard let url else { return false }
        if doc.hasEditor {
            if UserDefaults.standard.object(forKey: "trimTrailingWhitespace") as? Bool ?? true { doc.editor.trimTrailingWhitespace() }
            if UserDefaults.standard.object(forKey: "insertFinalNewline") as? Bool ?? true { doc.editor.ensureFinalNewline() }
        }
        let text = doc.text
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert("Could not save “\(url.lastPathComponent)”", error.localizedDescription)
            return false
        }
        let oldKey = doc.key
        if doc.url?.path != url.standardizedFileURL.path {
            doc.url = url
            problemsByOwner[oldKey] = nil
        }
        doc.savedText = text
        doc.isDirty = false
        doc.changedOnDisk = false
        doc.diskDate = Workspace.modDate(url)
        addRecentFile(url.path)
        workspace.updateLive(path: url.standardizedFileURL.path, language: doc.language, symbols: doc.symbols)
        if let root = workspace.root, url.path.hasPrefix(root.path) { workspace.refreshListing() }
        scheduleLint(doc, delay: 0)
        return true
    }

    func saveAll() {
        for d in docs where d.isDirty { if !save(d) { return } }
    }

    func revert(_ doc: EditorDocument) {
        guard let url = doc.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        doc.replaceAll(with: text, markSaved: true)
        doc.diskDate = Workspace.modDate(url)
        doc.changedOnDisk = false
        scheduleLint(doc, delay: 0)
    }

    // MARK: Editor events

    func textChanged(_ doc: EditorDocument) {
        if UserDefaults.standard.object(forKey: "lintWhileTyping") as? Bool ?? true {
            scheduleLint(doc, delay: 0.9)
        }
    }

    func symbolsChanged(_ doc: EditorDocument) {
        if let p = doc.url?.path { workspace.updateLive(path: p, language: doc.language, symbols: doc.symbols) }
    }

    func editorFocused(_ doc: EditorDocument) {
        if paletteMode != nil { paletteMode = nil }
    }

    // MARK: Lint

    var linterKind: Linter.Kind { Linter.Kind(rawValue: UserDefaults.standard.string(forKey: "linter") ?? "auto") ?? .auto }

    func scheduleLint(_ doc: EditorDocument, delay: TimeInterval) {
        guard doc.language != .plain, linterKind != .off else { return }
        lintTimers[doc.id]?.invalidate()
        let id = doc.id
        lintTimers[doc.id] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                let m = AppModel.shared
                if let d = m.docs.first(where: { $0.id == id }) { m.runLint(d) }
            }
        }
    }

    func runLint(_ doc: EditorDocument) {
        if !tools.checked { tools.detect() }
        let gen = (lintGen[doc.id] ?? 0) + 1
        lintGen[doc.id] = gen
        var fileName = doc.url?.lastPathComponent ?? doc.untitledName
        if (fileName as NSString).pathExtension.isEmpty { fileName += doc.language == .vhdl ? ".vhd" : (doc.language == .systemVerilog ? ".sv" : ".v") }
        let job = Linter.Job(key: doc.key, fileName: fileName, text: doc.text, originalPath: doc.url?.path,
                             language: doc.language, deps: doc.language == .vhdl ? [] : dependencyFiles(for: doc),
                             includeDirs: includeDirs(for: doc), iverilog: tools.iverilog, verilator: tools.verilator,
                             ghdl: tools.ghdl, kind: linterKind, standard: languageStandard)
        let docID = doc.id
        let key = doc.key
        linting.insert(key)
        Task.detached(priority: .userInitiated) {
            let result = Linter.run(job)
            await MainActor.run {
                let m = AppModel.shared
                m.linting.remove(key)
                guard m.lintGen[docID] == gen, let d = m.docs.first(where: { $0.id == docID }), d.key == key else { return }
                m.lastLintTool = result?.tool
                m.problemsByOwner[key] = result?.diagnostics ?? []
                m.refreshDiagnostics()
            }
        }
    }

    func lintActive() {
        if let d = active {
            runLint(d)
            panelTab = .problems
            showPanel = true
        }
    }

    var allProblems: [Diagnostic] {
        var seen = Set<String>()
        var out: [Diagnostic] = []
        for (_, list) in problemsByOwner {
            for d in list {
                let k = "\(d.file)|\(d.line)|\(d.message)"
                if seen.insert(k).inserted { out.append(d) }
            }
        }
        return out.sorted { ($0.file, $0.line, $0.severity.rawValue) < ($1.file, $1.line, $1.severity.rawValue) }
    }

    func diagnostics(for key: String) -> [Diagnostic] {
        // A file's own lint result wins; other owners add problems found while compiling it as a dependency.
        if let own = problemsByOwner[key] {
            return own.filter { $0.file == key }
        }
        return allProblems.filter { $0.file == key }
    }

    func refreshDiagnostics() {
        for d in docs {
            let list = diagnostics(for: d.key)
            if list != d.diagnostics {
                d.diagnostics = list
                if d.hasEditor { d.editor.setDiagnostics(list) }
            } else if d.hasEditor && d.editor.diagnosticsByLine.isEmpty != list.isEmpty {
                d.editor.setDiagnostics(list)
            }
        }
    }

    // MARK: Dependencies

    /// Files that define the modules (and packages) this document uses, found through the workspace index.
    func dependencyFiles(for doc: EditorDocument) -> [String] {
        let own = doc.url?.path
        let text = doc.text
        let included = Set(Simulator.includes(in: text).map { ($0 as NSString).lastPathComponent })
        let ownNames = Set(doc.symbols.map { $0.name.lowercased() })
        let docDir = doc.url?.deletingLastPathComponent().path
        var result: [String] = []
        var visited = Set<String>()
        var queue: [String] = doc.symbols.flattened().filter { $0.kind == .instance }.compactMap(\.target)
        func pick(_ name: String) -> String? {
            let defs = workspace.definitions(of: name).filter { $0.path != own }
            return (defs.first { ($0.path as NSString).deletingLastPathComponent == docDir } ?? defs.first)?.path
        }
        while let m = queue.first {
            queue.removeFirst()
            let key = m.lowercased()
            guard !visited.contains(key), !ownNames.contains(key) else { continue }
            visited.insert(key)
            guard let path = pick(m), !included.contains((path as NSString).lastPathComponent) else { continue }
            if !result.contains(path) { result.append(path) }
            for s in workspace.index[path]?.symbols ?? [] {
                queue += s.children.filter { $0.kind == .instance }.compactMap(\.target)
            }
        }
        // SystemVerilog packages: pkg::name
        var packages: [String] = []
        if doc.language.isVerilogFamily, let re = try? NSRegularExpression(pattern: "\\b([A-Za-z_][A-Za-z0-9_]*)::") {
            var texts = [text]
            for p in result { if let t = try? String(contentsOfFile: p, encoding: .utf8) { texts.append(t) } }
            for t in texts {
                let ns = t as NSString
                for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                    let name = ns.substring(with: m.range(at: 1))
                    guard !ownNames.contains(name.lowercased()) else { continue }
                    if let def = workspace.definitions(of: name).first(where: { $0.symbol.kind == .package && $0.path != own }),
                       !packages.contains(def.path), !included.contains((def.path as NSString).lastPathComponent) {
                        packages.append(def.path)
                    }
                }
            }
        }
        result.removeAll { packages.contains($0) }
        if doc.language == .vhdl { result.reverse() }
        return packages + result
    }

    func includeDirs(for doc: EditorDocument) -> [String] {
        var dirs: [String] = []
        func add(_ d: String?) { if let d, !dirs.contains(d) { dirs.append(d) } }
        add(doc.url?.deletingLastPathComponent().path)
        add(workspace.root?.path)
        for f in dependencyFiles(for: doc) { add((f as NSString).deletingLastPathComponent) }
        // folders with header files
        for (path, _) in workspace.index where path.hasSuffix(".vh") || path.hasSuffix(".svh") {
            add((path as NSString).deletingLastPathComponent)
        }
        return dirs
    }

    // MARK: Run

    func runActive() {
        guard let doc = active else { return }
        if runStatus.isRunning { Simulator.stop(self); return }
        if doc.url == nil {
            guard save(doc) else { return }
        } else if UserDefaults.standard.object(forKey: "saveBeforeRun") as? Bool ?? true {
            for d in docs where d.isDirty && d.url != nil { save(d) }
        }
        Task { await Simulator.run(doc: doc, model: self) }
    }

    func stopRun() { Simulator.stop(self) }

    func appendOutput(_ kind: LogLine.Kind, _ text: String, cwd: URL? = nil) {
        var line = LogLine(kind: kind, text: text)
        if kind == .stdout || kind == .error || kind == .warning {
            line = LogLine(kind: classify(text, kind), text: text, link: Self.parseLink(text, cwd: cwd))
        }
        output.append(line)
        if output.count > 6000 { output.removeFirst(output.count - 6000) }
    }

    private func classify(_ text: String, _ kind: LogLine.Kind) -> LogLine.Kind {
        guard kind == .stdout else { return kind }
        let l = text.lowercased()
        if l.contains("error") || l.contains("fatal") { return .error }
        if l.contains("warning") { return .warning }
        return .stdout
    }

    static let linkRegex = try! NSRegularExpression(pattern: #"([^\s:'"]+\.(?:v|sv|vh|svh|vhd|vhdl)):(\d+)"#)

    static func parseLink(_ text: String, cwd: URL?) -> (path: String, line: Int)? {
        let ns = text as NSString
        guard let m = linkRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var p = ns.substring(with: m.range(at: 1))
        if !p.hasPrefix("/"), let cwd { p = cwd.appendingPathComponent(p).standardizedFileURL.path }
        guard FileManager.default.fileExists(atPath: p) else { return nil }
        return (p, Int(ns.substring(with: m.range(at: 2))) ?? 1)
    }

    func openLastWaveform() {
        if let v = lastVCD { Simulator.openInViewer(v) } else { showToast("No waveform yet — run a testbench first (⌘R)") }
    }

    func openActiveInTester() {
        generateTestbenchInTester()
    }

    // MARK: Navigation

    private func currentLocation() -> NavLocation? {
        guard let d = active, d.hasEditor else { return nil }
        return NavLocation(path: d.url?.path, docID: d.id, offset: d.editor.textView.selectedRange().location)
    }

    func recordNav() {
        guard let loc = currentLocation() else { return }
        if navBack.last != loc { navBack.append(loc) }
        if navBack.count > 100 { navBack.removeFirst() }
        navForward = []
    }

    private func go(to loc: NavLocation) {
        if let d = docs.first(where: { $0.id == loc.docID }) ?? loc.path.flatMap({ p in docs.first { $0.url?.path == p } }) {
            activate(d)
            d.editor.select(NSRange(location: min(loc.offset, (d.text as NSString).length), length: 0))
        } else if let p = loc.path, let d = openFile(URL(fileURLWithPath: p), recordHistory: false) {
            d.editor.select(NSRange(location: min(loc.offset, (d.text as NSString).length), length: 0))
        }
    }

    func goBack() {
        guard let loc = navBack.popLast() else { return }
        if let cur = currentLocation() { navForward.append(cur) }
        go(to: loc)
    }

    func goForward() {
        guard let loc = navForward.popLast() else { return }
        if let cur = currentLocation() { navBack.append(cur) }
        go(to: loc)
    }

    func goTo(path: String, line: Int, column: Int? = nil, length: Int = 0) {
        if path.hasPrefix("untitled:"), let d = docs.first(where: { $0.key == path }) {
            recordNav()
            activate(d)
            d.editor.reveal(line: line, column: column, length: length)
            return
        }
        openFile(URL(fileURLWithPath: path), line: line, column: column, length: length)
    }

    func goTo(symbol s: HDLSymbol, path: String?) {
        if let path, path != active?.url?.path {
            openFile(URL(fileURLWithPath: path))
        } else {
            recordNav()
        }
        guard let d = path.flatMap({ p in docs.first { $0.url?.path == p } }) ?? active else { return }
        let len = (d.text as NSString).length
        if s.offset + s.name.utf16.count <= len {
            d.editor.select(NSRange(location: s.offset, length: s.name.utf16.count))
        } else {
            d.editor.reveal(line: s.line + 1)
        }
    }

    func goToDefinition(word raw: String, in doc: EditorDocument, offset: Int) {
        let vhdl = doc.language == .vhdl
        let word = raw
        func same(_ a: String, _ b: String) -> Bool { vhdl ? a.lowercased() == b.lowercased() : a == b }

        // `define macro
        if word.hasPrefix("`") {
            let name = String(word.dropFirst())
            let pattern = "`define\\s+\(NSRegularExpression.escapedPattern(for: name))\\b"
            var candidates: [(String, String)] = [(doc.key, doc.text)]
            for (p, _) in workspace.index where p != doc.url?.path {
                if let t = try? String(contentsOfFile: p, encoding: .utf8) { candidates.append((p, t)) }
            }
            for (p, t) in candidates {
                let ns = t as NSString
                let r = ns.range(of: pattern, options: .regularExpression)
                if r.location != NSNotFound {
                    let line = ns.substring(to: r.location).components(separatedBy: "\n").count
                    goTo(path: p, line: line)
                    return
                }
            }
            showToast("No `define found for \(name)")
            return
        }
        let editor = doc.editor
        let line = editor.lineIndex(for: offset)
        let path = doc.symbols.path(at: line)

        // .port(...) in an instance → the port in the instantiated module
        if offset > 0, let (_, r) = editor.word(at: offset), r.location > 0 {
            var p = r.location - 1
            while p > 0 && (editor.units[p] == 32 || editor.units[p] == 9) { p -= 1 }
            if editor.units[p] == 46, let inst = path.last(where: { $0.kind == .instance }), let target = inst.target,
               let def = workspace.definitions(of: target).first,
               let port = def.symbol.children.first(where: { ($0.kind == .port || $0.kind == .param) && same($0.name, word) }) {
                goTo(symbol: port, path: def.path)
                return
            }
        }
        // `include "file"
        let lineText = editor.lineText(line)
        if lineText.contains("`include"), let q1 = lineText.firstIndex(of: "\""), let q2 = lineText[lineText.index(after: q1)...].firstIndex(of: "\"") {
            let name = String(lineText[lineText.index(after: q1)..<q2])
            for dir in includeDirs(for: doc) {
                let p = (dir as NSString).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: p) { openFile(URL(fileURLWithPath: p)); return }
            }
        }
        // Declaration inside the enclosing module/architecture
        if let container = path.first {
            var scope = container.children
            if container.kind == .architecture, let ent = container.target,
               let e = doc.symbols.first(where: { $0.kind == .entity && same($0.name, ent) }) ?? workspace.definitions(of: ent).first?.symbol {
                scope += e.children
            }
            if let s = scope.first(where: { same($0.name, word) && $0.kind != .instance && $0.offset != (editor.word(at: offset)?.1.location ?? -1) })
                ?? scope.first(where: { same($0.name, word) }) {
                goTo(symbol: s, path: doc.url?.path)
                return
            }
        }
        // Module / entity / package anywhere in the workspace
        if let def = workspace.definitions(of: word).first(where: { $0.path == doc.url?.path }) ?? workspace.definitions(of: word).first {
            goTo(symbol: def.symbol, path: def.path)
            return
        }
        if let s = doc.symbols.flattened().first(where: { same($0.name, word) && $0.kind != .instance }) {
            goTo(symbol: s, path: doc.url?.path)
            return
        }
        showToast("No definition found for “\(word)”")
    }

    func goToDefinitionAtCaret() {
        guard let d = active else { return }
        let off = d.editor.textView.selectedRange().location
        if let (w, _) = d.editor.word(at: off) { goToDefinition(word: w, in: d, offset: off) }
    }

    func findReferences(_ word: String) {
        search.options.query = word
        search.options.wholeWord = true
        search.options.regex = false
        search.options.caseSensitive = active?.language != .vhdl
        sidebarMode = .search
        runSearch()
    }

    // MARK: Templates

    /// The module at the caret: a module name under the caret, else the enclosing module, else the first one.
    func moduleForTemplates() -> (HDLSymbol, HDLLanguage)? {
        guard let d = active else { return nil }
        let off = d.hasEditor ? d.editor.textView.selectedRange().location : 0
        if d.hasEditor, let (w, _) = d.editor.word(at: off),
           let def = workspace.definitions(of: w).first(where: { $0.symbol.kind == .module || $0.symbol.kind == .entity || $0.symbol.kind == .interface }) {
            let lang = workspace.index[def.path]?.language ?? d.language
            return (def.symbol, lang)
        }
        let line = d.hasEditor ? d.editor.lineIndex(for: off) : 0
        var m = d.symbols.path(at: line).first(where: { $0.kind == .module || $0.kind == .entity })
        if m == nil, let arch = d.symbols.path(at: line).first(where: { $0.kind == .architecture }), let t = arch.target {
            m = d.symbols.first(where: { $0.kind == .entity && $0.name.lowercased() == t.lowercased() })
        }
        if m == nil { m = d.symbols.first(where: { $0.kind == .module || $0.kind == .entity }) }
        return m.map { ($0, d.language) }
    }

    func copyInstantiation() {
        guard let (m, lang) = moduleForTemplates() else { showToast("No module found"); return }
        let text = Templates.instance(of: m, language: lang, unit: active?.indentUnit ?? "    ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Copied instantiation template for \(m.name)")
    }

    func insertInstance(of m: HDLSymbol, language: HDLLanguage) {
        guard let d = active, d.language != .plain else { return }
        let text = Templates.instance(of: m, language: language == .vhdl || d.language == .vhdl ? d.language : d.language, unit: d.indentUnit)
        d.editor.insertBlock(text)
    }

    func generateTestbench() {
        guard let (m, lang) = moduleForTemplates() else { showToast("No module found in this file"); return }
        if m.ports.isEmpty && lang != .vhdl {
            showToast("“\(m.name)” has no ports — it already looks like a testbench")
            return
        }
        let tb = Templates.testbench(for: m, language: lang, unit: active?.indentUnit ?? "    ")
        let ext = lang == .vhdl ? "vhd" : (lang == .systemVerilog ? "sv" : "v")
        let src = active?.url?.deletingLastPathComponent()
        let doc = newFile(kind: .empty, name: "\(tb.name).\(ext)", text: tb.text, language: lang)
        doc.suggestedDirectory = src
        showToast("Generated \(tb.name) — save it to run it")
    }

    func reindent() {
        guard let d = active else { return }
        if !d.editor.reindent(all: false) { showToast("Reindent works on Verilog and SystemVerilog files") }
    }

    // MARK: Search

    func runSearch() {
        searchTask?.cancel()
        let opts = search.options
        guard !opts.query.isEmpty else {
            search.results = []
            search.searched = false
            return
        }
        guard opts.makeRegex() != nil else {
            search.results = []
            search.searched = true
            return
        }
        var buffers: [String: String] = [:]
        for d in docs where d.url != nil { buffers[d.key] = d.text }
        let files: [URL] = workspace.root != nil ? workspace.files : docs.compactMap(\.url)
        search.running = true
        searchTask = Task.detached(priority: .userInitiated) {
            let results = SearchEngine.search(opts, files: files, buffers: buffers)
            await MainActor.run {
                let m = AppModel.shared
                guard m.search.options == opts else { return }
                m.search.results = results
                m.search.running = false
                m.search.searched = true
            }
        }
    }

    func replaceAll() {
        guard let re = search.options.makeRegex(), !search.results.isEmpty else { return }
        let count = search.results.reduce(0) { $0 + $1.matches.count }
        let a = NSAlert()
        a.messageText = "Replace \(count) occurrence\(count == 1 ? "" : "s") in \(search.results.count) file\(search.results.count == 1 ? "" : "s")?"
        a.informativeText = "Open files are changed in the editor (you can undo there). Other files are changed on disk."
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let template = search.options.regex ? search.replace : NSRegularExpression.escapedTemplate(for: search.replace)
        for r in search.results {
            if let d = docs.first(where: { $0.url?.path == r.path }) {
                let text = d.text
                let new = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
                if new != text { d.editor.replace(NSRange(location: 0, length: (text as NSString).length), with: new, select: NSRange(location: 0, length: 0)) }
            } else if let text = try? String(contentsOfFile: r.path, encoding: .utf8) {
                let new = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
                try? new.write(toFile: r.path, atomically: true, encoding: .utf8)
            }
        }
        runSearch()
    }

    // MARK: Palette

    func openPalette(_ mode: PaletteMode = .files, text: String? = nil) {
        paletteMode = mode
        paletteText = text ?? mode.prefix
        active?.editor.completion.hide()
    }

    func closePalette() {
        paletteMode = nil
        active?.editor.focus()
    }

    // MARK: Layout

    func toggleSidebar() {
        sidebarMode = sidebarMode == nil ? .explorer : nil
    }

    func showSidebar(_ mode: SidebarMode) {
        sidebarMode = mode
    }

    func togglePanel(_ tab: PanelTab? = nil) {
        if let tab {
            if showPanel && panelTab == tab { showPanel = false } else { panelTab = tab; showPanel = true }
        } else {
            showPanel.toggle()
        }
    }

    func zoom(_ delta: Double) {
        let d = UserDefaults.standard
        let cur = d.object(forKey: "editor.fontSize") as? Double ?? 13
        d.set(delta == 0 ? 13 : min(36, max(8, cur + delta)), forKey: "editor.fontSize")
    }

    func setIndentation(spaces: Bool, size: Int) {
        guard let d = active else { return }
        d.useSpaces = spaces
        d.tabSize = size
        if d.hasEditor { d.editor.tabSizeChanged() }
    }

    func showToast(_ s: String) {
        toast = s
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: false) { _ in
            MainActor.assumeIsolated { AppModel.shared.toast = nil }
        }
    }

    // MARK: File operations (Explorer)

    func prompt(_ title: String, _ message: String = "", value: String = "", ok: String = "OK") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        a.accessoryView = field
        a.window.initialFirstResponder = field
        if let dot = value.lastIndex(of: "."), dot != value.startIndex {
            DispatchQueue.main.async {
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: value.distance(from: value.startIndex, to: dot))
            }
        }
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    func newFile(in dir: URL) {
        guard let name = prompt("New File", "Name of the new file in \(dir.lastPathComponent):", value: "new_module.v", ok: "Create") else { return }
        let url = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { alert("“\(name)” already exists", ""); return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = Templates.starter(forFileNamed: name).replacingOccurrences(of: "    ", with: indentUnitSetting)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { alert("Could not create the file", error.localizedDescription); return }
        workspace.expanded.insert(dir.path)
        workspace.refreshListing()
        openFile(url)
    }

    func newFolder(in dir: URL) {
        guard let name = prompt("New Folder", "Name of the new folder in \(dir.lastPathComponent):", value: "rtl", ok: "Create") else { return }
        let url = dir.appendingPathComponent(name)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch { alert("Could not create the folder", error.localizedDescription); return }
        workspace.expanded.insert(dir.path)
        workspace.refreshListing()
    }

    func rename(_ url: URL) {
        guard let name = prompt("Rename", "New name for “\(url.lastPathComponent)”:", value: url.lastPathComponent, ok: "Rename"), name != url.lastPathComponent else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            alert("Could not rename", error.localizedDescription)
            return
        }
        for d in docs {
            if let p = d.url?.path, p == url.path || p.hasPrefix(url.path + "/") {
                let newPath = dest.path + p.dropFirst(url.path.count)
                problemsByOwner[d.key] = nil
                d.url = URL(fileURLWithPath: newPath)
                d.diskDate = Workspace.modDate(d.url!)
                scheduleLint(d, delay: 0.1)
            }
        }
        workspace.refreshListing()
    }

    func moveToTrash(_ url: URL) {
        let a = NSAlert()
        a.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        a.informativeText = "You can restore it from the Trash."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([url]) { _, error in
            MainActor.assumeIsolated {
                let m = AppModel.shared
                if let error { m.alert("Could not move to the Trash", error.localizedDescription); return }
                for d in m.docs where d.url.map({ $0.path == url.path || $0.path.hasPrefix(url.path + "/") }) ?? false {
                    if !d.isDirty { m.close(d) } else { d.changedOnDisk = true }
                }
                m.workspace.refreshListing()
            }
        }
    }

    func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    // MARK: Examples

    static var exampleDir: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("examples"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("examples"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("counter.v").path) }
    }

    func openExamples() {
        guard let src = Self.exampleDir else { return }
        let fm = FileManager.default
        var dest = src
        if src.path.hasPrefix(Bundle.main.bundlePath + "/") {
            let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
            // Shared with the Tester tab, so a DUT there and its file here are the same file.
            dest = docsDir.appendingPathComponent("HDL Simulator").appendingPathComponent("Examples")
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
                let target = dest.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { continue }
                if name.hasSuffix(".hdltest"), let text = try? String(contentsOf: src.appendingPathComponent(name), encoding: .utf8) {
                    try? text.replacingOccurrences(of: "__EXAMPLES__", with: dest.path).write(to: target, atomically: true, encoding: .utf8)
                } else {
                    try? fm.copyItem(at: src.appendingPathComponent(name), to: target)
                }
            }
        }
        openFolder(dest)
        let tb = dest.appendingPathComponent("tb_counter.v")
        openFile(fm.fileExists(atPath: tb.path) ? tb : dest.appendingPathComponent("counter.v"))
    }

    // MARK: Recent

    private func addRecentFile(_ p: String) {
        recentFiles.removeAll { $0 == p }
        recentFiles.insert(p, at: 0)
        if recentFiles.count > 15 { recentFiles.removeLast(recentFiles.count - 15) }
        UserDefaults.standard.set(recentFiles, forKey: "recentFiles")
    }

    private func addRecentFolder(_ p: String) {
        recentFolders.removeAll { $0 == p }
        recentFolders.insert(p, at: 0)
        if recentFolders.count > 10 { recentFolders.removeLast(recentFolders.count - 10) }
        UserDefaults.standard.set(recentFolders, forKey: "recentFolders")
    }

    func clearRecent() {
        recentFiles = []
        recentFolders = []
        UserDefaults.standard.set(recentFiles, forKey: "recentFiles")
        UserDefaults.standard.set(recentFolders, forKey: "recentFolders")
    }

    // MARK: Timer

    private func onTimer() {
        tick += 1
        for d in docs {
            guard let url = d.url else { continue }
            let date = Workspace.modDate(url)
            guard let date, date != d.diskDate else { continue }
            if !d.isDirty {
                if let text = try? String(contentsOf: url, encoding: .utf8), text != d.text {
                    d.replaceAll(with: text, markSaved: true)
                    scheduleLint(d, delay: 0.1)
                }
                d.diskDate = date
            } else if !d.changedOnDisk {
                d.changedOnDisk = true
                d.diskDate = date
            }
        }
        if tick % 2 == 0 { workspace.poll() }
        if sessionEnabled { saveSession() }
    }

    // MARK: Session

    private struct Session: Codable {
        struct Doc: Codable {
            var path: String?
            var untitledName: String
            var text: String?
            var saved: String?
            var language: String
            var selection: Int
            var useSpaces: Bool
            var tabSize: Int
        }
        var root: String?
        var expanded: [String]
        var docs: [Doc]
        var active: Int?
        var sidebar: String?
        var showPanel: Bool
        var panelTab: String
        var extraFiles: [String]
    }

    private static var sessionURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HDL Simulator").appendingPathComponent("coder-session.json")
    }

    func saveSession() {
        let s = Session(
            root: workspace.root?.path,
            expanded: Array(workspace.expanded),
            docs: docs.map { d in
                let keepText = d.url == nil || d.isDirty
                return Session.Doc(path: d.url?.path, untitledName: d.untitledName, text: keepText ? d.text : nil,
                                   saved: d.url == nil ? nil : (d.isDirty ? d.savedText : nil),
                                   language: d.language.rawValue,
                                   selection: d.hasEditor ? d.editor.textView.selectedRange().location : 0,
                                   useSpaces: d.useSpaces, tabSize: d.tabSize)
            },
            active: docs.firstIndex { $0.id == activeID },
            sidebar: sidebarMode?.rawValue,
            showPanel: showPanel,
            panelTab: panelTab.rawValue,
            extraFiles: workspace.extraFiles)
        guard let data = try? JSONEncoder().encode(s), data != lastSession else { return }
        lastSession = data
        let url = Self.sessionURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func restoreSession() {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let s = try? JSONDecoder().decode(Session.self, from: data) else { return }
        lastSession = data
        workspace.extraFiles = s.extraFiles.filter { FileManager.default.fileExists(atPath: $0) }
        if let r = s.root, FileManager.default.fileExists(atPath: r) {
            workspace.setRoot(URL(fileURLWithPath: r))
            workspace.expanded = Set(s.expanded)
        }
        for sd in s.docs {
            var doc: EditorDocument?
            if let p = sd.path {
                let url = URL(fileURLWithPath: p)
                if let text = sd.text {
                    doc = EditorDocument(url: url, text: text, untitledName: sd.untitledName, savedText: sd.saved ?? (try? String(contentsOf: url, encoding: .utf8)) ?? "")
                } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                    doc = EditorDocument(url: url, text: text)
                }
            } else if let text = sd.text {
                doc = EditorDocument(url: nil, text: text, untitledName: sd.untitledName, savedText: "")
                if let n = Int(sd.untitledName.split(separator: "-").last?.split(separator: ".").first ?? "") { untitledCounter = max(untitledCounter, n) }
            }
            guard let doc else { continue }
            if let l = HDLLanguage(rawValue: sd.language) { doc.language = l }
            doc.useSpaces = sd.useSpaces
            doc.tabSize = sd.tabSize
            doc.initialSelection = NSRange(location: sd.selection, length: 0)
            docs.append(doc)
            scheduleLint(doc, delay: 0.5)
        }
        if let a = s.active, docs.indices.contains(a) { activeID = docs[a].id } else { activeID = docs.first?.id }
        sidebarMode = s.sidebar.flatMap(SidebarMode.init(rawValue:))
        showPanel = s.showPanel
        panelTab = PanelTab(rawValue: s.panelTab) ?? .problems
    }

    // MARK: Commands (palette)

    var commands: [AppCommand] {
        var c: [AppCommand] = []
        func add(_ id: String, _ title: String, _ shortcut: String = "", _ action: @escaping @MainActor () -> Void) {
            c.append(AppCommand(id: id, title: title, shortcut: shortcut, action: action))
        }
        add("file.new", "File: New Untitled File", "⌘N") { self.newFile() }
        add("file.newTemplate", "File: New File from Template…", "⌥⌘N") { self.openPalette(.newFile) }
        add("file.open", "File: Open…", "⌘O") { self.showOpenPanel() }
        add("file.openFolder", "File: Open Folder…", "⌥⌘O") { self.showOpenFolderPanel() }
        add("file.save", "File: Save", "⌘S") { if let d = self.active { self.save(d) } }
        add("file.saveAs", "File: Save As…", "⇧⌘S") { if let d = self.active { self.save(d, as: true) } }
        add("file.saveAll", "File: Save All", "⌥⌘S") { self.saveAll() }
        add("file.revert", "File: Revert File") { if let d = self.active { self.revert(d) } }
        add("file.close", "View: Close Editor", "⌘W") { self.closeActive() }
        add("file.closeAll", "View: Close All Editors") { self.closeAll() }
        add("file.closeFolder", "File: Close Folder") { self.closeFolder() }
        add("file.examples", "Help: Open Example Project") { self.openExamples() }
        add("go.file", "Go to File…", "⌘P") { self.openPalette(.files, text: "") }
        add("go.symbol", "Go to Symbol in File…", "⇧⌘O") { self.openPalette(.symbols) }
        add("go.module", "Go to Module in Workspace…", "⌘T") { self.openPalette(.modules) }
        add("go.line", "Go to Line…", "⌃G") { self.openPalette(.line) }
        add("go.definition", "Go to Definition", "F12") { self.goToDefinitionAtCaret() }
        add("go.back", "Go Back", "⌃-") { self.goBack() }
        add("go.forward", "Go Forward", "⌃⇧-") { self.goForward() }
        add("edit.comment", "Toggle Line Comment", "⌘/") { self.active?.editor.toggleComment() }
        add("edit.indent", "Indent Lines", "⌘]") { self.active?.editor.indentLines(1) }
        add("edit.outdent", "Outdent Lines", "⌘[") { self.active?.editor.indentLines(-1) }
        add("edit.reindent", "Reindent Lines (Verilog)", "⌃I") { self.reindent() }
        add("edit.reindentAll", "Reindent Whole File (Verilog)") {
            if let e = self.active?.editor, !e.reindent(all: true) { self.showToast("Reindent works on Verilog and SystemVerilog files") }
        }
        add("edit.moveUp", "Move Line Up", "⌥↑") { self.active?.editor.moveLines(up: true) }
        add("edit.moveDown", "Move Line Down", "⌥↓") { self.active?.editor.moveLines(up: false) }
        add("edit.copyUp", "Copy Line Up", "⇧⌥↑") { self.active?.editor.duplicateLines(up: true) }
        add("edit.copyDown", "Copy Line Down", "⇧⌥↓") { self.active?.editor.duplicateLines(up: false) }
        add("edit.deleteLine", "Delete Line", "⇧⌘K") { self.active?.editor.deleteLines() }
        add("edit.selectLine", "Expand Selection to Line", "⌘L") { self.active?.editor.selectLine() }
        add("edit.bracket", "Go to Matching Bracket / begin–end", "⇧⌘\\") { self.active?.editor.jumpToMatchingBracket() }
        add("edit.trim", "Trim Trailing Whitespace") { self.active?.editor.trimTrailingWhitespace() }
        add("edit.toSpaces", "Convert Indentation to Spaces") { self.active?.editor.convertIndentation(toSpaces: true) }
        add("edit.toTabs", "Convert Indentation to Tabs") { self.active?.editor.convertIndentation(toSpaces: false) }
        add("edit.find", "Find", "⌘F") { self.active?.editor.performFind(.showFindInterface) }
        add("edit.replace", "Replace", "⌥⌘F") { self.active?.editor.performFind(.showReplaceInterface) }
        add("search.files", "Search: Find in Files", "⇧⌘F") { self.sidebarMode = .search }
        add("search.replace", "Search: Replace in Files", "⇧⌘H") { self.sidebarMode = .search; self.search.showReplace = true }
        add("hdl.snippet", "HDL: Insert Snippet…", "⇧⌘J") { self.openPalette(.snippet) }
        add("hdl.instance", "HDL: Insert Module Instance…", "⇧⌘I") { self.openPalette(.instance) }
        add("hdl.copyInst", "HDL: Copy Instantiation Template", "⌥⇧⌘I") { self.copyInstantiation() }
        add("hdl.testbench", "HDL: Generate Testbench File (Template)", "⇧⌘G") { self.generateTestbench() }
        add("hdl.lint", "HDL: Check File (Lint)", "⇧⌘B") { self.lintActive() }
        add("hdl.run", "HDL: Run Simulation", "⌘R") { self.runActive() }
        add("hdl.stop", "HDL: Stop Simulation", "⌘.") { self.stopRun() }
        add("hdl.wave", "HDL: Open Waveform in HDL Viewer", "⌘Y") { self.openLastWaveform() }
        add("hdl.tester", "HDL: Generate Testbench in HDL Tester", "⌥⌘T") { self.generateTestbenchInTester() }
        add("hdl.descend", "HDL: Descend into Module", "⌥⌘↓") { self.descend() }
        add("hdl.ascend", "HDL: Ascend to Testbench / Parent", "⌥⌘↑") { self.ascend() }
        add("view.tester", "View: Switch to HDL Tester", "⌘2") { Shell.shared.show(.tester) }
        add("hdl.language", "Change Language Mode…") { self.openPalette(.language) }
        add("view.sidebar", "View: Toggle Sidebar", "⌘B") { self.toggleSidebar() }
        add("view.panel", "View: Toggle Panel", "⌘J") { self.togglePanel() }
        add("view.explorer", "View: Show Explorer", "⇧⌘E") { self.sidebarMode = .explorer }
        add("view.outline", "View: Show Outline") { self.sidebarMode = .outline }
        add("view.hierarchy", "View: Show Design Hierarchy") { self.sidebarMode = .hierarchy }
        add("view.snippets", "View: Show Snippets") { self.sidebarMode = .snippets }
        add("view.problems", "View: Show Problems", "⇧⌘M") { self.togglePanel(.problems) }
        add("view.output", "View: Show Output", "⇧⌘U") { self.togglePanel(.output) }
        add("view.wrap", "View: Toggle Word Wrap", "⌥Z") {
            let d = UserDefaults.standard
            d.set(!(d.object(forKey: "editor.wordWrap") as? Bool ?? false), forKey: "editor.wordWrap")
        }
        add("view.zoomIn", "View: Zoom In", "⌘=") { self.zoom(1) }
        add("view.zoomOut", "View: Zoom Out", "⌘-") { self.zoom(-1) }
        add("view.zoomReset", "View: Reset Zoom", "⌘0") { self.zoom(0) }
        add("view.theme", "Preferences: Color Theme", "⌘K ⌘T") { self.openPalette(.theme) }
        add("view.settings", "Preferences: Open Settings", "⌘,") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        return c
    }
}
