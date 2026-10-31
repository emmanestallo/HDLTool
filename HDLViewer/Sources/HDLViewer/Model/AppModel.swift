import AppKit
import Observation
import UniformTypeIdentifiers

enum SidebarMode: String {
    case explorer, search
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var docs: [WaveDocument] = []
    var activeID: UUID?
    var sidebarMode: SidebarMode? = .explorer
    var searchText = ""
    var recentFiles: [String]
    private(set) var autoReload: Bool

    @ObservationIgnored private var timer: Timer?

    private init() {
        recentFiles = UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []
        autoReload = UserDefaults.standard.object(forKey: "autoReload") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.checkForChanges() }
        }
    }

    var active: WaveDocument? {
        guard let activeID else { return nil }
        return docs.first { $0.id == activeID }
    }

    static let vcdType = UTType(filenameExtension: "vcd") ?? .data

    // MARK: Opening

    func open(_ urls: [URL]) {
        for raw in urls {
            let url = raw.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let existing = docs.first(where: { $0.url.path == url.path }) {
                activeID = existing.id
                existing.reload()
            } else {
                let doc = WaveDocument(url: url)
                docs.append(doc)
                activeID = doc.id
                doc.load()
            }
            addRecent(url.path)
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.vcdType]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a VCD waveform file"
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

    func close(_ doc: WaveDocument) {
        guard let i = docs.firstIndex(where: { $0.id == doc.id }) else { return }
        docs.remove(at: i)
        if activeID == doc.id {
            activeID = docs.isEmpty ? nil : docs[min(i, docs.count - 1)].id
        }
    }

    func closeActive() {
        if let a = active { close(a) }
    }

    // MARK: Recent & settings

    private func addRecent(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 12 { recentFiles.removeLast(recentFiles.count - 12) }
        UserDefaults.standard.set(recentFiles, forKey: "recentFiles")
    }

    func clearRecent() {
        recentFiles = []
        UserDefaults.standard.set(recentFiles, forKey: "recentFiles")
    }

    func setAutoReload(_ on: Bool) {
        autoReload = on
        UserDefaults.standard.set(on, forKey: "autoReload")
    }

    func toggleSidebar() {
        sidebarMode = sidebarMode == nil ? .explorer : nil
    }

    // MARK: Auto reload

    private func checkForChanges() {
        guard autoReload else { return }
        for doc in docs where !doc.isLoading {
            guard let date = WaveDocument.modificationDate(of: doc.url) else { continue }
            // Wait until the simulator has stopped writing for a moment.
            if date != doc.modDate && Date().timeIntervalSince(date) > 0.4 {
                doc.modDate = date
                doc.reload()
            }
        }
    }
}
