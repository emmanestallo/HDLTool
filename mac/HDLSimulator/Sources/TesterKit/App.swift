import AppKit
import HDLShell
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

struct SettingsView: View {
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue
    @AppStorage("iverilogPath") private var iverilogPath = ""
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Color theme", selection: $themeID) {
                ForEach(ThemeID.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Toggle("Open waveforms in HDL Viewer after a run", isOn: $model.openResultsInViewer)
            Section("Icarus Verilog") {
                TextField("Location", text: $iverilogPath, prompt: Text("Automatic (Homebrew, /usr/local/bin, PATH)"))
                    .onSubmit { model.tools.detect() }
                LabeledContent("Found") {
                    Text(model.tools.iverilog.map { "\($0)  (version \(model.tools.version ?? "…"))" } ?? "Not found — brew install icarus-verilog")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Detect Again") { model.tools.detect() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

public struct AppCommands: Commands {
    let model: AppModel
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue

    public init() { model = .shared }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Test") { model.newTest() }
                .keyboardShortcut("n")
            Button("Open…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent Test") {
                ForEach(model.recentTests, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { model.open([URL(fileURLWithPath: path)]) }
                }
                Divider()
                Button("Clear Recent") { model.clearRecent() }
            }
            Button("Open Example Test") { model.openExample() }
            Button("Open Wired Example") { model.openExample("wired.hdltest") }
            Divider()
            Button("Close Test") { model.closeActive() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Test") { if let d = model.active { model.save(d, as: false) } }
                .keyboardShortcut("s")
            Button("Save Test As…") { if let d = model.active { model.save(d, as: true) } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Export Testbench") {
                if let d = model.active, let url = Runner.export(d, model: model) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .keyboardShortcut("e")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { EditActions.undo() }
                .keyboardShortcut("z")
            Button("Redo") { EditActions.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Stimulus") { EditActions.copyStimulus() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Paste Stimulus") { EditActions.pasteStimulus() }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Duplicate DUT") { EditActions.duplicate() }
                .keyboardShortcut("d")
            Button("Delete Selection") { EditActions.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [.command])
        }
        CommandMenu("Test") {
            Button("Run Test") { model.runActive() }
                .keyboardShortcut("r")
            Button("Run All Tests") { model.runAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Stop") { if let d = model.active { Runner.stop(d) } }
                .keyboardShortcut(".")
            Divider()
            Button("Open Waveform in HDL Viewer") {
                if let v = model.active?.lastVCD { Runner.openInViewer(v) }
            }
            .keyboardShortcut("y")
            Button("Descend into DUT") { model.descendSelected() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("Reveal Output Folder") {
                if let d = model.active {
                    let dir = Runner.outputDir(for: d)
                    if FileManager.default.fileExists(atPath: dir.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
            }
            Divider()
            Button("Zoom In") { if let d = model.active { d.zoom = min(2, d.zoom * 1.25) } }
                .keyboardShortcut("=")
            Button("Zoom Out") { if let d = model.active { d.zoom = max(0.4, d.zoom / 1.25) } }
                .keyboardShortcut("-")
            Button("Actual Size") { model.active?.zoom = 1 }
                .keyboardShortcut("0")
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("b")
            Button("Toggle Panel") { model.showPanel.toggle() }
                .keyboardShortcut("j")
            Button("Toggle Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .option])
            Picker("Color Theme", selection: $themeID) {
                ForEach(ThemeID.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Divider()
        }
    }
}

/// Edit actions that defer to text fields when one is being edited.
@MainActor
enum EditActions {
    static var editingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    static func undo() {
        if editingText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); return }
        AppModel.shared.active?.undo()
    }

    static func redo() {
        if editingText { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil); return }
        AppModel.shared.active?.redo()
    }

    static func deleteSelection() {
        guard let doc = AppModel.shared.active, let sel = doc.selection else { return }
        if case .wire(let w) = sel { doc.removeWire(w); return }
        if case .pin(let id, let pin) = sel, doc.state.instance(id)?.isSource == false {
            // A pin: remove its wire(s), never the whole DUT.
            let ref = PinRef(instance: id, pin: pin)
            if doc.state.wire(to: ref) != nil {
                doc.disconnect(input: ref)
            } else if !doc.state.wires(from: ref).isEmpty {
                doc.edit { $0.wires.removeAll { $0.from == ref } }
            } else {
                NSSound.beep()
            }
            return
        }
        if let id = sel.instanceID { doc.removeInstance(id) }
    }

    static func duplicate() {
        guard let doc = AppModel.shared.active, let id = doc.selection?.instanceID else { return }
        doc.duplicateInstance(id)
    }

    /// The selected source block, if any (only sources have a stimulus).
    private static func selectedSource() -> (TestDocument, DUTInstance)? {
        guard let doc = AppModel.shared.active, let id = doc.selection?.instanceID,
              let inst = doc.state.instance(id), inst.isSource else { return nil }
        return (doc, inst)
    }

    static func copyStimulus() {
        guard let (_, inst) = selectedSource() else { NSSound.beep(); return }
        AppModel.shared.stimulusClipboard = inst.stimulus("out")
    }

    static func pasteStimulus() {
        guard let s = AppModel.shared.stimulusClipboard, let (doc, inst) = selectedSource() else { NSSound.beep(); return }
        doc.edit { st in
            if let i = st.instances.firstIndex(where: { $0.id == inst.id }) { st.instances[i].stimuli["out"] = s }
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
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// `HDLTester --cli parse file.v` · `--cli tb test.hdltest` · `--cli run test.hdltest`
@MainActor
enum CLI {
    static func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }

    static func run(_ args: [String]) {
        let model = AppModel.shared
        model.sessionEnabled = false
        model.openResultsInViewer = false
        guard let cmd = args.first else {
            out("usage: --cli parse <file.v>… | tb <test.hdltest> | run <test.hdltest> | resave <test.hdltest>")
            exit(2)
        }
        let files = args.dropFirst().map { URL(fileURLWithPath: $0) }
        switch cmd {
        case "parse":
            for f in files {
                let r = VerilogParser.parse(file: f)
                out("== \(f.lastPathComponent)")
                for e in r.errors { out("  error: \(e)") }
                for m in r.modules {
                    out("module \(m.name) (line \(m.line))  instantiates: \(m.instantiates)")
                    for p in m.params { out("  \(p.isLocal ? "localparam" : "parameter") \(p.name) = \(p.value)") }
                    let inst = DUTInstance(module: m, name: "u", x: 0, y: 0)
                    let env = inst.paramValues()
                    for p in m.ports {
                        let w = inst.resolve(p, env: env).map { "\($0.width) bits" } ?? "width ?"
                        out("  \(p.dir.rawValue) \(p.dataType) \(p.isSigned ? "signed " : "")\(p.ranges.map { "[\($0.msb):\($0.lsb)]" }.joined()) \(p.name)  → \(w)"
                            + (p.unsupported.map { "  !! \($0)" } ?? ""))
                    }
                    for w in m.warnings { out("  warning: \(w)") }
                }
            }
            exit(0)
        case "resave":
            // Rewrites a test in the current format (e.g. after old per-pin stimuli became sources).
            guard let f = files.first else { exit(2) }
            model.open([f])
            guard let doc = model.active, doc.fileURL != nil else { out("could not open test"); exit(1) }
            exit(model.save(doc, as: false) ? 0 : 1)
        case "autowire":
            // Adds sources for every unwired DUT input, then prints the testbench (for checking the helper).
            guard let f = files.first else { exit(2) }
            model.open([f])
            guard let doc = model.active, doc.fileURL != nil else { out("could not open test"); exit(1) }
            for d in doc.state.duts { out("\(d.name): wired \(doc.addSourcesForUnwiredInputs(of: d.id)) inputs") }
            for s in doc.state.sources { out("source \(s.name) \(s.stimulus("out").kind.rawValue) \(s.sourceWidth) bit(s) at \(Int(s.x)),\(Int(s.y))") }
            let g = model.generated(for: doc)
            for p in g.problems { out("// \(p.severity == .error ? "ERROR" : "warning"): \(p.message)") }
            exit(0)
        case "tb", "run":
            guard let f = files.first else { exit(2) }
            model.tools.detect()
            model.open([f])
            guard let doc = model.active, doc.fileURL != nil else { out("could not open test"); exit(1) }
            if cmd == "tb" {
                let g = model.generated(for: doc)
                out(g.source)
                for p in g.problems { out("// \(p.severity == .error ? "ERROR" : "warning"): \(p.message)") }
                out("// sources: " + g.sourceFiles.map(\.path).joined(separator: " "))
                exit(0)
            }
            Task { @MainActor in
                let ok = await Runner.run(doc, model: model)
                for l in doc.log { out(l.text) }
                exit(ok ? 0 : 1)
            }
        default:
            out("unknown command \(cmd)")
            exit(2)
        }
    }
}
