import AppKit
import HDLShell
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 270
    @AppStorage("panelHeight") private var panelHeight: Double = 230
    @ViewState private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                ActivityBar()
                if let mode = model.sidebarMode {
                    SidebarView(mode: mode)
                        .frame(width: sidebarWidth)
                    ResizeDivider(color: theme.border) { dx in
                        sidebarWidth = min(max(sidebarWidth + Double(dx), 180), 600)
                    }
                }
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        EditorArea()
                        if model.showPanel {
                            ResizeDivider(axis: .horizontal, color: theme.border) { dy in
                                panelHeight = min(max(panelHeight - Double(dy), 100), max(120, Double(geo.size.height) - 140))
                            }
                            BottomPanel()
                                .frame(height: min(panelHeight, max(120, geo.size.height - 140)))
                        }
                    }
                }
            }
            StatusBar()
        }
        .background(theme.editor)
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if model.paletteMode != nil {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { model.closePalette() }
                    PaletteView()
                        .padding(.top, 40)
                }
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.fg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.widgetBG))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .padding(.bottom, 40)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in AppModel.shared.open([url]) }
                }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    theme.accent.opacity(0.12)
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(14)
                    Label("Drop files to open them, or a folder to open it as the workspace", systemImage: "arrow.down.doc")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.fg)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Title bar

struct TitleBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.titleBar
            commandCenter
            HStack(spacing: 2) {
                AppTabSwitcher()
                    .padding(.leading, 78)
                Spacer()
                runButton
                    .padding(.trailing, 6)
                IconButton(icon: "testtube.2", help: "Generate Testbench in HDL Tester (⌥⌘T)", disabled: model.active?.url == nil || !(model.active?.language.isVerilogFamily ?? false)) {
                    model.generateTestbenchInTester()
                }
                IconButton(icon: "waveform.path", help: "Open Last Waveform in HDL Viewer (⌘Y)", disabled: model.lastVCD == nil) {
                    model.openLastWaveform()
                }
                IconButton(icon: "checkmark.seal", help: "Check File for Errors (⇧⌘B)", disabled: model.active == nil || model.active?.language == .plain) {
                    model.lintActive()
                }
                Rectangle().fill(theme.border).frame(width: 1, height: 16).padding(.horizontal, 4)
                let down = model.descendTarget()
                IconButton(icon: "arrow.turn.right.down", help: down.map { "Descend into \($0.def.symbol.name) (⌥⌘↓)" } ?? "Descend into Module — put the caret on an instance (⌥⌘↓)", disabled: down == nil) {
                    model.descend()
                }
                let up = model.ascendTarget()
                IconButton(icon: "arrow.turn.left.up", help: up.map { "Ascend to \($0.label) (⌥⌘↑)" } ?? "Ascend — nothing uses this module (⌥⌘↑)", disabled: up == nil) {
                    model.ascend()
                }
                Rectangle().fill(theme.border).frame(width: 1, height: 16).padding(.horizontal, 4)
                IconButton(icon: model.sidebarMode == nil ? "sidebar.left" : "sidebar.squares.left", help: "Toggle Sidebar (⌘B)") { model.toggleSidebar() }
                IconButton(icon: model.showPanel ? "rectangle.bottomthird.inset.filled" : "rectangle", help: "Toggle Panel (⌘J)") { model.togglePanel() }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 35)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .gesture(WindowDragGesture())
        .simultaneousGesture(TapGesture(count: 2).onEnded { NSApp.keyWindow?.zoom(nil) })
    }

    private var commandCenter: some View {
        Button { model.openPalette(.files, text: "") } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Text(model.workspace.root != nil ? model.workspace.name : (model.active?.name ?? "HDL Coder"))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(theme.titleFG.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 380)
        .help("Go to File (⌘P) · Commands (⇧⌘P)")
    }

    @ViewBuilder private var runButton: some View {
        let running = model.runStatus.isRunning
        let enabled = model.active.map { $0.language != .plain } ?? false
        Button {
            if running { model.stopRun() } else { model.runActive() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: running ? "stop.fill" : "play.fill").font(.system(size: 10))
                Text(running ? "Stop" : "Run").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(running ? Color.white : (enabled ? theme.buttonFG : theme.dimFG))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 4).fill(running ? theme.error : (enabled ? Color(hex: 0x16825D) : theme.secondaryButtonBG)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !running)
        .help(running ? "Stop the simulation (⌘.)" : "Compile and simulate this file with Icarus Verilog (⌘R)")
    }
}

// MARK: - Activity bar

struct ActivityBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue

    var body: some View {
        VStack(spacing: 0) {
            ForEach(SidebarMode.allCases, id: \.self) { item($0) }
            Spacer()
            Menu {
                Picker("Color Theme", selection: $themeID) {
                    ForEach(ThemeID.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Command Palette…") { model.openPalette(.commands) }
                Button("Open Example Project") { model.openExamples() }
                Divider()
                Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(theme.activityInactiveFG)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 48, height: 48)
            .padding(.bottom, 4)
        }
        .frame(width: 48)
        .background(theme.activityBar)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 1) }
    }

    private func item(_ mode: SidebarMode) -> some View {
        let active = model.sidebarMode == mode
        return Button {
            model.sidebarMode = active ? nil : mode
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(active ? theme.activityFG : theme.activityInactiveFG)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if mode == .search && !model.search.results.isEmpty {
                        badge(model.search.results.reduce(0) { $0 + $1.matches.count })
                    }
                }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if active { Rectangle().fill(theme.activityActiveBorder).frame(width: 2) }
        }
        .help(mode.help)
    }

    private func badge(_ n: Int) -> some View {
        Text(n > 999 ? "999+" : "\(n)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(theme.accent))
            .padding(.top, 8)
            .padding(.trailing, 6)
    }
}

// MARK: - Editor area

struct EditorArea: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if !model.docs.isEmpty { TabBar() }
            if let doc = model.active {
                Breadcrumbs(doc: doc)
                if doc.changedOnDisk { DiskChangeBanner(doc: doc) }
                EditorPane(doc: doc)
            } else {
                WelcomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.editor)
    }
}

/// Reads the editor preferences and hosts the document's text view.
struct EditorPane: View {
    let doc: EditorDocument
    @Environment(\.theme) private var theme
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

    var body: some View {
        let s = EditorSettings(fontSize: fontSize, fontName: fontName, tabSize: tabSize, insertSpaces: insertSpaces,
                               wordWrap: wordWrap, autoClose: autoClose, autoEnd: autoEnd, suggest: suggest,
                               highlightLine: highlightLine, indentGuides: indentGuides,
                               inlineDiagnostics: inlineDiagnostics, showInvisibles: showInvisibles)
        EditorHost(doc: doc, theme: theme, settings: s)
    }
}

final class EditorContainerView: NSView {
    weak var current: NSView?

    func show(_ view: NSView) {
        if current === view { return }
        current?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        current = view
        (view as? NSScrollView)?.tile()
    }
}

struct EditorHost: NSViewRepresentable {
    let doc: EditorDocument
    let theme: Theme
    let settings: EditorSettings

    func makeNSView(context: Context) -> EditorContainerView {
        let v = EditorContainerView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: EditorContainerView, context: Context) {
        let ed = doc.editor
        ed.configure(theme: theme, settings: settings)
        if v.current !== ed.scrollView {
            v.show(ed.scrollView)
            ed.setDiagnostics(doc.diagnostics)
            DispatchQueue.main.async {
                if AppModel.shared.paletteMode == nil { ed.focus() }
            }
        }
    }
}

struct TabBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(model.docs) { doc in
                            TabItem(doc: doc, isActive: doc.id == model.activeID).id(doc.id)
                        }
                    }
                }
                .onChange(of: model.activeID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            IconButton(icon: "plus", help: "New File (⌘N)", color: theme.tabInactiveFG, size: 12) { model.newFile() }
                .padding(.horizontal, 6)
        }
        .frame(height: 35)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.tabBar)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

struct FileIcon: View {
    let name: String
    var size: CGFloat = 12
    @Environment(\.theme) private var theme

    var body: some View {
        let (icon, color) = Self.style(name, theme)
        Image(systemName: icon)
            .font(.system(size: size))
            .foregroundStyle(color)
    }

    static func style(_ name: String, _ theme: Theme) -> (String, Color) {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "v", "vh", "vlog": return ("chevron.left.forwardslash.chevron.right", theme.isDark ? Color(hex: 0x4FC1FF) : Color(hex: 0x0070C1))
        case "sv", "svh": return ("chevron.left.forwardslash.chevron.right", theme.isDark ? Color(hex: 0x4EC9B0) : Color(hex: 0x267F99))
        case "vhd", "vhdl": return ("curlybraces", theme.isDark ? Color(hex: 0xC586C0) : Color(hex: 0xAF00DB))
        case "vcd", "fst", "ghw": return ("waveform.path", theme.isDark ? Color(hex: 0xDCDCAA) : Color(hex: 0x795E26))
        case "hdltest": return ("testtube.2", theme.isDark ? Color(hex: 0x89D185) : Color(hex: 0x388A34))
        case "xdc", "sdc", "ucf", "pcf", "lpf", "qsf": return ("pin", theme.isDark ? Color(hex: 0xEE9D28) : Color(hex: 0xD67E00))
        case "tcl", "sh", "py", "do", "mk": return ("terminal", theme.dimFG)
        case "mem", "hex", "coe", "mif": return ("memorychip", theme.dimFG)
        case "md", "txt": return ("doc.text", theme.dimFG)
        default:
            if name == "Makefile" { return ("hammer", theme.dimFG) }
            return ("doc", theme.dimFG)
        }
    }
}

struct TabItem: View {
    let doc: EditorDocument
    let isActive: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false
    @ViewState private var hoveringClose = false

    var body: some View {
        let errors = doc.diagnostics.filter { $0.severity == .error }.count
        HStack(spacing: 6) {
            FileIcon(name: doc.name)
            Text(doc.name)
                .font(.system(size: 13))
                .foregroundStyle(errors > 0 ? theme.error : (isActive ? theme.tabActiveFG : theme.tabInactiveFG))
                .italic(doc.url == nil)
                .lineLimit(1)
            if errors > 0 {
                Text("\(errors)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.error)
            }
            Button { model.close(doc) } label: {
                ZStack {
                    if doc.isDirty && !hoveringClose {
                        Circle().fill(theme.fg).frame(width: 8, height: 8)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.fg)
                    }
                }
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(hoveringClose ? theme.listHover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || hovering || doc.isDirty ? 1 : 0)
            .onHover { hoveringClose = $0 }
            .help("Close (⌘W)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 35)
        .background(isActive ? theme.tabActive : (hovering ? theme.listHover.opacity(0.5) : theme.tabInactive))
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(theme.tabActiveBorder).frame(height: 1) }
        }
        .overlay(alignment: .bottom) {
            if isActive { Rectangle().fill(theme.tabActive).frame(height: 1) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.activate(doc) }
        .onHover { hovering = $0 }
        .help(doc.url?.path ?? "Not saved yet")
        .contextMenu {
            Button("Close") { model.close(doc) }
            Button("Close Others") { model.closeOthers(doc) }
            Button("Close All") { model.closeAll() }
            Divider()
            Button("Save") { model.save(doc) }
            Button("Save As…") { model.save(doc, as: true) }
            if let url = doc.url {
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Reveal in Explorer") {
                    model.workspace.reveal(url)
                    model.sidebarMode = .explorer
                }
            }
        }
    }
}

struct Breadcrumbs: View {
    let doc: EditorDocument
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            let parts = pathParts
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                if i > 0 { chevron }
                Text(p).foregroundStyle(theme.dimFG)
            }
            if !parts.isEmpty { chevron }
            FileIcon(name: doc.name, size: 10)
            Text(doc.name).foregroundStyle(theme.dimFG)
            ForEach(Array(doc.caret.symbolPath.enumerated()), id: \.offset) { _, s in
                chevron
                Button { model.openPalette(.symbols) } label: {
                    Text(s).foregroundStyle(theme.dimFG).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.editor)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(theme.dimFG.opacity(0.7))
    }

    private var pathParts: [String] {
        guard let url = doc.url else { return [] }
        let rel = model.workspace.relativePath(url.deletingLastPathComponent())
        if let root = model.workspace.root, url.path.hasPrefix(root.path + "/") {
            let dirRel = String(url.deletingLastPathComponent().path.dropFirst(root.path.count)).split(separator: "/").map(String.init)
            return [root.lastPathComponent] + dirRel
        }
        return rel.split(separator: "/").suffix(2).map(String.init)
    }
}

struct DiskChangeBanner: View {
    let doc: EditorDocument
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
            Text("“\(doc.name)” changed on disk while you have unsaved edits.")
                .font(.system(size: 12))
                .foregroundStyle(theme.fg)
            Spacer()
            VSButton(title: "Reload from Disk", secondary: true, fill: false) { model.revert(doc) }
            VSButton(title: "Keep My Version", fill: false) { doc.changedOnDisk = false }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(theme.warning.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HDL Coder")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(theme.fg)
                    Text("A code editor for Verilog, SystemVerilog and VHDL")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(theme.dimFG)
                }
                HStack(alignment: .top, spacing: 64) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start").font(.system(size: 17)).foregroundStyle(theme.fg)
                        LinkRow(icon: "doc.badge.plus", title: "New File", detail: "⌘N") { model.newFile() }
                        LinkRow(icon: "doc.text", title: "New File from Template…", detail: "⌥⌘N") { model.openPalette(.newFile) }
                        LinkRow(icon: "doc", title: "Open File…", detail: "⌘O") { model.showOpenPanel() }
                        LinkRow(icon: "folder", title: "Open Folder…", detail: "⌥⌘O") { model.showOpenFolderPanel() }
                        if AppModel.exampleDir != nil {
                            LinkRow(icon: "cpu", title: "Open Example Project", detail: "counter, UART, adder") { model.openExamples() }
                        }
                    }
                    .frame(minWidth: 240, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent").font(.system(size: 17)).foregroundStyle(theme.fg)
                        if model.recentFolders.isEmpty && model.recentFiles.isEmpty {
                            Text("Nothing opened yet").font(UI.uiFont).foregroundStyle(theme.dimFG)
                        }
                        ForEach(model.recentFolders.prefix(5), id: \.self) { path in recentRow(path, folder: true) }
                        ForEach(model.recentFiles.prefix(6), id: \.self) { path in recentRow(path, folder: false) }
                    }
                }
                HStack(alignment: .top, spacing: 64) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shortcuts").font(.system(size: 17)).foregroundStyle(theme.fg).padding(.bottom, 2)
                        shortcut("Go to file / command palette", "⌘P  ·  ⇧⌘P")
                        shortcut("Go to definition", "F12  ·  ⌘-click")
                        shortcut("Suggestions / next placeholder", "⌃Space  ·  Tab")
                        shortcut("Toggle comment", "⌘/")
                        shortcut("Move / copy line", "⌥↑↓  ·  ⇧⌥↑↓")
                        shortcut("Testbench in HDL Tester", "⌥⌘T")
                        shortcut("Descend / ascend hierarchy", "⌥⌘↓  ·  ⌥⌘↑")
                        shortcut("Run simulation", "⌘R")
                    }
                    .frame(minWidth: 240, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tools").font(.system(size: 17)).foregroundStyle(theme.fg).padding(.bottom, 2)
                        tool("Icarus Verilog", model.tools.iverilog, hint: "brew install icarus-verilog")
                        tool("Verilator", model.tools.verilator, hint: "brew install verilator (optional)")
                        tool("GHDL", model.tools.ghdl, hint: "for VHDL (optional)")
                        tool("HDL Viewer", Simulator.viewerURL?.path, hint: "opens waveforms")
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
    }

    private func recentRow(_ path: String, folder: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: folder ? "folder" : "doc").font(.system(size: 12)).foregroundStyle(theme.dimFG).frame(width: 16)
            Button((path as NSString).lastPathComponent) { model.open([URL(fileURLWithPath: path)]) }
                .buttonStyle(LinkButtonStyle(color: theme.accent))
            Text(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                .font(UI.uiFont).foregroundStyle(theme.dimFG).lineLimit(1).truncationMode(.middle)
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title).font(UI.uiFont).foregroundStyle(theme.fg)
            Spacer(minLength: 16)
            Text(keys).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.dimFG)
        }
        .frame(width: 330)
    }

    private func tool(_ name: String, _ path: String?, hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: path != nil ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(path != nil ? theme.success : theme.dimFG)
                .font(.system(size: 12))
            Text(name).font(UI.uiFont).foregroundStyle(theme.fg)
            Text(path != nil ? "found" : hint).font(.system(size: 12)).foregroundStyle(theme.dimFG)
        }
        .help(path ?? hint)
    }
}

struct LinkRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(theme.accent).frame(width: 18)
            Button(title, action: action).buttonStyle(LinkButtonStyle(color: theme.accent))
            Text(detail).font(.system(size: 12)).foregroundStyle(theme.dimFG)
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            toolStatus
            problemCounts
            if let doc = model.active, model.linting.contains(doc.key) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…")
                }
                .padding(.horizontal, 6)
            }
            runStatus
            Spacer(minLength: 8)
            if let doc = model.active {
                CaretStatus(doc: doc)
                indentMenu(doc)
                item(nil, "UTF-8")
                item(nil, doc.lineEnding)
                languageMenu(doc)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.statusFG)
        .frame(height: 22)
        .background(theme.statusBar)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private var toolStatus: some View {
        let found = model.tools.iverilog != nil
        return HStack(spacing: 5) {
            Image(systemName: found ? "cpu" : "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold))
            Text(found ? "Icarus Verilog \(model.tools.iverilogVersion ?? "")" : "Icarus Verilog not found")
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(found ? theme.statusAccent : theme.error)
        .foregroundStyle(theme.statusAccentFG)
        .help(found ? (model.tools.iverilog ?? "") : "Install with: brew install icarus-verilog — or set the location in Settings")
    }

    private var problemCounts: some View {
        let all = model.allProblems
        let errors = all.filter { $0.severity == .error }.count
        let warnings = all.filter { $0.severity == .warning }.count
        return Button { model.togglePanel(.problems) } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle").font(.system(size: 11))
                Text("\(errors)")
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).padding(.leading, 4)
                Text("\(warnings)")
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show Problems (⇧⌘M)")
    }

    @ViewBuilder private var runStatus: some View {
        Button { model.togglePanel(.output) } label: {
            switch model.runStatus {
            case .idle: EmptyView()
            case .compiling: label("hammer", "Compiling…")
            case .simulating: label("play", "Simulating…")
            case .passed: label("checkmark.circle", "Simulation finished" + (model.lastRunSeconds.map { String(format: " in %.2f s", $0) } ?? ""))
            case .failed(let why): label("xmark.circle", why)
            case .stopped: label("stop.circle", "Stopped")
            }
        }
        .buttonStyle(.plain)
    }

    private func label(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func item(_ icon: String?, _ text: String) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10)) }
            Text(text).lineLimit(1)
        }
        .padding(.horizontal, 7)
    }

    private func indentMenu(_ doc: EditorDocument) -> some View {
        Menu {
            Section("Indent Using Spaces") {
                ForEach([2, 3, 4, 8], id: \.self) { n in
                    Button("Spaces: \(n)") { model.setIndentation(spaces: true, size: n) }
                }
            }
            Section("Indent Using Tabs") {
                ForEach([2, 4, 8], id: \.self) { n in
                    Button("Tab Size: \(n)") { model.setIndentation(spaces: false, size: n) }
                }
            }
            Divider()
            Button("Convert Indentation to Spaces") { doc.editor.convertIndentation(toSpaces: true) }
            Button("Convert Indentation to Tabs") { doc.editor.convertIndentation(toSpaces: false) }
        } label: {
            Text(doc.useSpaces ? "Spaces: \(doc.tabSize)" : "Tab Size: \(doc.tabSize)")
                .foregroundStyle(theme.statusFG)
                .padding(.horizontal, 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func languageMenu(_ doc: EditorDocument) -> some View {
        Menu {
            ForEach(HDLLanguage.allCases) { l in
                Button(l.displayName) { doc.language = l; model.scheduleLint(doc, delay: 0) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "curlybraces").font(.system(size: 10))
                Text(doc.language.displayName)
            }
            .foregroundStyle(theme.statusFG)
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Select Language Mode")
    }
}

/// Split out so caret moves only redraw this part.
struct CaretStatus: View {
    let doc: EditorDocument
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let c = doc.caret
        HStack(spacing: 0) {
            if let n = c.numberHint {
                Text(n)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .help("Value of the number at the cursor")
            }
            Button { model.openPalette(.line) } label: {
                Text("Ln \(c.line), Col \(c.column)" + (c.selected > 0 ? " (\(c.selected) selected\(c.selectedLines > 1 ? ", \(c.selectedLines) lines" : ""))" : ""))
                    .padding(.horizontal, 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to Line (⌃G)")
        }
    }
}
