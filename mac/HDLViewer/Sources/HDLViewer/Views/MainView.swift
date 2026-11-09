import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 280
    @ViewState private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                ActivityBar()
                if model.sidebarMode != nil {
                    SidebarView()
                        .frame(width: sidebarWidth)
                    ResizeDivider(color: theme.border) { dx in
                        sidebarWidth = min(max(sidebarWidth + Double(dx), 180), 640)
                    }
                }
                EditorArea()
            }
            StatusBar()
        }
        .background(theme.editor)
        .ignoresSafeArea()
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            model.handleFileDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    theme.accent.opacity(0.12)
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(14)
                    Label("Drop to open waveform", systemImage: "arrow.down.doc")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.fg)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .onAppear { ScrollMonitor.install() }
    }
}

// MARK: - Title bar

struct TitleBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.titleBar
            Text(model.active.map { "\($0.name) — HDL Viewer" } ?? "HDL Viewer")
                .font(.system(size: 12))
                .foregroundStyle(theme.titleFG)
            HStack(spacing: 2) {
                Spacer()
                TitleButton(icon: model.sidebarMode == nil ? "sidebar.left" : "sidebar.squares.left",
                            help: "Toggle Sidebar (⌘B)") { model.toggleSidebar() }
                TitleButton(icon: "plus.magnifyingglass", help: "Zoom In (⌘=)") { model.active?.zoom(by: 0.5) }
                TitleButton(icon: "minus.magnifyingglass", help: "Zoom Out (⌘-)") { model.active?.zoom(by: 2) }
                TitleButton(icon: "arrow.left.and.right.square", help: "Zoom to Fit (⌘0)") { model.active?.zoomFit() }
                TitleButton(icon: "arrow.clockwise", help: "Reload (⌘R)") { model.active?.reload() }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 35)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .gesture(WindowDragGesture())
        .simultaneousGesture(TapGesture(count: 2).onEnded { NSApp.keyWindow?.zoom(nil) })
    }
}

struct TitleButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(theme.titleFG)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.listHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Activity bar

struct ActivityBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue

    var body: some View {
        VStack(spacing: 0) {
            item(.explorer, icon: "doc.on.doc", help: "Explorer")
            item(.search, icon: "magnifyingglass", help: "Search Signals (⇧⌘F)")
            Spacer()
            Menu {
                Picker("Color Theme", selection: $themeID) {
                    ForEach(ThemeID.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Auto-Reload When File Changes", isOn: Binding(
                    get: { model.autoReload }, set: { model.setAutoReload($0) }))
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

    private func item(_ mode: SidebarMode, icon: String, help: String) -> some View {
        let active = model.sidebarMode == mode
        return Button {
            model.sidebarMode = active ? nil : mode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(active ? theme.activityFG : theme.activityInactiveFG)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if active { Rectangle().fill(theme.activityActiveBorder).frame(width: 2) }
        }
        .help(help)
    }
}

// MARK: - Editor area & tabs

struct EditorArea: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if !model.docs.isEmpty { TabBar() }
            if let doc = model.active {
                DocumentView(doc: doc).id(doc.id)
            } else {
                WelcomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.editor)
    }
}

struct TabBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.docs) { doc in
                    TabItem(doc: doc, isActive: doc.id == model.activeID)
                }
            }
        }
        .frame(height: 35)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.tabBar)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

struct TabItem: View {
    let doc: WaveDocument
    let isActive: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.wave1)
            Text(doc.name)
                .font(.system(size: 13))
                .foregroundStyle(isActive ? theme.tabActiveFG : theme.tabInactiveFG)
                .lineLimit(1)
            ZStack {
                if doc.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { model.close(doc) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.fg)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isActive || hovering ? 1 : 0)
                    .help("Close (⇧⌘W)")
                }
            }
            .frame(width: 18)
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
        .onTapGesture { model.activeID = doc.id }
        .onHover { hovering = $0 }
        .help(doc.url.path)
    }
}

struct DocumentView: View {
    let doc: WaveDocument
    @Environment(\.theme) private var theme

    var body: some View {
        if let file = doc.file {
            WaveformPanel(doc: doc, file: file)
                .overlay(alignment: .top) {
                    if doc.isLoading {
                        ProgressView(value: max(doc.progress, 0.05))
                            .progressViewStyle(.linear)
                            .tint(theme.accent)
                            .frame(height: 2)
                            .scaleEffect(x: 1, y: 0.5)
                    }
                }
        } else if let err = doc.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(theme.waveZ)
                Text("Could not open \(doc.name)").font(.system(size: 15)).foregroundStyle(theme.fg)
                Text(err).font(UI.uiFont).foregroundStyle(theme.dimFG)
                VSButton(title: "Try Again") { doc.reload() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 14) {
                Text("Parsing \(doc.name)…").font(UI.uiFont).foregroundStyle(theme.dimFG)
                ProgressView(value: doc.progress)
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
                    .frame(width: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                    Text("HDL Viewer")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(theme.fg)
                    Text("Waveforms for your Verilog simulations")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(theme.dimFG)
                }

                HStack(alignment: .top, spacing: 64) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start").font(.system(size: 17)).foregroundStyle(theme.fg)
                        LinkRow(icon: "doc", title: "Open Waveform…", detail: "⌘O") { model.showOpenPanel() }
                        if let example = Self.exampleURL {
                            LinkRow(icon: "waveform.path", title: "Open Example", detail: example.lastPathComponent) {
                                model.open([example])
                            }
                        }
                    }
                    .frame(minWidth: 220, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent").font(.system(size: 17)).foregroundStyle(theme.fg)
                        if model.recentFiles.isEmpty {
                            Text("No recent waveforms").font(UI.uiFont).foregroundStyle(theme.dimFG)
                        }
                        ForEach(model.recentFiles.prefix(8), id: \.self) { path in
                            HStack(spacing: 10) {
                                Button((path as NSString).lastPathComponent) {
                                    model.open([URL(fileURLWithPath: path)])
                                }
                                .buttonStyle(LinkButtonStyle(color: theme.accent))
                                Text(abbreviate((path as NSString).deletingLastPathComponent))
                                    .font(UI.uiFont)
                                    .foregroundStyle(theme.dimFG)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 30, weight: .ultraLight))
                    Text("Drop a .vcd file anywhere in this window")
                        .font(.system(size: 14))
                }
                .foregroundStyle(theme.dimFG)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Generating a VCD with Icarus Verilog")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(theme.fg)
                    Text("""
                    initial begin
                        $dumpfile("wave.vcd");
                        $dumpvars(0, tb);
                    end
                    """)
                    .font(UI.mono)
                    .foregroundStyle(theme.valueFG)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.sidebar))
                    Text("iverilog -o sim tb.v && vvp sim   ·   the viewer reloads automatically when the file changes")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.dimFG)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
    }

    private func abbreviate(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }

    static var exampleURL: URL? {
        let candidates = [
            Bundle.main.url(forResource: "counter", withExtension: "vcd"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("examples/counter.vcd"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
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

struct LinkButtonStyle: ButtonStyle {
    let color: Color
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(UI.uiFont)
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.7 : 1))
            .underline(hovering)
            .onHover { hovering = $0 }
    }
}

struct VSButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(UI.uiFont)
                .foregroundStyle(theme.buttonFG)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.buttonBG))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path").font(.system(size: 11, weight: .semibold))
                Text("VCD").font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(theme.statusAccent)
            .foregroundStyle(theme.statusAccentFG)

            if let doc = model.active, let file = doc.file {
                let ts = file.timescale
                item("clock", "Timescale \(ts)")
                item("list.bullet", "\(doc.displayed.count) / \(file.allVars.count) signals")
                item("flag.checkered", "End \(ts.format(Double(file.endTime)))")
                Spacer(minLength: 8)
                if let h = doc.hoverTime {
                    item("scope", ts.format(h)).opacity(0.75)
                }
                if let c = doc.cursorTime {
                    item("cursorarrow.rays", "Cursor \(ts.format(c))")
                }
                if let m = doc.markerTime {
                    item("mappin", "Marker \(ts.format(m))")
                    if let c = doc.cursorTime {
                        let d = abs(c - m)
                        let f = TimeScale.frequency(period: ts.seconds(d))
                        item("arrow.left.and.right", "Δ \(ts.format(d))" + (f.isEmpty ? "" : "  (\(f))"))
                    }
                }
            } else {
                Spacer()
            }
            if model.autoReload {
                item("arrow.triangle.2.circlepath", "Auto-Reload")
                    .help("The waveform reloads when the file changes on disk")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.statusFG)
        .frame(height: 22)
        .background(theme.statusBar)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private func item(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).lineLimit(1)
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Helpers

struct ResizeDivider: View {
    let color: Color
    let onDrag: (CGFloat) -> Void
    @ViewState private var last: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                onDrag(v.translation.width - last)
                                last = v.translation.width
                            }
                            .onEnded { _ in last = 0 }
                    )
            )
            .zIndex(10)
    }
}

/// Routes trackpad / mouse-wheel gestures over the waveform to pan & zoom,
/// while letting vertical scrolling fall through to the signal list.
@MainActor
enum ScrollMonitor {
    private static var token: Any?

    static func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    private static func handle(_ e: NSEvent) -> Bool {
        guard let doc = AppModel.shared.active, doc.file != nil, doc.isHoveringWaves else { return false }
        let anchor = doc.hoverX
        if e.type == .magnify {
            doc.zoom(by: 1 / max(0.2, 1 + e.magnification), anchorX: anchor)
            return true
        }
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas { dx *= 12; dy *= 12 }
        let mods = e.modifierFlags
        if mods.contains(.command) || mods.contains(.option) || mods.contains(.control) {
            let d = abs(dy) >= abs(dx) ? dy : dx
            doc.zoom(by: exp(-Double(d) * 0.012), anchorX: anchor)
            return true
        }
        if abs(dx) > abs(dy) {
            doc.pan(byPixels: -dx)
            return true
        }
        return false
    }
}
