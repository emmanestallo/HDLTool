import AppKit
import HDLShell
import Observation
import UniformTypeIdentifiers

enum SidebarMode: String {
    case duts, outline
}

enum PanelTab: String, CaseIterable, Identifiable {
    case testbench, output, problems, stimulus
    var id: String { rawValue }
    var title: String {
        switch self {
        case .testbench: return "TESTBENCH"
        case .output: return "OUTPUT"
        case .problems: return "PROBLEMS"
        case .stimulus: return "STIMULUS"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let library = Library()
    let tools = Tools()
    var tests: [TestDocument] = []
    var activeID: UUID?
    var sidebarMode: SidebarMode? = .duts
    var showInspector = true
    var showPanel = true
    var panelTab: PanelTab = .testbench
    var stimulusClipboard: Stimulus?
    var recentTests: [String]
    var openResultsInViewer: Bool {
        didSet { UserDefaults.standard.set(openResultsInViewer, forKey: "openResultsInViewer") }
    }

    /// Off for snapshot / command-line runs so they don't touch the saved session.
    @ObservationIgnored var sessionEnabled = true
    @ObservationIgnored private var lastSession: Data?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var genCache: [UUID: (TestState, Int, TBGenerator.Output)] = [:]
    @ObservationIgnored private var libraryVersion = 0

    static let testType = UTType(exportedAs: "com.emman.hdltester.test", conformingTo: .json)
    static let verilogTypes: [UTType] = Library.extensions.compactMap { UTType(filenameExtension: $0) }

    private init() {
        recentTests = UserDefaults.standard.stringArray(forKey: "recentTests") ?? []
        openResultsInViewer = UserDefaults.standard.object(forKey: "openResultsInViewer") as? Bool ?? true
    }

    func start() {
        tools.detect()
        registerWithShell()
        if sessionEnabled { restoreSession() }
        if tests.isEmpty { newTest() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.tick() }
        }
    }

    var active: TestDocument? {
        guard let activeID else { return nil }
        return tests.first { $0.id == activeID }
    }

    // MARK: Generated testbench (cached)

    func generator(for doc: TestDocument) -> TBGenerator {
        TBGenerator(state: doc.state, library: library.modules)
    }

    func generated(for doc: TestDocument) -> TBGenerator.Output {
        if let c = genCache[doc.id], c.0 == doc.state, c.1 == libraryVersion { return c.2 }
        let out = generator(for: doc).generate()
        genCache[doc.id] = (doc.state, libraryVersion, out)
        return out
    }

    // MARK: Tests

    func newTest() {
        var n = tests.count + 1
        let names = Set(tests.map(\.name))
        while names.contains("Test \(n)") { n += 1 }
        let doc = TestDocument(state: TestState(name: "Test \(n)"))
        tests.append(doc)
        activeID = doc.id
    }

    func close(_ doc: TestDocument) {
        if doc.isDirty && !doc.state.instances.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes to “\(doc.name)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                activeID = doc.id
                guard save(doc, as: false) else { return }
            case .alertSecondButtonReturn:
                return
            default: break
            }
        }
        Runner.stop(doc)
        guard let i = tests.firstIndex(where: { $0.id == doc.id }) else { return }
        tests.remove(at: i)
        genCache[doc.id] = nil
        if activeID == doc.id {
            activeID = tests.isEmpty ? nil : tests[min(i, tests.count - 1)].id
        }
    }

    func closeActive() {
        if let a = active { close(a) }
    }

    // MARK: Opening

    func open(_ urls: [URL]) {
        var verilog: [URL] = []
        for url in urls {
            if url.pathExtension.lowercased() == "hdltest" {
                openTest(url)
            } else {
                verilog.append(url)
            }
        }
        if !verilog.isEmpty {
            let added = library.add(verilog)
            libraryChanged(added)
            if !added.isEmpty { sidebarMode = .duts }
        }
    }

    func openTest(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = tests.first(where: { $0.fileURL?.path == url.path }) {
            activeID = existing.id
            return
        }
        do {
            let data = try Data(contentsOf: url)
            var file = try JSONDecoder().decode(TestFile.self, from: data)
            file.relocate(testDir: url.deletingLastPathComponent())
            let missing = file.sources.filter { !FileManager.default.fileExists(atPath: $0) }
            let have = Set(library.files.map(\.url.path))
            let toAdd = file.sources.filter { !have.contains($0) && FileManager.default.fileExists(atPath: $0) }
            libraryChanged(library.add(toAdd.map { URL(fileURLWithPath: $0) }))
            let doc = TestDocument(state: file.test, fileURL: url)
            // Replace an untouched empty test.
            if tests.count == 1, let only = tests.first, only.fileURL == nil, only.state.instances.isEmpty, !only.isDirty {
                tests = []
            }
            tests.append(doc)
            activeID = doc.id
            refresh(doc)
            addRecent(url.path)
            if !missing.isEmpty {
                doc.appendLog(.warning, "Missing source files: " + missing.joined(separator: ", "))
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Opens the demo test. The copy inside the app bundle is first copied to ~/Documents/HDL Tester/Examples.
    func openExample(_ file: String = "demo.hdltest") {
        guard let src = WelcomeView.exampleDir else { return }
        let fm = FileManager.default
        guard src.path.hasPrefix(Bundle.main.bundlePath + "/") else {
            open([src.appendingPathComponent(file)])
            return
        }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dest = docs.appendingPathComponent("HDL Simulator").appendingPathComponent("Examples")
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
        open([dest.appendingPathComponent(file)])
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.verilogTypes + [Self.testType]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose Verilog files (.v, .sv), a folder of them, or a saved test (.hdltest)"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in AppModel.shared.open([url]) }
            }
        }
        return handled
    }

    // MARK: Saving

    func sources(for doc: TestDocument) -> [String] {
        var out: [String] = []
        for inst in doc.state.duts where !out.contains(inst.filePath) { out.append(inst.filePath) }
        let gen = generated(for: doc)
        for f in gen.sourceFiles where !out.contains(f.path) { out.append(f.path) }
        return out
    }

    @discardableResult
    func save(_ doc: TestDocument, as saveAs: Bool) -> Bool {
        var url = doc.fileURL
        if saveAs || url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.testType]
            panel.nameFieldStringValue = doc.name + ".hdltest"
            if let first = doc.state.duts.first {
                panel.directoryURL = URL(fileURLWithPath: first.filePath).deletingLastPathComponent()
            }
            guard panel.runModal() == .OK, let u = panel.url else { return false }
            url = u
        }
        guard let url else { return false }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var file = doc.toFile(sources: sources(for: doc))
            file.savedDir = url.deletingLastPathComponent().path
            try enc.encode(file).write(to: url, options: .atomic)
            doc.fileURL = url
            doc.isDirty = false
            addRecent(url.path)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    private func addRecent(_ path: String) {
        recentTests.removeAll { $0 == path }
        recentTests.insert(path, at: 0)
        if recentTests.count > 12 { recentTests.removeLast(recentTests.count - 12) }
        UserDefaults.standard.set(recentTests, forKey: "recentTests")
    }

    func clearRecent() {
        recentTests = []
        UserDefaults.standard.set(recentTests, forKey: "recentTests")
    }

    // MARK: DUTs

    /// Places a module on a test's canvas. `at` is where the box's centre-top should go.
    func place(_ module: ModuleInfo, in doc: TestDocument, at point: CGPoint? = nil) {
        let pos: CGPoint
        if let point {
            pos = CGPoint(x: max(140, point.x - 80), y: max(40, point.y - 20))
        } else {
            let maxY = doc.state.instances.map { $0.y + Double(28 + 22 * max($0.inputs.count, $0.outputs.count + $0.inouts.count)) }.max()
            pos = CGPoint(x: 330, y: (maxY ?? 20) + 70)
        }
        let snap = { (v: Double) in (v / 10).rounded() * 10 }
        var inst = DUTInstance(module: module, name: doc.state.uniqueInstanceName(for: module.name),
                               x: snap(pos.x), y: snap(pos.y))
        inst.paramOverrides = [:]
        doc.edit { $0.instances.append(inst) }
        doc.selection = .instance(inst.id)
        activeID = doc.id
    }

    /// Adds a source block (clock, reset, …) that can be wired to several inputs.
    func placeSource(_ preset: SourcePreset, in doc: TestDocument, at point: CGPoint? = nil) {
        let snap = { (v: Double) in (v / 10).rounded() * 10 }
        let pos: CGPoint
        if let point {
            pos = CGPoint(x: max(10, point.x - 60), y: max(10, point.y - 20))
        } else {
            let maxY = doc.state.sources.map { $0.y + 54 }.max()
            pos = CGPoint(x: 30, y: (maxY ?? 50) + 20)
        }
        let inst = DUTInstance(sourceNamed: doc.state.uniqueName(preset.baseName), width: preset.width,
                               stimulus: preset.stimulus(period: doc.state.typicalClockPeriod), x: snap(pos.x), y: snap(pos.y))
        doc.edit { $0.instances.append(inst) }
        doc.selection = .instance(inst.id)
        activeID = doc.id
    }

    func placeInActive(_ module: ModuleInfo) {
        if active == nil { newTest() }
        if let doc = active { place(module, in: doc) }
    }

    /// Updates DUT boxes after their source file changed.
    func libraryChanged(_ files: [SourceFile]) {
        guard !files.isEmpty else { return }
        libraryVersion += 1
        for doc in tests { refresh(doc) }
    }

    func refresh(_ doc: TestDocument) {
        var changed = false
        var s = doc.state
        for i in s.instances.indices {
            let inst = s.instances[i]
            guard let m = library.module(named: inst.moduleName, preferFile: inst.filePath),
                  Library.samePath(m.file.path, inst.filePath) || !FileManager.default.fileExists(atPath: inst.filePath) else { continue }
            if m.ports != inst.ports || m.params != inst.params || !Library.samePath(m.file.path, inst.filePath) {
                s.instances[i].ports = m.ports
                s.instances[i].params = m.params
                s.instances[i].filePath = m.file.path
                let inputs = Set(m.ports.filter { $0.dir == .input }.map(\.name))
                s.wires.removeAll { $0.to.instance == inst.id && !inputs.contains($0.to.pin) }
                changed = true
            }
        }
        if changed {
            s.migratePinStimuli()
            doc.silently { $0 = s }
            doc.validateSelection()
        }
    }

    // MARK: Running

    func runActive() {
        guard let doc = active else { return }
        Task { await Runner.run(doc, model: self) }
    }

    func runAll() {
        Task {
            for doc in tests where !doc.state.duts.isEmpty {
                activeID = doc.id
                await Runner.run(doc, model: self)
            }
        }
    }

    // MARK: Layout

    func toggleSidebar() {
        sidebarMode = sidebarMode == nil ? .duts : nil
    }

    // MARK: Timer: file watching & session autosave

    private func tick() {
        let changed = library.checkForChanges()
        if !changed.isEmpty { libraryChanged(changed) }
        if sessionEnabled { saveSession() }
    }

    private struct Session: Codable {
        struct Test: Codable {
            var state: TestState
            var path: String?
            var dirty: Bool
        }
        var sources: [String]
        var tests: [Test]
        var active: Int?
    }

    private static var sessionURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HDL Simulator").appendingPathComponent("tester-session.json")
    }

    func saveSession() {
        let s = Session(sources: library.files.map(\.url.path),
                        tests: tests.map { Session.Test(state: $0.state, path: $0.fileURL?.path, dirty: $0.isDirty) },
                        active: tests.firstIndex { $0.id == activeID })
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
        library.add(s.sources.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) })
        libraryVersion += 1
        for t in s.tests {
            let doc = TestDocument(state: t.state, fileURL: t.path.map { URL(fileURLWithPath: $0) })
            doc.isDirty = t.dirty
            tests.append(doc)
            refresh(doc)
        }
        if let a = s.active, tests.indices.contains(a) { activeID = tests[a].id } else { activeID = tests.first?.id }
    }
}
