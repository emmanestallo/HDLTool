import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(model.sidebarMode == .outline ? "TEST OUTLINE" : "AVAILABLE DUTS")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.sidebarFG)
                Spacer()
                if model.sidebarMode != .outline {
                    IconButton(icon: "doc.badge.plus", help: "Open Verilog Files… (⌘O)", color: theme.sidebarFG) { model.showOpenPanel() }
                    IconButton(icon: "arrow.clockwise", help: "Reload All Files", color: theme.sidebarFG) {
                        let files = model.library.files
                        for f in files { model.library.reload(f) }
                        model.libraryChanged(model.library.files)
                    }
                    IconButton(icon: "rectangle.compress.vertical", help: "Collapse All", color: theme.sidebarFG) {
                        model.library.collapsedFiles = Set(model.library.files.map(\.id))
                        model.library.expandedModules = []
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .frame(height: 35)

            if model.sidebarMode == .outline {
                OutlinePane()
            } else {
                DUTListPane()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.sidebar)
    }
}

// MARK: - Sources

struct SourcesSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("sourcesOpen") private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "SOURCES", subtitle: open ? "drag onto the canvas, then wire" : nil, isOpen: $open)
            if open {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(SourcePreset.allCases) { p in SourceTile(preset: p) }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            Rectangle().fill(theme.border).frame(height: 1)
                .padding(.bottom, 8)
        }
    }
}

struct SourceTile: View {
    let preset: SourcePreset
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let c = theme.stimColor(preset.kind)
        HStack(spacing: 6) {
            StimIcon(kind: preset.kind, size: 10, color: c).frame(width: 14)
            Text(preset.title.replacingOccurrences(of: "Reset (active ", with: "Reset (").replacingOccurrences(of: ")", with: ")"))
                .font(.system(size: 11.5))
                .foregroundStyle(theme.sidebarFG)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? theme.listHover : theme.inputBG.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(c.opacity(hovering ? 0.8 : 0.35)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if model.active == nil { model.newTest() }
            if let d = model.active { model.placeSource(preset, in: d) }
        }
        .onDrag {
            NSItemProvider(object: (sourceDragPrefix + preset.rawValue) as NSString)
        } preview: {
            HStack(spacing: 6) {
                StimIcon(kind: preset.kind, size: 11, color: c)
                Text(preset.baseName).font(.system(size: 13, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.blockBG))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c))
            .foregroundStyle(theme.fg)
        }
        .help("\(preset.title): drag onto the canvas (or double-click), then drag from its dot to the inputs it should drive")
    }
}

// MARK: - Available DUTs

struct DUTListPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var filter = ""

    var body: some View {
        let lib = model.library
        SourcesSection()
        if lib.files.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("No Verilog files are open yet.")
                    .font(UI.uiFont)
                    .foregroundStyle(theme.sidebarFG)
                VSButton(title: "Open Verilog File") { model.showOpenPanel() }
                Text("Every module in the files you open shows up here as a DUT. You can also drag .v / .sv files or a folder into the window.")
                    .font(UI.uiFont)
                    .foregroundStyle(theme.dimFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            Spacer()
        } else {
            VSTextField(text: $filter, placeholder: "Filter modules")
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lib.files) { f in
                        let mods = filtered(f.modules)
                        if filter.isEmpty || !mods.isEmpty {
                            FileRow(file: f)
                            if !lib.collapsedFiles.contains(f.id) || !filter.isEmpty {
                                ForEach(mods) { m in
                                    ModuleRow(module: m)
                                    if lib.expandedModules.contains(m.id) {
                                        ForEach(m.ports) { p in PortRow(port: p, module: m) }
                                    }
                                }
                                if f.modules.isEmpty {
                                    Text(f.errors.first ?? "No modules")
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.dimFG)
                                        .padding(.leading, 38)
                                        .frame(height: 22)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            Text("Drag a module onto the canvas, or double-click it. Drag between pin dots to wire them.")
                .font(.system(size: 11))
                .foregroundStyle(theme.dimFG)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }

    private func filtered(_ m: [ModuleInfo]) -> [ModuleInfo] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? m : m.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }
}

struct FileRow: View {
    let file: SourceFile
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let collapsed = model.library.collapsedFiles.contains(file.id)
        HStack(spacing: 5) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.sidebarFG)
                .frame(width: 14)
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(theme.dirColor(.input))
            Text(file.name)
                .font(UI.uiFont)
                .foregroundStyle(theme.sidebarFG)
                .lineLimit(1)
            Text((file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11))
                .foregroundStyle(theme.dimFG)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if !file.errors.isEmpty && !file.modules.isEmpty {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(theme.warning)
                    .help(file.errors.joined(separator: "\n"))
            }
            if hovering {
                Button { model.library.remove(file) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.sidebarFG)
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(hovering ? theme.listHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if collapsed { model.library.collapsedFiles.remove(file.id) } else { model.library.collapsedFiles.insert(file.id) }
        }
        .help(file.url.path)
        .contextMenu {
            Button("Reload") { model.library.reload(file); model.libraryChanged([file]) }
            Button("Open in HDL Coder") { model.openInCoder(file.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Divider()
            Button("Remove from List") { model.library.remove(file) }
        }
    }
}

struct ModuleRow: View {
    let module: ModuleInfo
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let expanded = model.library.expandedModules.contains(module.id)
        let ins = module.inputs.count, outs = module.outputs.count
        HStack(spacing: 5) {
            Button {
                if expanded { model.library.expandedModules.remove(module.id) } else { model.library.expandedModules.insert(module.id) }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.dimFG)
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Image(systemName: "cpu")
                .font(.system(size: 12))
                .foregroundStyle(theme.dirColor(.output))
            Text(module.name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(theme.sidebarFG)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !module.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(theme.warning)
                    .help(module.warnings.joined(separator: "\n"))
            }
            Text("\(ins) in · \(outs) out")
                .font(.system(size: 11))
                .foregroundStyle(theme.dimFG)
            if hovering {
                Button { model.placeInActive(module) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.sidebarFG)
                }
                .buttonStyle(.plain)
                .help("Add to the current test")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(hovering ? theme.listHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.placeInActive(module) }
        .onDrag {
            NSItemProvider(object: (dutDragPrefix + module.id) as NSString)
        } preview: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text(module.name).font(.system(size: 13, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.blockBG))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.focusBorder))
            .foregroundStyle(theme.fg)
        }
        .help("\(module.name) — line \(module.line) of \(module.file.lastPathComponent)\nDrag onto the canvas to test it")
        .contextMenu {
            Button("Add to Current Test") { model.placeInActive(module) }
            Button("Add to New Test") {
                model.newTest()
                model.placeInActive(module)
            }
            Divider()
            Button("Open in HDL Coder") { model.openInCoder(module.file, module: module.name, line: module.line) }
        }
    }
}

struct PortRow: View {
    let port: PortInfo
    let module: ModuleInfo
    @Environment(\.theme) private var theme

    var body: some View {
        let range = port.ranges.map { "[\($0.msb):\($0.lsb)]" }.joined()
        HStack(spacing: 6) {
            Image(systemName: port.dir == .input ? "arrow.right" : (port.dir == .output ? "arrow.left" : "arrow.left.arrow.right"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.dirColor(port.dir))
                .frame(width: 12)
            Text(port.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(port.unsupported == nil ? theme.sidebarFG : theme.dimFG)
            Text(range)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.dimFG)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 58)
        .padding(.trailing, 10)
        .frame(height: 20)
        .help(port.unsupported.map { "Cannot be driven: \($0)" } ?? "\(port.dir.rawValue) \(port.dataType) \(range) \(port.name)")
    }
}

// MARK: - Outline

struct OutlinePane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if let doc = model.active {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !doc.state.sources.isEmpty {
                        OutlineHeading(text: "SOURCES")
                        ForEach(doc.state.sources) { src in
                            let s = src.stimulus("out")
                            HStack(spacing: 6) {
                                StimIcon(kind: s.kind, size: 9, color: theme.stimColor(s.kind)).frame(width: 14)
                                Text(src.name).font(.system(size: 13, design: .monospaced)).foregroundStyle(theme.sidebarFG)
                                Spacer()
                                Text("→ \(doc.state.wires(from: PinRef(instance: src.id, pin: "out")).count)")
                                    .font(.system(size: 11)).foregroundStyle(theme.dimFG)
                                    .help("Number of inputs it drives")
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 24)
                            .background(doc.selection?.instanceID == src.id ? theme.listSelection : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { doc.selection = .instance(src.id) }
                        }
                        OutlineHeading(text: "DUTS")
                    }
                    ForEach(doc.state.duts) { inst in
                        let selected = doc.selection == .instance(inst.id)
                        HStack(spacing: 6) {
                            Image(systemName: "cpu").font(.system(size: 12)).foregroundStyle(theme.dirColor(.output))
                            Text(inst.name).font(.system(size: 13, design: .monospaced)).foregroundStyle(theme.sidebarFG)
                            Text(inst.moduleName).font(.system(size: 11)).foregroundStyle(theme.dimFG)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 24)
                        .background(selected ? theme.listSelection : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { doc.selection = .instance(inst.id) }
                        ForEach(inst.ports) { p in
                            let sel = doc.selection == .pin(inst.id, p.name)
                            HStack(spacing: 6) {
                                Image(systemName: p.dir == .output ? "arrow.left" : "arrow.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(theme.dirColor(p.dir))
                                    .frame(width: 12)
                                Text(p.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.sidebarFG)
                                Spacer()
                                if let d = doc.state.wire(to: PinRef(instance: inst.id, pin: p.name))?.from {
                                    Text("← " + doc.state.describe(d)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.dimFG).lineLimit(1)
                                } else if p.dir == .input && p.unsupported == nil {
                                    Text("not wired").font(.system(size: 11)).foregroundStyle(theme.warning).lineLimit(1)
                                } else if inst.logged.contains(p.name) {
                                    Image(systemName: "text.alignleft").font(.system(size: 10)).foregroundStyle(theme.dimFG)
                                }
                            }
                            .padding(.leading, 34)
                            .padding(.trailing, 12)
                            .frame(height: 22)
                            .background(sel ? theme.listSelection : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { doc.selection = .pin(inst.id, p.name) }
                        }
                    }
                    if !doc.state.wires.isEmpty {
                        OutlineHeading(text: "WIRES")
                        ForEach(doc.state.wires) { w in
                            HStack(spacing: 6) {
                                Text(doc.state.describe(w.from)).foregroundStyle(theme.sidebarFG)
                                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(theme.dimFG)
                                Text(doc.state.describe(w.to)).foregroundStyle(theme.sidebarFG)
                                Spacer()
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: 22)
                            .background(doc.selection == .wire(w.id) ? theme.listSelection : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { doc.selection = .wire(w.id) }
                        }
                    }
                    if doc.state.instances.isEmpty {
                        Text("This test has no DUTs yet.")
                            .font(UI.uiFont)
                            .foregroundStyle(theme.dimFG)
                            .padding(20)
                    }
                }
            }
        } else {
            Spacer()
        }
    }
}

struct OutlineHeading: View {
    let text: String
    @Environment(\.theme) private var theme
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.dimFG)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}
