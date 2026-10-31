import AppKit
import HDLShell
import SwiftUI

/// What the HDL Simulator app uses from the Coder.
@MainActor
public enum CoderBridge {
    /// Shown as an extra tab in Settings (the Tester's settings).
    public static var extraSettings: AnyView?

    public static func start(sessionEnabled: Bool, openWaveforms: Bool = true) {
        let m = AppModel.shared
        m.sessionEnabled = sessionEnabled
        if !openWaveforms { m.openWaveformsInViewer = false }
        m.start()
    }

    public static func rootView() -> AnyView { AnyView(ThemedRoot { MainView() }) }
    public static func settingsView() -> AnyView { AnyView(ThemedRoot { SettingsView() }) }

    public static func open(_ urls: [URL]) { AppModel.shared.open(urls) }

    public static func saveSession() {
        if AppModel.shared.sessionEnabled { AppModel.shared.saveSession() }
    }

    public static func focusEditor() { AppModel.shared.focusEditor() }

    public static func runCLI(_ args: [String]) { CLI.run(args) }

    public static func writeSnapshot(to path: String) { Snapshot.write(to: path) }

    // MARK: Developer helpers (used by --snapshot runs)

    public static func setUp(sidebar: String?, panel: String?) {
        let model = AppModel.shared
        if let sidebar { model.sidebarMode = sidebar == "none" ? nil : SidebarMode(rawValue: sidebar) }
        if let panel { model.panelTab = PanelTab(rawValue: panel) ?? .problems; model.showPanel = true }
    }

    public static func prepare(line: Int?, keys: String?, command: String?, palette: String?, run: Bool) async {
        let model = AppModel.shared
        if let line, let d = model.active { d.editor.reveal(line: line) }
        if let keys, let d = model.active { type(keys, into: d.editor.textView) }
        if let command, let c = model.commands.first(where: { $0.id == command }) { c.action() }
        if let palette { model.openPalette(.files, text: palette) }
        if run, let d = model.active { await Simulator.run(doc: d, model: model) }
    }

    public static func perform(_ action: String) {
        let model = AppModel.shared
        switch action {
        case "descend": model.descend()
        case "ascend": model.ascend()
        case "testbench": model.generateTestbenchInTester()
        default: if let c = model.commands.first(where: { $0.id == action }) { c.action() }
        }
    }

    /// One line describing the active editor, for checking runs from the command line.
    public static var debugState: String {
        let model = AppModel.shared
        guard let d = model.active else { return "coder: no file" }
        let line = d.hasEditor ? d.editor.lineIndex(for: d.editor.textView.selectedRange().location) + 1 : 0
        return "coder: \(d.name) line \(line)\(d.isDirty ? " (modified)" : "")"
            + " descend→\(model.descendTarget()?.def.symbol.name ?? "-") ascend→\(model.ascendTarget()?.label ?? "-")"
    }

    /// Types text as if from the keyboard: \n = Return, \t = Tab, \b = Backspace, ¬ = Escape.
    static func type(_ s: String, into tv: CodeTextView) {
        tv.window?.makeFirstResponder(tv)
        let unescaped = s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\b", with: "\u{8}")
        for ch in unescaped {
            switch ch {
            case "\n": tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            case "\t": tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
            case "\u{8}": tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            case "¬": tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            case "↓": tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
            case "↑": tv.doCommand(by: #selector(NSResponder.moveUp(_:)))
            case "→": tv.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
            case "⇥": tv.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            default: tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }
}
