import AppKit
import HDLShell
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("tester.sidebarWidth") private var sidebarWidth: Double = 280
    @AppStorage("tester.inspectorWidth") private var inspectorWidth: Double = 320
    @AppStorage("tester.panelHeight") private var panelHeight: Double = 250
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
                        sidebarWidth = min(max(sidebarWidth + Double(dx), 200), 560)
                    }
                }
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        EditorArea()
                        if model.showPanel, let doc = model.active {
                            ResizeDivider(axis: .horizontal, color: theme.border) { dy in
                                panelHeight = min(max(panelHeight - Double(dy), 120), max(140, Double(geo.size.height) - 160))
                            }
                            BottomPanel(doc: doc)
                                .frame(height: min(panelHeight, max(140, geo.size.height - 160)))
                        }
                    }
                }
                if model.showInspector && model.active != nil {
                    ResizeDivider(color: theme.border) { dx in
                        inspectorWidth = min(max(inspectorWidth - Double(dx), 260), 520)
                    }
                    InspectorView()
                        .frame(width: inspectorWidth)
                }
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
                    Label("Drop Verilog files to add their modules as DUTs", systemImage: "arrow.down.doc")
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
            Text(model.active.map { "\($0.name)\($0.isDirty ? " ●" : "") — HDL Tester" } ?? "HDL Tester")
                .font(.system(size: 12))
                .foregroundStyle(theme.titleFG)
            HStack(spacing: 2) {
                AppTabSwitcher()
                    .padding(.leading, 78)
                Spacer()
                runButton
                    .padding(.trailing, 6)
                IconButton(icon: "waveform.path", help: "Open Last Waveform in HDL Viewer (⌘Y)",
                           disabled: model.active?.lastVCD == nil) {
                    if let v = model.active?.lastVCD { Runner.openInViewer(v) }
                }
                Rectangle().fill(theme.border).frame(width: 1, height: 16).padding(.horizontal, 4)
                let down = model.active.flatMap { model.descendTarget(in: $0) }
                IconButton(icon: "arrow.turn.right.down",
                           help: down.map { "Descend into \($0.name) — edit \(URL(fileURLWithPath: $0.filePath).lastPathComponent) (⌥⌘↓)" }
                               ?? "Descend into DUT — select a DUT first (⌥⌘↓)",
                           disabled: down == nil) {
                    model.descendSelected()
                }
                Rectangle().fill(theme.border).frame(width: 1, height: 16).padding(.horizontal, 4)
                IconButton(icon: model.sidebarMode == nil ? "sidebar.left" : "sidebar.squares.left",
                           help: "Toggle Sidebar (⌘B)") { model.toggleSidebar() }
                IconButton(icon: model.showPanel ? "rectangle.bottomthird.inset.filled" : "rectangle",
                           help: "Toggle Panel (⌘J)") { model.showPanel.toggle() }
                IconButton(icon: model.showInspector ? "sidebar.squares.right" : "sidebar.right",
                           help: "Toggle Inspector (⌥⌘B)") { model.showInspector.toggle() }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 35)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .gesture(WindowDragGesture())
        .simultaneousGesture(TapGesture(count: 2).onEnded { NSApp.keyWindow?.zoom(nil) })
    }

    @ViewBuilder private var runButton: some View {
        let running = model.active?.status.isRunning ?? false
        let enabled = !(model.active?.state.duts.isEmpty ?? true)
        Button {
            if let d = model.active {
                if running { Runner.stop(d) } else { model.runActive() }
            }
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
        .help(running ? "Stop the simulation (⌘.)" : "Generate the testbench, compile and simulate (⌘R)")
    }
}

// MARK: - Activity bar

struct ActivityBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            item(.duts, icon: "cpu", help: "Available DUTs")
            item(.outline, icon: "list.bullet.indent", help: "Test Outline")
            Spacer()
            Menu {
                Picker("Color Theme", selection: $themeID) {
                    ForEach(ThemeID.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Open Waveforms in HDL Viewer", isOn: $model.openResultsInViewer)
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
            if !model.tests.isEmpty { TabBar() }
            if let doc = model.active {
                TestCanvasView(doc: doc).id(doc.id)
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
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tests) { doc in
                        TabItem(doc: doc, isActive: doc.id == model.activeID)
                    }
                }
            }
            IconButton(icon: "plus", help: "New Test (⌘N)", color: theme.tabInactiveFG, size: 12) { model.newTest() }
                .padding(.horizontal, 6)
        }
        .frame(height: 35)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.tabBar)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

struct TabItem: View {
    let doc: TestDocument
    let isActive: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false
    @ViewState private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            Text(doc.name)
                .font(.system(size: 13))
                .foregroundStyle(isActive ? theme.tabActiveFG : theme.tabInactiveFG)
                .lineLimit(1)
            Text("\(doc.state.duts.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.dimFG)
                .help("\(doc.state.duts.count) DUTs")
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
            .help("Close (⇧⌘W)")
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
        .help(doc.fileURL?.path ?? "Not saved yet")
        .contextMenu {
            Button("Save") { model.save(doc, as: false) }
            Button("Save As…") { model.save(doc, as: true) }
            Divider()
            Button("Close") { model.close(doc) }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch doc.status {
        case .compiling, .simulating:
            ProgressView().controlSize(.mini).frame(width: 14)
        case .passed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(theme.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(theme.error)
        default:
            Image(systemName: "testtube.2").font(.system(size: 12)).foregroundStyle(theme.wave1)
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
                    Text("HDL Tester")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(theme.fg)
                    Text("Testbenches for your Verilog modules, without writing one")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(theme.dimFG)
                }
                HStack(alignment: .top, spacing: 64) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start").font(.system(size: 17)).foregroundStyle(theme.fg)
                        LinkRow(icon: "plus.square", title: "New Test", detail: "⌘N") { model.newTest() }
                        LinkRow(icon: "doc", title: "Open Verilog File…", detail: "⌘O") { model.showOpenPanel() }
                        if Self.exampleDir != nil {
                            LinkRow(icon: "testtube.2", title: "Open Example Test", detail: "4 DUTs") { model.openExample() }
                            LinkRow(icon: "point.topleft.down.to.point.bottomright.curvepath", title: "Open Wired Example", detail: "DUTs wired together") {
                                model.openExample("wired.hdltest")
                            }
                        }
                    }
                    .frame(minWidth: 220, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent Tests").font(.system(size: 17)).foregroundStyle(theme.fg)
                        if model.recentTests.isEmpty {
                            Text("No saved tests yet").font(UI.uiFont).foregroundStyle(theme.dimFG)
                        }
                        ForEach(model.recentTests.prefix(8), id: \.self) { path in
                            HStack(spacing: 10) {
                                Button((path as NSString).lastPathComponent) { model.open([URL(fileURLWithPath: path)]) }
                                    .buttonStyle(LinkButtonStyle(color: theme.accent))
                                Text(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                                    .font(UI.uiFont).foregroundStyle(theme.dimFG).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("How it works").font(.system(size: 17)).foregroundStyle(theme.fg)
                    step(1, "Open .v / .sv files. Every module appears under Available DUTs.")
                    step(2, "Drag modules onto a test's canvas. Each becomes a box with its input and output pins.")
                    step(3, "Add sources (clock, reset, constant, sequence, bit stream, counter, random) and drag from their dots to the DUT inputs. Outputs can be wired to other DUTs' inputs too.")
                    step(4, "Press Run (⌘R). HDL Tester writes the testbench, runs Icarus Verilog and opens the waveform in HDL Viewer.")
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.buttonFG)
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.accent))
            Text(text).font(.system(size: 14)).foregroundStyle(theme.fg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    static var exampleDir: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("examples"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("examples"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("demo.hdltest").path)
        }
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
            if let doc = model.active {
                let gen = model.generated(for: doc)
                let errors = gen.problems.filter { $0.severity == .error }.count
                let warnings = gen.problems.count - errors
                Button {
                    model.panelTab = .problems
                    model.showPanel = true
                } label: {
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
                .help("Show Problems")
                item("cpu", "\(doc.state.duts.count) DUT\(doc.state.duts.count == 1 ? "" : "s")")
                if !doc.state.wires.isEmpty {
                    item("point.topleft.down.to.point.bottomright.curvepath", "\(doc.state.wires.count) wire\(doc.state.wires.count == 1 ? "" : "s")")
                }
                item("clock", "\(Fmt.num(doc.state.duration)) \(doc.state.unit.rawValue)")
                Spacer(minLength: 8)
                runStatus(doc)
                item("ruler", "`timescale 1\(doc.state.unit.rawValue)/1\(doc.state.precision.rawValue)")
            } else {
                Spacer()
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
            Text(found ? "Icarus Verilog \(model.tools.version ?? "")" : "Icarus Verilog not found")
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(found ? theme.statusAccent : theme.error)
        .foregroundStyle(theme.statusAccentFG)
        .help(found ? (model.tools.iverilog ?? "") : "Install with: brew install icarus-verilog — or set the location in Settings")
    }

    @ViewBuilder private func runStatus(_ doc: TestDocument) -> some View {
        Button {
            model.panelTab = .output
            model.showPanel = true
        } label: {
            switch doc.status {
            case .idle: EmptyView()
            case .compiling: label("hammer", "Compiling…")
            case .simulating: label("play", "Simulating…")
            case .passed:
                label("checkmark.circle", "Simulation finished" + (doc.lastRunSeconds.map { String(format: " in %.2f s", $0) } ?? ""))
            case .failed(let why): label("xmark.circle", why).foregroundStyle(theme.isDark ? theme.error : theme.error)
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

    private func item(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).lineLimit(1)
        }
        .padding(.horizontal, 8)
    }
}
