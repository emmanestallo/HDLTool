import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.sidebarMode == .search ? "SEARCH" : "EXPLORER")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.sidebarFG)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 35)

            if let doc = model.active, let file = doc.file {
                if model.sidebarMode == .search {
                    SearchPane(doc: doc, file: file)
                } else {
                    ExplorerPane(doc: doc, file: file)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("You have not opened a waveform yet.")
                        .font(UI.uiFont)
                        .foregroundStyle(theme.sidebarFG)
                    VSButton(title: "Open Waveform") { model.showOpenPanel() }
                    Text("You can also drag a .vcd file into the window.")
                        .font(UI.uiFont)
                        .foregroundStyle(theme.dimFG)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.sidebar)
    }
}

// MARK: - Explorer

struct ScopeRowItem: Identifiable {
    let scope: VCDScope
    let depth: Int
    var id: Int { scope.id }
}

struct ExplorerPane: View {
    let doc: WaveDocument
    let file: VCDFile
    @Environment(\.theme) private var theme
    @ViewState private var filter = ""
    @ViewState private var hierarchyOpen = true
    @ViewState private var signalsOpen = true

    private var selectedScope: VCDScope? {
        doc.selectedScopeID.flatMap { file.scope(withID: $0) }
    }

    private var rows: [ScopeRowItem] {
        var out: [ScopeRowItem] = []
        if !file.root.vars.isEmpty { out.append(ScopeRowItem(scope: file.root, depth: 0)) }
        func walk(_ s: VCDScope, _ d: Int) {
            for c in s.children {
                out.append(ScopeRowItem(scope: c, depth: d))
                if doc.expandedScopes.contains(c.id) { walk(c, d + 1) }
            }
        }
        walk(file.root, 0)
        return out
    }

    private var vars: [VCDVar] {
        guard let s = selectedScope else { return [] }
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? s.vars : s.vars.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                SectionHeader(title: "HIERARCHY", isOpen: $hierarchyOpen)
                if hierarchyOpen {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                ScopeRow(doc: doc, item: row)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .frame(height: signalsOpen ? max(90, geo.size.height * 0.36) : nil)
                    .frame(maxHeight: signalsOpen ? nil : .infinity)
                }
                SectionHeader(title: "SIGNALS", subtitle: selectedScope?.name, isOpen: $signalsOpen) {
                    if let s = selectedScope, !s.vars.isEmpty {
                        HeaderIconButton(icon: "plus.square.on.square", help: "Add all signals in scope") {
                            doc.add(vars.filter { !doc.isDisplayed($0) })
                        }
                    }
                }
                if signalsOpen {
                    FilterField(text: $filter, placeholder: "Filter signals")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(vars) { v in
                                VarRow(doc: doc, variable: v, showPath: false)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: .infinity)
                    if vars.isEmpty {
                        Text(selectedScope == nil ? "Select a scope above." : "No signals.")
                            .font(UI.uiFont)
                            .foregroundStyle(theme.dimFG)
                            .padding(20)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOpen: Bool
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 14)
            Text(title).font(.system(size: 11, weight: .bold))
            if let subtitle {
                Text("— \(subtitle)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dimFG)
                    .lineLimit(1)
            }
            Spacer()
            trailing()
        }
        .foregroundStyle(theme.sidebarFG)
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { isOpen.toggle() } }
        .onHover { hovering = $0 }
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, isOpen: Binding<Bool>) {
        self.init(title: title, subtitle: subtitle, isOpen: isOpen, trailing: { EmptyView() })
    }
}

struct HeaderIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(theme.sidebarFG)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? theme.listHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct ScopeRow: View {
    let doc: WaveDocument
    let item: ScopeRowItem
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    private var scope: VCDScope { item.scope }
    private var expanded: Bool { doc.expandedScopes.contains(scope.id) }
    private var selected: Bool { doc.selectedScopeID == scope.id }

    private var icon: String {
        switch scope.kind {
        case "module": return "cpu"
        case "task", "function": return "function"
        case "root": return "circle.grid.cross"
        default: return "curlybraces"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if scope.children.isEmpty {
                    Color.clear
                } else {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.sidebarFG.opacity(0.8))
                }
            }
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }

            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(theme.scopeColor(scope.kind))
                .frame(width: 16)
            Text(scope.name.isEmpty ? "(top)" : scope.name)
                .font(UI.uiFont)
                .foregroundStyle(theme.sidebarFG)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !scope.vars.isEmpty {
                Text("\(scope.vars.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.dimFG)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.inputBG))
            }
        }
        .padding(.leading, 8 + CGFloat(item.depth) * 12)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background(selected ? theme.listSelection : (hovering ? theme.listHover : .clear))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(theme.focusBorder.opacity(0.0)).frame(width: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            doc.selectedScopeID = scope.id
            if !expanded && !scope.children.isEmpty { doc.expandedScopes.insert(scope.id) }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Add All Signals") { doc.add(scope.vars.filter { !doc.isDisplayed($0) }) }
                .disabled(scope.vars.isEmpty)
            Button(expanded ? "Collapse" : "Expand") { toggle() }
                .disabled(scope.children.isEmpty)
            Button("Copy Path") { copy(scope.path) }
        }
        .help(scope.path)
    }

    private func toggle() {
        if expanded { doc.expandedScopes.remove(scope.id) } else { doc.expandedScopes.insert(scope.id) }
    }
}

// MARK: - Signals

struct VarRow: View {
    let doc: WaveDocument
    let variable: VCDVar
    let showPath: Bool
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let shown = doc.isDisplayed(variable)
        HStack(spacing: 7) {
            VarBadge(kind: variable.kind)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(variable.name)
                        .font(UI.uiFont)
                        .foregroundStyle(theme.sidebarFG)
                        .lineLimit(1)
                    if !variable.range.isEmpty {
                        Text(variable.range)
                            .font(UI.monoSmall)
                            .foregroundStyle(theme.dimFG)
                            .lineLimit(1)
                    }
                }
                if showPath {
                    Text(variable.scopePath)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dimFG)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if hovering {
                Button { doc.add([variable]) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.sidebarFG)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add to waveform")
            } else if shown {
                Circle().fill(theme.wave1).frame(width: 6, height: 6)
                    .padding(.trailing, 6)
                    .help("Shown in waveform")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(height: showPath ? 36 : 22)
        .background(hovering ? theme.listHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { doc.add([variable]) }
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: "sig:\(variable.id)" as NSString) }
        .contextMenu {
            Button("Add to Waveform") { doc.add([variable]) }
            Button("Copy Path") { copy(variable.fullPath) }
        }
        .help("\(variable.fullPath)  ·  \(variable.kind), \(variable.width) bit\(variable.width == 1 ? "" : "s")")
    }
}

struct VarBadge: View {
    let kind: String
    @Environment(\.theme) private var theme

    private var letter: String {
        switch kind {
        case "wire", "tri", "wand", "wor", "supply0", "supply1", "tri0", "tri1": return "w"
        case "reg", "logic", "bit": return "r"
        case "integer", "int", "longint", "shortint", "byte": return "i"
        case "real", "realtime", "shortreal": return "f"
        case "parameter": return "p"
        case "event": return "e"
        case "string": return "s"
        default: return String(kind.prefix(1))
        }
    }

    var body: some View {
        let c = theme.varColor(kind)
        Text(letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(c)
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(c.opacity(0.85), lineWidth: 1))
    }
}

struct FilterField: View {
    @Binding var text: String
    let placeholder: String
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11))
                .foregroundStyle(theme.dimFG)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(UI.uiFont)
                .foregroundStyle(theme.fg)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(theme.dimFG)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 3).fill(theme.inputBG))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(focused ? theme.focusBorder : theme.inputBorder, lineWidth: 1)
        )
    }
}

// MARK: - Search

struct SearchPane: View {
    let doc: WaveDocument
    let file: VCDFile
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var results: [VCDVar] {
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Array(file.allVars.lazy.filter { $0.fullPath.localizedCaseInsensitiveContains(q) }.prefix(500))
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            FilterField(text: $model.searchText, placeholder: "Search all signals")
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            let r = results
            if !model.searchText.isEmpty {
                HStack {
                    Text("\(r.count)\(r.count == 500 ? "+" : "") result\(r.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dimFG)
                    Spacer()
                    if !r.isEmpty {
                        HeaderIconButton(icon: "plus.square.on.square", help: "Add all results") {
                            doc.add(r.filter { !doc.isDisplayed($0) })
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(r) { v in VarRow(doc: doc, variable: v, showPath: true) }
                }
            }
        }
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
