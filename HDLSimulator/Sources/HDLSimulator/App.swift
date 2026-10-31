import AppKit
import CoderKit
import HDLShell
import SwiftUI
import TesterKit

@main
struct HDLSimulatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The main window is created by AppDelegate (a SwiftUI `Window` scene does not
    // open when the app is launched by double-clicking a file).
    var body: some Scene {
        let tab = Shell.shared.tab
        Settings {
            CoderBridge.settingsView()
        }
        .commands { SimulatorCommands(tab: tab) }
    }
}

/// The menus of the tab that is showing, plus switching between tabs.
struct SimulatorCommands: Commands {
    let tab: AppTab

    var body: some Commands {
        if tab == .coder {
            CoderKit.AppCommands()
        } else {
            TesterKit.AppCommands()
        }
        CommandGroup(before: .toolbar) {
            ForEach(AppTab.allCases) { t in
                Button("HDL \(t.title)") { Shell.shared.show(t) }
                    .keyboardShortcut(t == .coder ? "1" : "2")
            }
            Divider()
        }
    }
}

/// Shows the Coder or the Tester.
struct RootView: View {
    var body: some View {
        switch Shell.shared.tab {
        case .coder: CoderBridge.rootView()
        case .tester: TesterBridge.rootView()
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
        var args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--cli") {
            args.remove(at: i)
            let which = args.isEmpty ? "" : args.removeFirst()
            switch which {
            case "coder": CoderBridge.runCLI(args)
            case "tester": TesterBridge.runCLI(args)
            default:
                print("usage: --cli coder symbols|lint|reindent|tb|deps|tokens <file> [folder]\n       --cli tester parse <file.v>… | tb|run|autowire|resave <test.hdltest>")
                exit(2)
            }
            return
        }

        var urls: [URL] = []
        var snapshot: String?
        var size: NSSize?
        var theme: String?
        var wait = 1.5
        var tab: AppTab?
        var sidebar: String?
        var panel: String?
        var line: Int?
        var keys: String?
        var command: String?
        var palette: String?
        var select: String?
        var actions: [String] = []
        var run = false
        var dumpMenus = false
        var dumpWires = false
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--snapshot" where !args.isEmpty: snapshot = args.removeFirst()
            case "--theme" where !args.isEmpty: theme = args.removeFirst()
            case "--size" where !args.isEmpty:
                let p = args.removeFirst().split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { size = NSSize(width: p[0], height: p[1]) }
            case "--wait" where !args.isEmpty: wait = Double(args.removeFirst()) ?? 1.5
            case "--tab" where !args.isEmpty: tab = AppTab(rawValue: args.removeFirst())
            case "--sidebar" where !args.isEmpty: sidebar = args.removeFirst()
            case "--panel" where !args.isEmpty: panel = args.removeFirst()
            case "--line" where !args.isEmpty: line = Int(args.removeFirst())
            case "--keys" where !args.isEmpty: keys = args.removeFirst()
            case "--command" where !args.isEmpty: command = args.removeFirst()
            case "--palette" where !args.isEmpty: palette = args.removeFirst()
            case "--select" where !args.isEmpty: select = args.removeFirst()
            case "--actions" where !args.isEmpty: actions = args.removeFirst().split(separator: "|").map(String.init)
            case "--run": run = true
            case "--dump-menus": dumpMenus = true
            case "--dump-wires": dumpWires = true
            default:
                if !a.hasPrefix("-") { urls.append(URL(fileURLWithPath: a).standardizedFileURL) }
            }
        }

        let shell = Shell.shared
        let dev = snapshot != nil || !actions.isEmpty || dumpMenus || dumpWires
        if dev, let theme { UserDefaults.standard.set(theme, forKey: "themeID") }
        if !dev, let saved = UserDefaults.standard.string(forKey: "app.tab").flatMap(AppTab.init) { shell.show(saved) }
        shell.tabChanged = { t in
            if !dev { UserDefaults.standard.set(t.rawValue, forKey: "app.tab") }
            if t == .coder {
                CoderBridge.focusEditor()
            } else {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        CoderBridge.extraSettings = TesterBridge.settingsView()
        CoderBridge.start(sessionEnabled: !dev, openWaveforms: !dev)
        TesterBridge.start(sessionEnabled: !dev, openWaveforms: !dev)
        showMainWindow(size: size)
        if !dev { NSApp.activate() }
        if !urls.isEmpty { Self.route(urls) }
        if let tab { shell.show(tab) }
        guard dev else { return }

        CoderBridge.setUp(sidebar: sidebar, panel: shell.tab == .coder ? panel : nil)
        TesterBridge.setUp(panel: shell.tab == .tester ? panel : nil, select: select)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            if shell.tab == .coder {
                await CoderBridge.prepare(line: line, keys: keys, command: command, palette: palette, run: run)
            } else if run {
                await TesterBridge.run()
            }
            for a in actions {
                Self.perform(a)
                try? await Task.sleep(for: .seconds(0.5))
                print("[\(a)] tab=\(shell.tab.rawValue) | \(CoderBridge.debugState) | \(TesterBridge.debugState) | stack=\(shell.stack.map(\.label))")
            }
            if dumpMenus { Self.dumpMenus() }
            if dumpWires { print(TesterBridge.wireDump) }
            try? await Task.sleep(for: .seconds(wait))
            if let snapshot { CoderBridge.writeSnapshot(to: snapshot) }
            NSApp.terminate(nil)
        }
    }

    /// `--actions` steps, separated by |: tab:coder, tab:tester, select:<inst>, line:<n>, open:<path>, or an action of the tab
    /// that is showing (descend, ascend, testbench, or a Coder command id).
    private static func perform(_ a: String) {
        let shell = Shell.shared
        let parts = a.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "tab" where parts.count == 2: if let t = AppTab(rawValue: parts[1]) { shell.show(t) }
        case "select" where parts.count == 2: TesterBridge.setUp(panel: nil, select: parts[1])
        case "line" where parts.count == 2:
            Task { await CoderBridge.prepare(line: Int(parts[1]), keys: nil, command: nil, palette: nil, run: false) }
        case "keys" where parts.count == 2:
            Task { await CoderBridge.prepare(line: nil, keys: parts[1], command: nil, palette: nil, run: false) }
        case "open" where parts.count == 2: route([URL(fileURLWithPath: parts[1]).standardizedFileURL])
        default:
            if shell.tab == .coder { CoderBridge.perform(a) } else { TesterBridge.perform(a) }
        }
    }

    private static func dumpMenus() {
        for item in NSApp.mainMenu?.items ?? [] {
            if let m = item.submenu { m.delegate?.menuNeedsUpdate?(m); m.update() }
            let entries = (item.submenu?.items ?? []).filter { !$0.isSeparatorItem }.map { i -> String in
                let mods = i.keyEquivalentModifierMask
                let key = i.keyEquivalent.isEmpty ? "" : " [\(mods.contains(.control) ? "⌃" : "")\(mods.contains(.option) ? "⌥" : "")\(mods.contains(.shift) ? "⇧" : "")\(mods.contains(.command) ? "⌘" : "")\(i.keyEquivalent)]"
                return i.title + key
            }
            print("MENU \(item.title): " + entries.joined(separator: " · "))
        }
    }

    /// Tests go to the Tester; source files and folders to the Coder.
    static func route(_ urls: [URL]) {
        let tests = urls.filter { $0.pathExtension.lowercased() == "hdltest" }
        let rest = urls.filter { $0.pathExtension.lowercased() != "hdltest" }
        if !rest.isEmpty {
            CoderBridge.open(rest)
            Shell.shared.show(.coder)
        }
        if !tests.isEmpty {
            TesterBridge.open(tests)
            Shell.shared.show(.tester)
        }
    }

    func showMainWindow(size: NSSize? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size ?? NSSize(width: 1440, height: 900)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "HDL Simulator"
        w.identifier = NSUserInterfaceItemIdentifier("main")
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 960, height: 540)
        w.tabbingMode = .disallowed
        w.contentView = NSHostingView(rootView: RootView())
        w.center()
        if size == nil { w.setFrameAutosaveName("MainWindow") }
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow()
        Self.route(urls.map(\.standardizedFileURL))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        CoderBridge.saveSession()
        TesterBridge.saveSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
