import AppKit
import HDLShell
import SwiftUI

/// What the HDL Simulator app uses from the Tester.
@MainActor
public enum TesterBridge {
    private static var keyMonitor: Any?

    public static func start(sessionEnabled: Bool, openWaveforms: Bool = true) {
        let m = AppModel.shared
        m.sessionEnabled = sessionEnabled
        if !openWaveforms { m.openResultsInViewer = false }
        m.start()
        installKeyMonitor()
    }

    public static func rootView() -> AnyView { AnyView(ThemedRoot { MainView() }) }
    public static func settingsView() -> AnyView { AnyView(ThemedRoot { SettingsView() }) }

    public static func open(_ urls: [URL]) { AppModel.shared.open(urls) }

    public static func saveSession() {
        if AppModel.shared.sessionEnabled { AppModel.shared.saveSession() }
    }

    public static func runCLI(_ args: [String]) { CLI.run(args) }

    // MARK: Developer helpers (used by --snapshot runs)

    public static func setUp(panel: String?, select: String?) {
        let model = AppModel.shared
        if let panel, let p = PanelTab(rawValue: panel) { model.panelTab = p }
        if let select, let doc = model.active {
            let parts = select.split(separator: ".", maxSplits: 1).map(String.init)
            if let inst = doc.state.instances.first(where: { $0.name == parts[0] }) {
                doc.selection = parts.count > 1 ? .pin(inst.id, parts[1]) : .instance(inst.id)
            }
        }
    }

    public static func run() async {
        let model = AppModel.shared
        guard let doc = model.active else { return }
        model.openResultsInViewer = false
        await Runner.run(doc, model: model)
    }

    public static func perform(_ action: String) {
        switch action {
        case "descend": AppModel.shared.descendSelected()
        default:
            // param:<inst>.<NAME>=<value>  sets a parameter override, as typing in the inspector does.
            if action.hasPrefix("param:"), let doc = AppModel.shared.active {
                let body = action.dropFirst(6)
                let kv = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let lhs = kv[0].split(separator: ".").map(String.init)
                guard kv.count == 2, lhs.count == 2,
                      let i = doc.state.instances.firstIndex(where: { $0.name == lhs[0] }) else { return }
                doc.edit { $0.instances[i].paramOverrides[lhs[1]] = kv[1].isEmpty ? nil : kv[1] }
            }
        }
    }

    /// Every wire's corner points and every block's width, one line each (to compare layouts).
    public static var wireDump: String {
        guard let doc = AppModel.shared.active else { return "" }
        let st = doc.state
        let name = { (id: UUID) in st.instance(id)?.name ?? "?" }
        var out = st.duts.map { "BOX \($0.name) w=\(Int(BlockLayout(inst: $0, env: $0.paramValues()).boxW))" }
        for r in PinGeo.routeAll(st, pins: PinGeo.allPins(st, dragging: nil)) {
            let pts = r.points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
            out.append("WIRE \(name(r.wire.from.instance)).\(r.wire.from.pin)->\(name(r.wire.to.instance)).\(r.wire.to.pin): \(pts)")
        }
        return out.joined(separator: "\n")
    }

    public static var debugState: String {
        let model = AppModel.shared
        guard let doc = model.active else { return "tester: no test" }
        let sel = doc.selection?.instanceID.flatMap { doc.state.instance($0) }
            .map { "\($0.name)(\($0.inputs.map(\.name).joined(separator: " ")))" } ?? "-"
        return "tester: \(doc.name) duts=\(doc.state.duts.map(\.name).joined(separator: ",")) sources=\(doc.state.sources.count) selected=\(sel)"
    }

    /// Delete / Backspace removes the selected canvas item when the Tester tab is showing and
    /// no text field is being edited.
    private static func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled: Bool = MainActor.assumeIsolated {
                guard event.keyCode == 51 || event.keyCode == 117,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      Shell.shared.tab == .tester,
                      !EditActions.editingText,
                      NSApp.keyWindow?.identifier?.rawValue == "main",
                      AppModel.shared.active?.selection != nil else { return false }
                EditActions.deleteSelection()
                return true
            }
            return handled ? nil : event
        }
    }
}
