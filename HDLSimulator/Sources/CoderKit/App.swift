import AppKit
import QuartzCore
import SwiftUI

/// Injects the model and the selected color theme.
struct ThemedRoot<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue

    var body: some View {
        let theme = (ThemeID(rawValue: themeID) ?? .darkModern).theme
        content()
            .environment(AppModel.shared)
            .environment(\.theme, theme)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue
    @AppStorage("editor.fontSize") private var fontSize: Double = 13
    @AppStorage("editor.fontName") private var fontName = ""
    @AppStorage("editor.tabSize") private var tabSize = 4
    @AppStorage("editor.insertSpaces") private var insertSpaces = true
    @AppStorage("editor.wordWrap") private var wordWrap = false
    @AppStorage("editor.autoClose") private var autoClose = true
    @AppStorage("editor.autoEnd") private var autoEnd = true
    @AppStorage("editor.suggest") private var suggest = true
    @AppStorage("editor.highlightLine") private var highlightLine = true
    @AppStorage("editor.indentGuides") private var indentGuides = true
    @AppStorage("editor.inlineDiagnostics") private var inlineDiagnostics = true
    @AppStorage("editor.showInvisibles") private var showInvisibles = false
    @AppStorage("trimTrailingWhitespace") private var trimTrailing = true
    @AppStorage("insertFinalNewline") private var finalNewline = true
    @AppStorage("linter") private var linter = Linter.Kind.auto.rawValue
    @AppStorage("lintWhileTyping") private var lintWhileTyping = true
    @AppStorage("languageStandard") private var standard = "-g2012"
    @AppStorage("saveBeforeRun") private var saveBeforeRun = true
    @AppStorage("iverilogPath") private var iverilogPath = ""
    @AppStorage("verilatorPath") private var verilatorPath = ""
    @AppStorage("ghdlPath") private var ghdlPath = ""
    @ViewState private var tab = 0

    static let fonts: [String] = {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        return ["Menlo", "Monaco", "SF Mono", "JetBrains Mono", "Fira Code", "Source Code Pro", "Courier New", "IBM Plex Mono", "Hack", "Cascadia Code"]
            .filter { families.contains($0) }
    }()

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Form {
                Section("Appearance") {
                    Picker("Color theme", selection: $themeID) {
                        ForEach(ThemeID.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    Picker("Font", selection: $fontName) {
                        Text("System Monospaced (SF Mono)").tag("")
                        ForEach(Self.fonts, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 8...36, step: 1)
                }
                Section("Indentation") {
                    Picker("Tab size", selection: $tabSize) {
                        ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("Insert spaces when pressing Tab", isOn: $insertSpaces)
                    Text("Files that already use tabs or another indent size keep their own (shown in the status bar).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Editing") {
                    Toggle("Close brackets and quotes automatically", isOn: $autoClose)
                    Toggle("Insert end, endcase, endmodule… after Return", isOn: $autoEnd)
                    Toggle("Show suggestions while typing", isOn: $suggest)
                    Toggle("Wrap long lines", isOn: $wordWrap)
                    Toggle("Trim trailing whitespace when saving", isOn: $trimTrailing)
                    Toggle("End files with a newline when saving", isOn: $finalNewline)
                }
                Section("Display") {
                    Toggle("Highlight the current line", isOn: $highlightLine)
                    Toggle("Show indent guides", isOn: $indentGuides)
                    Toggle("Show problem messages at the end of the line", isOn: $inlineDiagnostics)
                    Toggle("Show invisible characters", isOn: $showInvisibles)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Editor", systemImage: "textformat") }
            .tag(0)

            Form {
                Section("Checking") {
                    Picker("Check code with", selection: $linter) {
                        ForEach(Linter.Kind.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Check while typing (otherwise on open and save)", isOn: $lintWhileTyping)
                    Picker("Language standard (Icarus)", selection: $standard) {
                        Text("Verilog-1995").tag("-g1995")
                        Text("Verilog-2001").tag("-g2001")
                        Text("Verilog-2005").tag("-g2005")
                        Text("SystemVerilog 2009").tag("-g2009")
                        Text("SystemVerilog 2012").tag("-g2012")
                    }
                    Text("Automatic uses Icarus Verilog if installed, otherwise Verilator. VHDL files are checked with GHDL when it is installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Simulation") {
                    Toggle("Save files before running", isOn: $saveBeforeRun)
                    Toggle("Open waveforms in HDL Viewer after a run", isOn: $model.openWaveformsInViewer)
                }
                Section("Tool locations") {
                    TextField("Icarus Verilog", text: $iverilogPath, prompt: Text("Automatic (Homebrew, /usr/local/bin, PATH)"))
                        .onSubmit { model.tools.detect() }
                    TextField("Verilator", text: $verilatorPath, prompt: Text("Automatic"))
                        .onSubmit { model.tools.detect() }
                    TextField("GHDL", text: $ghdlPath, prompt: Text("Automatic"))
                        .onSubmit { model.tools.detect() }
                    LabeledContent("Icarus Verilog") {
                        Text(model.tools.iverilog.map { "\($0)  (version \(model.tools.iverilogVersion ?? "…"))" } ?? "Not found — brew install icarus-verilog")
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    LabeledContent("Verilator") {
                        Text(model.tools.verilator ?? "Not found (optional)").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    LabeledContent("GHDL") {
                        Text(model.tools.ghdl ?? "Not found (optional, for VHDL)").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button("Detect Again") { model.tools.detect() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Tools", systemImage: "hammer") }
            .tag(1)

            if let extra = CoderBridge.extraSettings {
                extra
                    .tabItem { Label("Tester", systemImage: "testtube.2") }
                    .tag(2)
            }
        }
        .frame(width: 560, height: 600)
    }
}

// MARK: - Menus

public struct AppCommands: Commands {
    let model: AppModel
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue
    @AppStorage("editor.wordWrap") private var wordWrap = false

    private var editor: EditorController? { model.active?.editor }

    public init() { model = .shared }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { model.newFile() }
                .keyboardShortcut("n")
            Button("New File from Template…") { model.openPalette(.newFile) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Open…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Open Folder…") { model.showOpenFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Menu("Open Recent") {
                ForEach(model.recentFolders, id: \.self) { p in
                    Button((p as NSString).abbreviatingWithTildeInPath) { model.open([URL(fileURLWithPath: p)]) }
                }
                if !model.recentFolders.isEmpty && !model.recentFiles.isEmpty { Divider() }
                ForEach(model.recentFiles, id: \.self) { p in
                    Button((p as NSString).lastPathComponent) { model.open([URL(fileURLWithPath: p)]) }
                }
                Divider()
                Button("Clear Recent") { model.clearRecent() }
            }
            Button("Open Example Project") { model.openExamples() }
            Divider()
            Button("Close Editor") { model.closeActive() }
                .keyboardShortcut("w")
            Button("Close Folder") { model.closeFolder() }
                .disabled(model.workspace.root == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { if let d = model.active { model.save(d) } }
                .keyboardShortcut("s")
            Button("Save As…") { if let d = model.active { model.save(d, as: true) } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Save All") { model.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Revert File") { if let d = model.active { model.revert(d) } }
                .disabled(model.active?.url == nil)
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { editor?.performFind(.showFindInterface) }
                .keyboardShortcut("f")
            Button("Find and Replace…") { editor?.performFind(.showReplaceInterface) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find Next") { editor?.performFind(.nextMatch) }
                .keyboardShortcut("g")
            Button("Find Previous") { editor?.performFind(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { editor?.performFind(.setSearchString) }
                .keyboardShortcut("e")
            Divider()
            Button("Find in Files") { model.sidebarMode = .search }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Replace in Files") { model.sidebarMode = .search; model.search.showReplace = true }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Line Comment") { editor?.toggleComment() }
                .keyboardShortcut("/")
            Button("Indent Lines") { editor?.indentLines(1) }
                .keyboardShortcut("]")
            Button("Outdent Lines") { editor?.indentLines(-1) }
                .keyboardShortcut("[")
            Button("Reindent Lines") { model.reindent() }
                .keyboardShortcut("i", modifiers: [.control])
            Button("Trim Trailing Whitespace") { editor?.trimTrailingWhitespace() }
        }
        CommandMenu("Selection") {
            Button("Expand Selection to Line") { editor?.selectLine() }
                .keyboardShortcut("l")
            Divider()
            Button("Move Line Up") { editor?.moveLines(up: true) }
                .keyboardShortcut(.upArrow, modifiers: [.option])
            Button("Move Line Down") { editor?.moveLines(up: false) }
                .keyboardShortcut(.downArrow, modifiers: [.option])
            Button("Copy Line Up") { editor?.duplicateLines(up: true) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            Button("Copy Line Down") { editor?.duplicateLines(up: false) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            Button("Delete Line") { editor?.deleteLines() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Insert Line Below") { editor?.insertLine(below: true) }
                .keyboardShortcut(.return, modifiers: [.command])
            Button("Insert Line Above") { editor?.insertLine(below: false) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            Button("Go to Matching Bracket / begin–end") { editor?.jumpToMatchingBracket() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("Trigger Suggestions") { editor?.completion.update(explicit: true) }
                .keyboardShortcut(.space, modifiers: [.control])
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("-", modifiers: [.control])
            Button("Forward") { model.goForward() }
                .keyboardShortcut("-", modifiers: [.control, .shift])
            Divider()
            Button("Go to File…") { model.openPalette(.files, text: "") }
                .keyboardShortcut("p")
            Button("Command Palette…") { model.openPalette(.commands) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Go to Symbol in File…") { model.openPalette(.symbols) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Go to Module in Workspace…") { model.openPalette(.modules) }
                .keyboardShortcut("t")
            Button("Go to Line…") { model.openPalette(.line) }
                .keyboardShortcut("g", modifiers: [.control])
            Divider()
            Button("Go to Definition") { model.goToDefinitionAtCaret() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: [])
            Divider()
            Button("Descend into Module") { model.descend() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Ascend to Testbench / Parent") { model.ascend() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            Button("Find All References") {
                if let w = model.active?.editor.selectedOrCaretWord { model.findReferences(w) }
            }
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: [.shift])
        }
        CommandMenu("HDL") {
            Button("Run Simulation") { model.runActive() }
                .keyboardShortcut("r")
            Button("Stop Simulation") { model.stopRun() }
                .keyboardShortcut(".")
                .disabled(!model.runStatus.isRunning)
            Button("Check File for Errors") { model.lintActive() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Insert Snippet…") { model.openPalette(.snippet) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Button("Insert Module Instance…") { model.openPalette(.instance) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Copy Instantiation Template") { model.copyInstantiation() }
                .keyboardShortcut("i", modifiers: [.command, .shift, .option])
            Button("Generate Testbench File (Template)") { model.generateTestbench() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Open Waveform in HDL Viewer") { model.openLastWaveform() }
                .keyboardShortcut("y")
            Button("Generate Testbench in HDL Tester") { model.generateTestbenchInTester() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Reveal Simulation Output Folder") {
                if let dir = model.active?.url?.deletingLastPathComponent().appendingPathComponent("sim_out"),
                   FileManager.default.fileExists(atPath: dir.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
            Divider()
            Menu("Language Mode") {
                ForEach(HDLLanguage.allCases) { l in
                    Button(l.displayName) { if let d = model.active { d.language = l; model.scheduleLint(d, delay: 0) } }
                }
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("b")
            Button("Toggle Panel") { model.togglePanel() }
                .keyboardShortcut("j")
            Button("Explorer") { model.sidebarMode = .explorer }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Outline") { model.sidebarMode = .outline }
            Button("Design Hierarchy") { model.sidebarMode = .hierarchy }
            Button("Snippets") { model.sidebarMode = .snippets }
            Button("Problems") { model.togglePanel(.problems) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Output") { model.togglePanel(.output) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Divider()
            Toggle("Word Wrap", isOn: $wordWrap)
                .keyboardShortcut("z", modifiers: [.option])
            Button("Zoom In") { model.zoom(1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { model.zoom(-1) }
                .keyboardShortcut("-")
            Button("Reset Zoom") { model.zoom(0) }
                .keyboardShortcut("0")
            Picker("Color Theme", selection: $themeID) {
                ForEach(ThemeID.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Divider()
        }
    }
}

/// Developer helper: renders the window to a PNG.
@MainActor
enum Snapshot {
    static func write(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write("snapshot: no window\n".data(using: .utf8)!)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Child windows (the suggestion list) are separate; draw them on top.
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            for child in window.childWindows ?? [] where child.isVisible {
                guard let cv = child.contentView, let layer = cv.layer else { continue }
                child.displayIfNeeded()
                cv.layoutSubtreeIfNeeded()
                CATransaction.flush()
                let f = child.frame
                let cg = ctx.cgContext
                cg.saveGState()
                cg.translateBy(x: f.minX - window.frame.minX, y: f.maxY - window.frame.minY)
                cg.scaleBy(x: 1, y: -1)
                layer.render(in: cg)
                cg.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Developer helpers: `HDLCoder --cli symbols|lint|reindent|tb|deps <file> [folder]`
@MainActor
enum CLI {
    static func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }

    static func dump(_ s: HDLSymbol, _ depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        var line = "\(pad)\(s.kind.label) \(s.name)"
        if !s.detail.isEmpty { line += "  [\(s.detail)]" }
        if let t = s.target { line += "  → \(t)" }
        line += "  (L\(s.line + 1)-\(s.endLine + 1))"
        out(line)
        for c in s.children where s.kind != .instance { dump(c, depth + 1) }
    }

    static func run(_ args: [String]) {
        let model = AppModel.shared
        model.sessionEnabled = false
        guard args.count >= 2 else {
            out("usage: --cli symbols|lint|reindent|tb|deps|tokens <file> [folder]")
            exit(2)
        }
        let url = URL(fileURLWithPath: args[1]).standardizedFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { out("cannot read \(url.path)"); exit(1) }
        let lang = HDLLanguage.detect(url)
        switch args[0] {
        case "symbols":
            for s in SymbolScanner.scan(text, language: lang) { dump(s, 0) }
            exit(0)
        case "tokens":
            let u = Array(text.utf16)
            for t in Lexer.lex(u, language: lang) where t.kind != .op {
                out("L\(t.line + 1) \(t.kind) \(Lexer.string(u, t))")
            }
            exit(0)
        case "reindent":
            let u = Array(text.utf16)
            let levels = Structure.indentLevels(u, Lexer.lex(u, language: lang), language: lang)
            let lines = text.components(separatedBy: "\n")
            for (i, l) in lines.enumerated() {
                let body = l.drop { $0 == " " || $0 == "\t" }
                if let lv = levels[i] { out(String(repeating: "    ", count: lv) + body) } else { out(l) }
            }
            exit(0)
        case "tb":
            let syms = SymbolScanner.scan(text, language: lang)
            guard let m = syms.first(where: { $0.kind == .module || $0.kind == .entity }) else { out("no module"); exit(1) }
            out(Templates.instance(of: m, language: lang))
            out("")
            out(Templates.testbench(for: m, language: lang).text)
            exit(0)
        case "lint", "deps":
            model.tools.detect()
            if args.count > 2 { model.workspace.setRoot(URL(fileURLWithPath: args[2])) }
            let doc = EditorDocument(url: url, text: text)
            Task { @MainActor in
                while model.workspace.indexing { try? await Task.sleep(for: .milliseconds(50)) }
                if args[0] == "deps" {
                    for d in model.dependencyFiles(for: doc) { out(d) }
                    exit(0)
                }
                let job = Linter.Job(key: doc.key, fileName: url.lastPathComponent, text: text, originalPath: url.path,
                                     language: lang, deps: model.dependencyFiles(for: doc), includeDirs: model.includeDirs(for: doc),
                                     iverilog: model.tools.iverilog, verilator: model.tools.verilator, ghdl: model.tools.ghdl,
                                     kind: .auto, standard: "-g2012")
                let r = await Task.detached { Linter.run(job) }.value
                out("tool: \(r?.tool ?? "none")")
                for d in r?.diagnostics ?? [] {
                    out("\((d.file as NSString).lastPathComponent):\(d.line): \(d.severity) \(d.message)")
                }
                exit(0)
            }
        default:
            out("unknown command")
            exit(2)
        }
    }
}
