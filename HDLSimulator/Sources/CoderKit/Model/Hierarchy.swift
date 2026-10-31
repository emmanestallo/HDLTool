import AppKit
import HDLShell

/// Descend / ascend through the design hierarchy, and the hand-off to the Tester tab.
extension AppModel {
    /// Called once at start: lets the Tester and the host open things in the Coder.
    func registerWithShell() {
        let shell = Shell.shared
        shell.openInCoder = { path, line, module in
            AppModel.shared.openForHierarchy(path: path, line: line, module: module)
        }
        shell.revealInCoder = { path, offset in
            let m = AppModel.shared
            guard let d = m.openFile(URL(fileURLWithPath: path)) else { return }
            let len = (d.text as NSString).length
            d.editor.select(NSRange(location: min(max(offset, 0), len), length: 0))
            m.focusEditor()
        }
    }

    func openForHierarchy(path: String, line: Int?, module: String?) {
        guard let d = openFile(URL(fileURLWithPath: path)) else { return }
        if let module, let s = d.symbols.first(where: { ($0.kind == .module || $0.kind == .entity) && $0.name == module }) {
            goTo(symbol: s, path: path)
        } else if let line {
            d.editor.reveal(line: line)
        }
        focusEditor()
    }

    func focusEditor() {
        guard let d = active, d.hasEditor else { return }
        let tv = d.editor.textView
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
    }

    /// The module (or entity) around the caret, else the first one in the file.
    func moduleAtCaret(_ d: EditorDocument) -> HDLSymbol? {
        let line = d.hasEditor ? d.editor.lineIndex(for: d.editor.textView.selectedRange().location) : 0
        let isUnit = { (s: HDLSymbol) in s.kind == .module || s.kind == .entity }
        return d.symbols.path(at: line).first(where: isUnit) ?? d.symbols.first(where: isUnit)
    }

    // MARK: Descend

    /// The module that Descend would open: the instance under the caret, or a module name under it.
    func descendTarget() -> (def: (path: String, symbol: HDLSymbol), instance: String?)? {
        guard let d = active, d.hasEditor else { return nil }
        _ = d.caret   // re-evaluate when the caret moves
        let off = d.editor.textView.selectedRange().location
        let path = d.symbols.path(at: d.editor.lineIndex(for: off))
        if let inst = path.last(where: { $0.kind == .instance }), let t = inst.target,
           let def = definition(of: t, near: d) {
            return (def, inst.name)
        }
        if let (w, _) = d.editor.word(at: off),
           let def = definition(of: w, near: d), def.path != d.url?.path || def.symbol.line != path.first?.line {
            return (def, nil)
        }
        return nil
    }

    /// A module's definition: from the open folder, else from an open file or a file next to `doc`
    /// (so descending works without opening a folder).
    func definition(of name: String, near doc: EditorDocument) -> (path: String, symbol: HDLSymbol)? {
        let isUnit = { (s: HDLSymbol) in (s.kind == .module || s.kind == .entity) && s.name.lowercased() == name.lowercased() }
        if let def = workspace.definitions(of: name).first(where: { isUnit($0.symbol) }) { return def }
        for o in docs where o.url != nil {
            if let s = o.symbols.first(where: isUnit) { return (o.url!.path, s) }
        }
        guard let dir = doc.url?.deletingLastPathComponent() else { return nil }
        let exts: Set<String> = ["v", "sv", "vh", "svh", "vhd", "vhdl"]
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            if let s = Self.siblingSymbols(f).first(where: isUnit) { return (f.standardizedFileURL.path, s) }
        }
        return nil
    }

    /// Symbols of a file on disk, cached until it changes (the title bar asks on every caret move).
    private static var siblingCache: [String: (Date, [HDLSymbol])] = [:]

    private static func siblingSymbols(_ url: URL) -> [HDLSymbol] {
        let date = Workspace.modDate(url) ?? .distantPast
        if let c = siblingCache[url.path], c.0 == date { return c.1 }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let syms = SymbolScanner.scan(text, language: HDLLanguage.detect(url))
        siblingCache[url.path] = (date, syms)
        return syms
    }

    func descend() {
        guard let d = active else { return }
        guard let (def, inst) = descendTarget() else {
            showToast("Put the caret on a module instance to descend into it")
            return
        }
        guard let here = d.url?.path else { showToast("Save the file first"); return }
        let label = moduleAtCaret(d)?.name ?? d.name
        let frame = NavFrame(place: .file(path: here, offset: d.editor.textView.selectedRange().location),
                             label: inst.map { "\(label) (\($0))" } ?? label, child: def.path)
        Shell.shared.descend(from: frame, to: def.path, line: def.symbol.line + 1, module: def.symbol.name)
    }

    // MARK: Ascend

    /// Where Ascend goes from the active file: where we descended from, the test that uses this
    /// module, or a file in the folder that instantiates it.
    func ascendTarget() -> NavFrame? {
        guard let d = active, let p = d.url?.path else { return nil }
        _ = d.caret
        let m = moduleAtCaret(d)?.name
        return Shell.shared.parent(of: p, module: m) ?? instantiatingFile(of: m, from: p)
    }

    private func instantiatingFile(of module: String?, from child: String) -> NavFrame? {
        guard let module else { return nil }
        for (path, f) in workspace.index.sorted(by: { $0.key < $1.key }) where path != child {
            for s in f.symbols where s.kind == .module || s.kind == .architecture {
                if let inst = s.children.first(where: { $0.kind == .instance && $0.target?.lowercased() == module.lowercased() }) {
                    return NavFrame(place: .file(path: path, offset: inst.offset), label: s.name, child: child)
                }
            }
        }
        return nil
    }

    func ascend() {
        guard let d = active else { return }
        guard let f = ascendTarget() else {
            showToast("Nothing above “\(moduleAtCaret(d)?.name ?? d.name)” — no test or file uses it")
            return
        }
        // Save first so the testbench sees the edits.
        if d.isDirty, d.url != nil { save(d) }
        if Shell.shared.ascend(from: d.url?.path ?? "", module: moduleAtCaret(d)?.name) { return }
        if !Shell.shared.go(to: f) { showToast("“\(f.label)” is no longer open") }
    }

    // MARK: Testbench in the Tester

    /// Opens the module at the caret in the Tester tab, wired up and ready to run.
    func generateTestbenchInTester() {
        guard let doc = active else { return }
        guard doc.url != nil else { showToast("Save the file first"); return }
        guard doc.language.isVerilogFamily else { showToast("HDL Tester works with Verilog and SystemVerilog files"); return }
        guard let (m, _) = moduleForTemplates() else { showToast("No module found in this file"); return }
        if m.ports.isEmpty {
            showToast("“\(m.name)” has no ports — it already looks like a testbench. Run it with ⌘R")
            return
        }
        let path = doc.symbols.contains(where: { $0.name == m.name && $0.kind == m.kind }) ? doc.url!.path
            : (workspace.definitions(of: m.name).first?.path ?? doc.url!.path)
        for d in docs where d.isDirty && d.url?.path == path { save(d) }
        Shell.shared.generateTestbench?(path, m.name)
    }
}

extension AppModel {
    /// Explorer → “Generate Testbench in HDL Tester” on a file: uses its first module with ports.
    func generateTestbenchInTester(file url: URL) {
        if let d = docs.first(where: { $0.url?.path == url.path }) {
            if d.isDirty { save(d) }
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let syms = SymbolScanner.scan(text, language: HDLLanguage.detect(url))
        guard let m = syms.first(where: { $0.kind == .module && !$0.ports.isEmpty }) else {
            showToast("No module with ports in \(url.lastPathComponent)")
            return
        }
        Shell.shared.generateTestbench?(url.standardizedFileURL.path, m.name)
    }
}
