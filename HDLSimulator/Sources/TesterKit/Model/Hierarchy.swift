import AppKit
import HDLShell

/// Descend into a DUT's source (Coder tab) and the hand-off from the Coder.
extension AppModel {
    /// Called once at start: lets the Coder and the host reach the Tester.
    func registerWithShell() {
        let shell = Shell.shared
        shell.showTest = { id, inst in
            let m = AppModel.shared
            guard let doc = m.tests.first(where: { $0.id == id }) else { return false }
            m.reloadChangedFiles()
            m.activeID = id
            if let inst, doc.state.instance(inst) != nil { doc.selection = .instance(inst) }
            return true
        }
        shell.testbench = { path, module in
            AppModel.shared.testbench(using: path, module: module)
        }
        shell.generateTestbench = { path, module in
            AppModel.shared.generateTestbench(path: path, module: module)
        }
        shell.openInTester = { urls in
            AppModel.shared.open(urls)
        }
    }

    /// Picks up edits saved in the Coder right away instead of on the next timer tick.
    func reloadChangedFiles() {
        let changed = library.checkForChanges(settled: true)
        if !changed.isEmpty { libraryChanged(changed) }
    }

    /// The open test (the active one first) that has `module` from `path` as a DUT.
    func testbench(using path: String, module: String?) -> NavFrame? {
        let ordered = (active.map { [$0] } ?? []) + tests.filter { $0.id != activeID }
        for doc in ordered {
            if let inst = doc.state.duts.first(where: { Library.samePath($0.filePath, path) && (module == nil || $0.moduleName == module) }) {
                return NavFrame(place: .test(id: doc.id, instance: inst.id), label: doc.name, child: path)
            }
        }
        return nil
    }

    // MARK: Descend

    /// The DUT that Descend would open: the selected DUT, or the only DUT in the test.
    func descendTarget(in doc: TestDocument) -> DUTInstance? {
        if let id = doc.selection?.instanceID, let inst = doc.state.instance(id) {
            return inst.isSource ? nil : inst
        }
        let duts = doc.state.duts
        return duts.count == 1 ? duts[0] : nil
    }

    /// Opens a DUT's Verilog source in the Coder tab. Ascend there comes back to this test.
    func descend(into inst: DUTInstance, in doc: TestDocument) {
        guard !inst.isSource else { return }
        let path = URL(fileURLWithPath: inst.filePath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            doc.appendLog(.error, "Cannot descend into \(inst.name): \(path) is missing")
            NSSound.beep()
            return
        }
        doc.selection = .instance(inst.id)
        let line = library.module(named: inst.moduleName, preferFile: inst.filePath)?.line
        let frame = NavFrame(place: .test(id: doc.id, instance: inst.id), label: doc.name, child: path)
        Shell.shared.descend(from: frame, to: path, line: line, module: inst.moduleName)
    }

    func descendSelected() {
        guard let doc = active, let inst = descendTarget(in: doc) else { NSSound.beep(); return }
        descend(into: inst, in: doc)
    }

    /// Opens a Verilog file in the Coder tab (sidebar “Open in HDL Coder”).
    func openInCoder(_ url: URL, module: String? = nil, line: Int? = nil) {
        let path = url.standardizedFileURL.path
        if let doc = active {
            let frame = NavFrame(place: .test(id: doc.id, instance: nil), label: doc.name, child: path)
            Shell.shared.descend(from: frame, to: path, line: line, module: module)
        } else {
            Shell.shared.show(.coder)
            Shell.shared.openInCoder?(path, line, module)
        }
    }

    // MARK: Testbench for a module sent from the Coder

    /// Shows the test that already has this DUT, or makes a new test with it placed and every input
    /// driven (clocks, resets and constants), ready to run.
    func generateTestbench(path: String, module: String) {
        let shell = Shell.shared
        libraryChanged(library.add([URL(fileURLWithPath: path)]))
        reloadChangedFiles()
        sidebarMode = sidebarMode ?? .duts
        if let frame = testbench(using: path, module: module) {
            shell.go(to: frame)
            return
        }
        guard let info = library.module(named: module, preferFile: path) else {
            shell.show(.tester)
            active?.appendLog(.error, "Module \(module) not found in \(path) — check it for syntax errors")
            panelTab = .output
            showPanel = true
            return
        }
        // Reuse an untouched empty test, else start a new one.
        if let a = active, a.state.instances.isEmpty, a.fileURL == nil {
        } else {
            newTest()
        }
        guard let doc = active else { return }
        let names = Set(tests.filter { $0.id != doc.id }.map(\.name))
        var name = module
        var n = 2
        while names.contains(name) { name = "\(module)_\(n)"; n += 1 }
        doc.silently { $0.name = name }
        place(info, in: doc)
        if let id = doc.selection?.instanceID {
            doc.addSourcesForUnwiredInputs(of: id)
            doc.selection = .instance(id)
        }
        panelTab = .testbench
        shell.show(.tester)
    }
}
