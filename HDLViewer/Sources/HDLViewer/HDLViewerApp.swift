import AppKit
import SwiftUI

@main
struct HDLViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The main window is created by AppDelegate (a SwiftUI `Window` scene does not
    // open when the app is launched by double-clicking a file).
    var body: some Scene {
        Settings {
            ThemedRoot { SettingsView() }
        }
        .commands { AppCommands(model: AppModel.shared) }
    }
}

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
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Picker("Color theme", selection: $themeID) {
                ForEach(ThemeID.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Toggle("Reload waveforms automatically when the file changes", isOn: Binding(
                get: { model.autoReload }, set: { model.setAutoReload($0) }))
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentFiles, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { model.open([URL(fileURLWithPath: path)]) }
                }
                Divider()
                Button("Clear Recent") { model.clearRecent() }
            }
            Divider()
            Button("Reload") { model.active?.reload() }
                .keyboardShortcut("r")
            Button("Close Tab") { model.closeActive() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("Waveform") {
            Button("Zoom In") { model.active?.zoom(by: 0.5) }
                .keyboardShortcut("=")
            Button("Zoom Out") { model.active?.zoom(by: 2) }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { model.active?.zoomFit() }
                .keyboardShortcut("0")
            Divider()
            Button("Next Transition  (→)") { model.active?.jumpTransition(forward: true) }
            Button("Previous Transition  (←)") { model.active?.jumpTransition(forward: false) }
            Button("Clear Marker") { model.active?.markerTime = nil }
            Divider()
            Button("Remove Selected Signals  (⌫)") { model.active?.removeSelected() }
            Button("Remove All Signals") { model.active?.removeAll() }
            Divider()
            Toggle("Auto-Reload When File Changes", isOn: Binding(
                get: { model.autoReload },
                set: { model.setAutoReload($0) }
            ))
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("b")
            Button("Search Signals") { model.sidebarMode = .search }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Picker("Color Theme", selection: $themeID) {
                ForEach(ThemeID.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Divider()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
        NSApp.activate()

        var urls: [URL] = []
        var snapshotPath: String?
        var cursor: Double?
        var marker: Double?
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            if a == "--snapshot", !args.isEmpty {
                snapshotPath = args.removeFirst()
            } else if a == "--cursor", !args.isEmpty {
                cursor = Double(args.removeFirst())
            } else if a == "--marker", !args.isEmpty {
                marker = Double(args.removeFirst())
            } else if !a.hasPrefix("-"), FileManager.default.fileExists(atPath: a) {
                urls.append(URL(fileURLWithPath: a))
            }
        }
        if !urls.isEmpty { AppModel.shared.open(urls) }

        if let snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    if let doc = AppModel.shared.active {
                        doc.cursorTime = cursor
                        doc.markerTime = marker
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    Snapshot.write(to: snapshotPath)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "HDL Viewer"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 820, height: 480)
        w.tabbingMode = .disallowed
        w.contentView = NSHostingView(rootView: ThemedRoot { MainView() })
        w.center()
        w.setFrameAutosaveName("MainWindow")
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow()
        AppModel.shared.open(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Developer helper: `HDLViewer --snapshot out.png [--cursor t] file.vcd` renders the window to a PNG.
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
