import AppKit
import SwiftUI

struct SidebarView: View {
    let mode: SidebarMode
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(mode.title)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.sidebarFG)
                Spacer()
                actions
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .frame(height: 35)

            switch mode {
            case .explorer: ExplorerPane()
            case .search: SearchPane()
            case .outline: OutlinePane()
            case .hierarchy: HierarchyPane()
            case .snippets: SnippetsPane()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.sidebar)
    }

    @ViewBuilder private var actions: some View {
        let c = theme.sidebarFG
        switch mode {
        case .explorer:
            if let root = model.workspace.root {
                IconButton(icon: "doc.badge.plus", help: "New File…", color: c) { model.newFile(in: root) }
                IconButton(icon: "folder.badge.plus", help: "New Folder…", color: c) { model.newFolder(in: root) }
                IconButton(icon: "arrow.clockwise", help: "Refresh Explorer", color: c) { model.workspace.refreshListing() }
                IconButton(icon: "rectangle.compress.vertical", help: "Collapse Folders", color: c) { model.workspace.expanded = [] }
            } else {
                IconButton(icon: "folder", help: "Open Folder… (⌥⌘O)", color: c) { model.showOpenFolderPanel() }
            }
        case .search:
            IconButton(icon: "arrow.clockwise", help: "Refresh", color: c) { model.runSearch() }
            IconButton(icon: "clear", help: "Clear Search Results", color: c) {
                model.search.options.query = ""
                model.search.results = []
                model.search.searched = false
            }
            IconButton(icon: "rectangle.compress.vertical", help: "Collapse All", color: c) {
                model.search.collapsed = Set(model.search.results.map(\.path))
            }
        case .outline:
            EmptyView()
        case .hierarchy:
            IconButton(icon: "arrow.clockwise", help: "Rescan Workspace", color: c) { model.workspace.refreshListing() }
        case .snippets:
            IconButton(icon: "plus.rectangle.on.rectangle", help: "Insert Snippet… (⇧⌘J)", color: c) { model.openPalette(.snippet) }
        }
    }
}

/// One row in a sidebar tree.
struct TreeRow<Leading: View, Trailing: View>: View {
    let depth: Int
    var expandable = false
    var expanded = false
    var selected = false
    let title: String
    var detail: String? = nil
    var titleColor: Color? = nil
    var italic = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    let onTap: () -> Void
    var onToggle: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if expandable {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.sidebarFG)
                        .contentShape(Rectangle())
                        .onTapGesture { (onToggle ?? onTap)() }
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            leading()
            Text(title)
                .font(.system(size: 13))
                .italic(italic)
                .foregroundStyle(titleColor ?? theme.sidebarFG)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.dimFG)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 2)
            trailing()
        }
        .padding(.leading, 8 + CGFloat(depth) * 12)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(selected ? theme.listSelection : (hovering ? theme.listHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}

extension TreeRow where Trailing == EmptyView {
    init(depth: Int, expandable: Bool = false, expanded: Bool = false, selected: Bool = false, title: String, detail: String? = nil,
         titleColor: Color? = nil, italic: Bool = false, @ViewBuilder leading: @escaping () -> Leading, onTap: @escaping () -> Void, onToggle: (() -> Void)? = nil) {
        self.init(depth: depth, expandable: expandable, expanded: expanded, selected: selected, title: title, detail: detail,
                  titleColor: titleColor, italic: italic, leading: leading, trailing: { EmptyView() }, onTap: onTap, onToggle: onToggle)
    }
}

// MARK: - Explorer

struct ExplorerPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var openEditorsOpen = true
    @ViewState private var folderOpen = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "OPEN EDITORS", isOpen: $openEditorsOpen) {
                    IconButton(icon: "square.and.arrow.down.on.square", help: "Save All (⌥⌘S)", color: theme.sidebarFG, size: 11) { model.saveAll() }
                    IconButton(icon: "xmark.square", help: "Close All Editors", color: theme.sidebarFG, size: 11) { model.closeAll() }
                }
                if openEditorsOpen {
                    ForEach(model.docs) { doc in
                        TreeRow(depth: 0, selected: doc.id == model.activeID, title: doc.name,
                                detail: doc.url.map { model.workspace.relativePath($0.deletingLastPathComponent()) },
                                italic: doc.url == nil,
                                leading: { FileIcon(name: doc.name) },
                                trailing: {
                                    if doc.isDirty { Circle().fill(theme.fg).frame(width: 7, height: 7) }
                                },
                                onTap: { model.activate(doc) })
                        .contextMenu {
                            Button("Close") { model.close(doc) }
                            Button("Close Others") { model.closeOthers(doc) }
                        }
                    }
                    if model.docs.isEmpty {
                        Text("No open editors").font(.system(size: 12)).foregroundStyle(theme.dimFG).padding(.leading, 28).frame(height: 22)
                    }
                }
                if let root = model.workspace.root {
                    SectionHeader(title: root.lastPathComponent.uppercased(), isOpen: $folderOpen) {
                        IconButton(icon: "doc.badge.plus", help: "New File…", color: theme.sidebarFG, size: 11) { model.newFile(in: root) }
                    }
                    .contextMenu { folderMenu(root) }
                    if folderOpen {
                        let _ = model.workspace.listingVersion
                        ForEach(rows(root), id: \.0.id) { item, depth in
                            fileRow(item, depth: depth)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("You have not yet opened a folder.")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.sidebarFG)
                        VSButton(title: "Open Folder") { model.showOpenFolderPanel() }
                        Text("Opening a folder lets HDL Coder find your modules across files: the design hierarchy, go to definition, and automatic compile order.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.dimFG)
                            .fixedSize(horizontal: false, vertical: true)
                        if AppModel.exampleDir != nil {
                            VSButton(title: "Open Example Project", secondary: true) { model.openExamples() }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
        }
    }

    private func rows(_ dir: URL, depth: Int = 0) -> [(FileItem, Int)] {
        var out: [(FileItem, Int)] = []
        for item in model.workspace.children(of: dir) {
            out.append((item, depth))
            if item.isDir && model.workspace.expanded.contains(item.url.path) {
                out += rows(item.url, depth: depth + 1)
            }
        }
        return out
    }

    @ViewBuilder private func fileRow(_ item: FileItem, depth: Int) -> some View {
        let isActive = model.active?.url?.path == item.url.path
        let errors = item.isDir ? 0 : model.allProblems.filter { $0.file == item.url.path && $0.severity == .error }.count
        TreeRow(depth: depth, expandable: item.isDir, expanded: model.workspace.expanded.contains(item.url.path),
                selected: isActive, title: item.name, titleColor: errors > 0 ? theme.error : nil,
                leading: {
                    if item.isDir {
                        Image(systemName: model.workspace.expanded.contains(item.url.path) ? "folder.fill" : "folder")
                            .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                    } else {
                        FileIcon(name: item.name)
                    }
                },
                trailing: {
                    if errors > 0 {
                        Text("\(errors)").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.error)
                    }
                },
                onTap: {
                    if item.isDir { model.workspace.toggle(item.url) } else { model.openFile(item.url) }
                })
        .contextMenu {
            if item.isDir { folderMenu(item.url) } else { fileMenu(item.url) }
        }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
    }

    @ViewBuilder private func folderMenu(_ url: URL) -> some View {
        Button("New File…") { model.newFile(in: url) }
        Button("New Folder…") { model.newFolder(in: url) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") { copy(url.path) }
        if url != model.workspace.root {
            Divider()
            Button("Rename…") { model.rename(url) }
            Button("Move to Trash") { model.moveToTrash(url) }
        }
    }

    @ViewBuilder private func fileMenu(_ url: URL) -> some View {
        Button("Open") { model.openFile(url) }
        let ext = url.pathExtension.lowercased()
        if ["v", "sv"].contains(ext) {
            Button("Generate Testbench in HDL Tester") { model.generateTestbenchInTester(file: url) }
        }
        if ["vcd", "fst"].contains(ext) {
            Button("Open in HDL Viewer") { Simulator.openInViewer(url) }
        }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") { copy(url.path) }
        Button("Copy Relative Path") { copy(model.workspace.relativePath(url)) }
        Divider()
        Button("Rename…") { model.rename(url) }
        Button("Move to Trash") { model.moveToTrash(url) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Search

struct SearchPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @ViewState private var showInclude = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 2) {
                Button { model.search.showReplace.toggle() } label: {
                    Image(systemName: model.search.showReplace ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.sidebarFG)
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle Replace")
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        TextField("", text: $model.search.options.query, prompt: Text("Search").foregroundStyle(theme.dimFG))
                            .textFieldStyle(.plain)
                            .font(UI.uiFont)
                            .foregroundStyle(theme.fg)
                            .focused($focused)
                            .onSubmit { model.runSearch() }
                        toggle("textformat", on: $model.search.options.caseSensitive, help: "Match Case")
                        toggle("character.cursor.ibeam", on: $model.search.options.wholeWord, help: "Match Whole Word")
                        toggle("asterisk", on: $model.search.options.regex, help: "Use Regular Expression")
                    }
                    .padding(.leading, 6)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 2).fill(theme.inputBG))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(focused ? theme.focusBorder : theme.inputBorder, lineWidth: 1))
                    if model.search.showReplace {
                        HStack(spacing: 4) {
                            VSTextField(text: $model.search.replace, placeholder: "Replace")
                            IconButton(icon: "text.badge.checkmark", help: "Replace All", color: theme.sidebarFG,
                                       disabled: model.search.results.isEmpty) { model.replaceAll() }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button { showInclude.toggle() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(theme.dimFG).frame(width: 20, height: 14)
                }
                .buttonStyle(.plain)
                .help("Toggle Search Details")
            }
            if showInclude {
                Text("files to include").font(.system(size: 11)).foregroundStyle(theme.dimFG)
                VSTextField(text: $model.search.options.include, placeholder: "e.g. *.v, rtl/**") { model.runSearch() }
            }
            summary
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .onAppear { focused = true }
        .onChange(of: model.search.options) { _, _ in model.runSearch() }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.search.results) { r in
                    let collapsed = model.search.collapsed.contains(r.path)
                    TreeRow(depth: 0, expandable: true, expanded: !collapsed, title: (r.path as NSString).lastPathComponent,
                            detail: model.workspace.relativePath(URL(fileURLWithPath: r.path).deletingLastPathComponent()),
                            leading: { FileIcon(name: r.path) },
                            trailing: {
                                Text("\(r.matches.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.fg)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Capsule().fill(theme.secondaryButtonBG))
                            },
                            onTap: {
                                if collapsed { model.search.collapsed.remove(r.path) } else { model.search.collapsed.insert(r.path) }
                            })
                    if !collapsed {
                        ForEach(r.matches) { m in
                            matchRow(r.path, m)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private var summary: some View {
        let s = model.search
        if s.running {
            Text("Searching…").font(.system(size: 12)).foregroundStyle(theme.dimFG)
        } else if s.searched {
            let n = s.results.reduce(0) { $0 + $1.matches.count }
            if s.options.makeRegex() == nil && !s.options.query.isEmpty {
                Text("Invalid regular expression").font(.system(size: 12)).foregroundStyle(theme.error)
            } else if n == 0 {
                Text("No results found." + (model.workspace.root == nil ? " Open a folder to search all its files." : ""))
                    .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(n) result\(n == 1 ? "" : "s") in \(s.results.count) file\(s.results.count == 1 ? "" : "s")")
                    .font(.system(size: 12)).foregroundStyle(theme.dimFG)
            }
        }
    }

    private func toggle(_ icon: String, on: Binding<Bool>, help: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(on.wrappedValue ? theme.fg : theme.dimFG)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 3).fill(on.wrappedValue ? theme.accent.opacity(0.35) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on.wrappedValue ? theme.focusBorder : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .padding(.trailing, 2)
    }

    private func matchRow(_ path: String, _ m: SearchMatch) -> some View {
        var a = AttributedString(m.preview)
        a.foregroundColor = theme.sidebarFG
        if let r = Range(m.range, in: m.preview), let ar = Range(r, in: a) {
            a[ar].backgroundColor = theme.isDark ? Color(hex: 0x9E6A03, alpha: 0.55) : Color(hex: 0xEA5C00, alpha: 0.25)
        }
        if model.search.showReplace && !model.search.replace.isEmpty, let r = Range(m.range, in: m.preview), let ar = Range(r, in: a) {
            a[ar].strikethroughStyle = .single
            var rep = AttributedString(model.search.replace)
            rep.backgroundColor = theme.success.opacity(0.3)
            a.insert(rep, at: ar.upperBound)
        }
        return HStack(spacing: 6) {
            Text(a).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text("\(m.line + 1)").font(.system(size: 10.5)).foregroundStyle(theme.dimFG)
        }
        .padding(.leading, 34)
        .padding(.trailing, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture {
            if let d = model.openFile(URL(fileURLWithPath: path)) {
                d.editor.select(NSRange(location: m.offset, length: m.length))
            }
        }
        .modifier(HoverHighlight())
    }
}

struct HoverHighlight: ViewModifier {
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(hovering ? theme.listHover : Color.clear)
            .onHover { hovering = $0 }
    }
}

// MARK: - Outline

struct OutlinePane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var collapsed: Set<String> = []
    @ViewState private var filter = ""

    var body: some View {
        if let doc = model.active {
            VStack(spacing: 6) {
                VSTextField(text: $filter, placeholder: "Filter symbols")
                    .padding(.horizontal, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let caretLine = doc.caret.line - 1
                        let rows = flatten(doc.symbols, depth: 0)
                        ForEach(rows, id: \.0.id) { s, depth in
                            let expandable = !visibleChildren(s).isEmpty && filter.isEmpty
                            let current = s.line <= caretLine && caretLine <= s.endLine && !s.kind.isContainer && (s.kind == .process || s.kind == .function || s.kind == .task || s.kind == .instance)
                            TreeRow(depth: depth, expandable: expandable, expanded: !collapsed.contains(s.id), selected: current,
                                    title: s.name, detail: detail(s),
                                    leading: {
                                        Image(systemName: s.kind.icon)
                                            .font(.system(size: 11))
                                            .foregroundStyle(s.kind == .port ? theme.dirColor(s.dir ?? "") : theme.symbolColor(s.kind))
                                            .frame(width: 14)
                                    },
                                    onTap: { model.goTo(symbol: s, path: doc.url?.path) },
                                    onToggle: {
                                        if collapsed.contains(s.id) { collapsed.remove(s.id) } else { collapsed.insert(s.id) }
                                    })
                            .help("\(s.kind.label) \(s.name)\(s.detail.isEmpty ? "" : " — \(s.detail)") · line \(s.line + 1)")
                        }
                        if doc.symbols.isEmpty {
                            Text(doc.language == .plain ? "The outline is available for Verilog, SystemVerilog and VHDL files." : "No modules found in this file.")
                                .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                                .padding(.horizontal, 20).padding(.top, 6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } else {
            Text("Open a file to see its outline.")
                .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                .padding(.horizontal, 20)
        }
    }

    private func visibleChildren(_ s: HDLSymbol) -> [HDLSymbol] {
        s.kind == .instance || s.kind == .component ? [] : s.children
    }

    private func detail(_ s: HDLSymbol) -> String {
        switch s.kind {
        case .instance: return s.target ?? ""
        case .port: return s.detail
        case .param, .constant: return s.value.map { "= \($0)" } ?? ""
        case .signal: return s.detail
        case .architecture: return s.detail
        default: return s.detail
        }
    }

    private func flatten(_ syms: [HDLSymbol], depth: Int) -> [(HDLSymbol, Int)] {
        var out: [(HDLSymbol, Int)] = []
        let f = filter.lowercased()
        for s in syms {
            if f.isEmpty {
                out.append((s, depth))
                if !collapsed.contains(s.id) { out += flatten(visibleChildren(s), depth: depth + 1) }
            } else {
                if s.name.lowercased().contains(f) { out.append((s, 0)) }
                out += flatten(visibleChildren(s), depth: 0)
            }
        }
        return out
    }
}

// MARK: - Hierarchy

struct HierarchyPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var collapsed: Set<String> = []

    var body: some View {
        let _ = model.workspace.index.count
        let tops = model.workspace.hierarchy()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if tops.isEmpty {
                    Text(model.workspace.indexing ? "Scanning…" : "No modules found. Open a folder with Verilog, SystemVerilog or VHDL files.")
                        .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                        .padding(.horizontal, 20).padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(flatten(tops, depth: 0), id: \.0.id) { n, depth in
                    TreeRow(depth: depth, expandable: !n.children.isEmpty, expanded: !collapsed.contains(n.id),
                            selected: false,
                            title: n.instance ?? n.module,
                            detail: n.instance != nil ? n.module : (n.children.isEmpty ? nil : "top"),
                            titleColor: n.missing ? theme.error : nil,
                            leading: {
                                Image(systemName: n.instance == nil ? "cpu" : (n.missing ? "questionmark.square.dashed" : "square.on.square"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(n.missing ? theme.error : theme.symbolColor(n.instance == nil ? .module : .instance))
                                    .frame(width: 14)
                            },
                            onTap: { open(n) },
                            onToggle: {
                                if collapsed.contains(n.id) { collapsed.remove(n.id) } else { collapsed.insert(n.id) }
                            })
                    .help(n.missing ? "Module “\(n.module)” is not defined in the workspace" : (n.recursive ? "Recursive instantiation" : "\(n.module)"))
                    .contextMenu {
                        if let def = model.workspace.definitions(of: n.module).first {
                            Button("Go to Module Definition") { model.goTo(symbol: def.symbol, path: def.path) }
                        }
                        if n.instance != nil, let f = n.file {
                            Button("Go to Instance") { model.goTo(path: f, line: n.line + 1) }
                        }
                    }
                }
            }
        }
    }

    private func open(_ n: HierNode) {
        if n.instance == nil {
            if let def = model.workspace.definitions(of: n.module).first { model.goTo(symbol: def.symbol, path: def.path) }
        } else if let def = model.workspace.definitions(of: n.module).first {
            model.goTo(symbol: def.symbol, path: def.path)
        } else if let f = n.file {
            model.goTo(path: f, line: n.line + 1)
        }
    }

    private func flatten(_ nodes: [HierNode], depth: Int) -> [(HierNode, Int)] {
        var out: [(HierNode, Int)] = []
        for n in nodes {
            out.append((n, depth))
            if !collapsed.contains(n.id) { out += flatten(n.children, depth: depth + 1) }
        }
        return out
    }
}

// MARK: - Snippets

struct SnippetsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let lang = model.active?.language ?? .verilog
        let list = Snippet.available(for: lang == .plain ? .verilog : lang)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Click to insert at the cursor, or type the prefix in the editor and pick it from the suggestions. Tab jumps between the highlighted placeholders.")
                    .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 8)
                ForEach(list) { s in
                    TreeRow(depth: 0, title: s.prefix, detail: s.title,
                            leading: {
                                Image(systemName: s.family == .vhdl ? "curlybraces" : (s.family == .systemVerilog ? "s.square" : "text.badge.plus"))
                                    .font(.system(size: 11)).foregroundStyle(theme.dimFG).frame(width: 14)
                            },
                            onTap: {
                                if let d = model.active, d.language != .plain {
                                    d.editor.insertSnippet(s)
                                    d.editor.focus()
                                } else {
                                    model.showToast("Open a Verilog or VHDL file first")
                                }
                            })
                    .help(s.body.replacingOccurrences(of: "\t", with: "    "))
                }
            }
        }
    }
}
