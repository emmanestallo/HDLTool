import AppKit
import SwiftUI

struct PaletteItem: Identifiable {
    let id: String
    let icon: String
    var iconColor: Color? = nil
    let title: String
    var detail: String = ""
    var trailing: String = ""
    var score = 0
    let action: @MainActor () -> Void
}

/// VS Code-style quick open: files, commands (>), symbols (@), line (:), modules (#) and pickers.
struct PaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("themeID") private var themeID = ThemeID.darkModern.rawValue
    @FocusState private var focused: Bool
    @ViewState private var selected = 0
    @ViewState private var originalTheme: String?

    private var effectiveMode: PaletteMode {
        let mode = model.paletteMode ?? .files
        guard mode == .files || mode == .commands || mode == .symbols || mode == .line || mode == .modules else { return mode }
        let t = model.paletteText
        if t.hasPrefix(">") { return .commands }
        if t.hasPrefix("@") { return .symbols }
        if t.hasPrefix(":") { return .line }
        if t.hasPrefix("#") { return .modules }
        return .files
    }

    private var query: String {
        let t = model.paletteText
        switch effectiveMode {
        case .commands, .symbols, .line, .modules:
            return String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        default:
            return t.trimmingCharacters(in: .whitespaces)
        }
    }

    var body: some View {
        @Bindable var model = model
        let items = computeItems()
        VStack(spacing: 0) {
            TextField("", text: $model.paletteText, prompt: Text(effectiveMode.placeholder).foregroundStyle(theme.dimFG))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.fg)
                .focused($focused)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.inputBG))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.focusBorder, lineWidth: 1))
                .padding(6)
                .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, items.count - 1)); preview(items); return .handled }
                .onKeyPress(.upArrow) { selected = max(selected - 1, 0); preview(items); return .handled }
                .onKeyPress(.escape) { cancel(); return .handled }
                .onKeyPress(.return) { run(items); return .handled }
                .onKeyPress(.pageDown) { selected = min(selected + 10, max(0, items.count - 1)); return .handled }
                .onKeyPress(.pageUp) { selected = max(selected - 10, 0); return .handled }
            if !items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == selected)
                                    .id(i)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selected = i; run(items) }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: min(CGFloat(items.count) * 24 + 4, 420))
                    .onChange(of: selected) { _, s in proxy.scrollTo(s) }
                }
            } else {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.dimFG)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 620)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.widgetBG))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.isDark ? Color(hex: 0x454545) : Color(hex: 0xC8C8C8), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.2), radius: 12, y: 4)
        .onAppear {
            focused = true
            selected = 0
            if model.paletteMode == .theme {
                originalTheme = themeID
                selected = ThemeID.allCases.firstIndex { $0.rawValue == themeID } ?? 0
            }
        }
        .onChange(of: model.paletteText) { _, _ in selected = 0 }
        .onChange(of: model.paletteMode) { _, m in
            focused = true
            selected = 0
            if m == .theme { originalTheme = themeID }
        }
    }

    private var emptyText: String {
        switch effectiveMode {
        case .line:
            let total = model.active?.caret.totalLines ?? 0
            return model.active == nil ? "Open a file first." : "Current line: \(model.active?.caret.line ?? 1). Type a line number between 1 and \(total)."
        case .files: return model.workspace.root == nil && model.docs.isEmpty ? "Open a folder to search its files." : "No matching files."
        case .symbols: return model.active == nil ? "Open a file first." : "No matching symbols."
        case .modules, .instance: return "No modules found in the workspace."
        default: return "No matching results."
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundStyle(item.iconColor ?? theme.dimFG)
                .frame(width: 18)
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
            Text(item.detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.dimFG)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !item.trailing.isEmpty {
                Text(item.trailing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.dimFG)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(theme.secondaryButtonBG.opacity(0.7)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(selected ? theme.listSelection : Color.clear)
    }

    private func run(_ items: [PaletteItem]) {
        guard items.indices.contains(selected) else { return }
        let item = items[selected]
        let modeBefore = model.paletteMode
        let textBefore = model.paletteText
        item.action()
        // The action may have opened another picker.
        if model.paletteMode == modeBefore && model.paletteText == textBefore {
            originalTheme = nil
            model.closePalette()
        }
    }

    private func cancel() {
        if let o = originalTheme { themeID = o }
        originalTheme = nil
        model.closePalette()
    }

    private func preview(_ items: [PaletteItem]) {
        guard model.paletteMode == .theme, items.indices.contains(selected) else { return }
        themeID = ThemeID.allCases[min(selected, ThemeID.allCases.count - 1)].rawValue
    }

    private func ranked(_ items: [PaletteItem], by key: (PaletteItem) -> String, limit: Int = 200) -> [PaletteItem] {
        guard !query.isEmpty else { return Array(items.prefix(limit)) }
        var out: [PaletteItem] = []
        for var it in items {
            if let s = Fuzzy.score(query, key(it)) { it.score = s; out.append(it) }
        }
        out.sort { $0.score > $1.score }
        return Array(out.prefix(limit))
    }

    private func computeItems() -> [PaletteItem] {
        switch effectiveMode {
        case .files: return fileItems()
        case .commands:
            let items = model.commands.map { c in
                PaletteItem(id: c.id, icon: "chevron.right.2", title: c.title, trailing: c.shortcut, action: c.action)
            }
            return ranked(items, by: \.title)
        case .symbols:
            guard let doc = model.active else { return [] }
            let syms = doc.symbols.flatMap { s in [s] + s.children.filter { $0.kind != .port || true }.flatMap { [$0] + ($0.kind == .instance ? [] : $0.children) } }
            let items = syms.map { s in
                PaletteItem(id: s.id, icon: s.kind.icon, iconColor: theme.symbolColor(s.kind), title: s.name,
                            detail: s.kind == .instance ? (s.target ?? "") : s.detail, trailing: s.kind.label) {
                    model.goTo(symbol: s, path: doc.url?.path)
                }
            }
            return ranked(items, by: \.title)
        case .line:
            guard let doc = model.active else { return [] }
            let parts = query.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let l = parts.first ?? nil, l > 0 else { return [] }
            let col = parts.count > 1 ? parts[1] : nil
            let line = min(l, doc.caret.totalLines)
            return [PaletteItem(id: "line", icon: "arrow.right.to.line", title: "Go to line \(line)" + (col.map { ", column \($0)" } ?? "")) {
                model.recordNav()
                doc.editor.reveal(line: line, column: col)
            }]
        case .modules, .instance:
            let insert = effectiveMode == .instance
            let items = model.workspace.allModules.map { def in
                PaletteItem(id: def.path + def.symbol.name, icon: def.symbol.kind.icon, iconColor: theme.symbolColor(def.symbol.kind),
                            title: def.symbol.name, detail: model.workspace.relativePath(URL(fileURLWithPath: def.path)),
                            trailing: "\(def.symbol.ports.count) ports") {
                    if insert {
                        model.insertInstance(of: def.symbol, language: model.workspace.index[def.path]?.language ?? .verilog)
                    } else {
                        model.goTo(symbol: def.symbol, path: def.path)
                    }
                }
            }
            return ranked(items, by: \.title)
        case .snippet:
            let lang = model.active?.language ?? .verilog
            let items = Snippet.available(for: lang == .plain ? .verilog : lang).map { s in
                PaletteItem(id: s.id, icon: "text.badge.plus", title: s.prefix, detail: s.title) {
                    if let d = model.active, d.language != .plain { d.editor.insertSnippet(s) } else { model.showToast("Open a Verilog or VHDL file first") }
                }
            }
            return ranked(items) { $0.title + " " + $0.detail }
        case .theme:
            return ThemeID.allCases.map { t in
                PaletteItem(id: t.rawValue, icon: t.theme.isDark ? "moon" : "sun.max", title: t.displayName, trailing: t.rawValue == (originalTheme ?? themeID) ? "current" : "") {
                    themeID = t.rawValue
                }
            }
        case .newFile:
            let items = Templates.Kind.allCases.map { k in
                PaletteItem(id: k.rawValue, icon: k == .vhdlEntity || k == .vhdlTB ? "curlybraces" : "chevron.left.forwardslash.chevron.right",
                            title: k.title, detail: ".\(k.ext)") {
                    let lang: HDLLanguage = k.ext == "vhd" ? .vhdl : (k.ext == "sv" ? .systemVerilog : .verilog)
                    model.newFile(kind: k, name: k == .empty ? nil : k.defaultName, language: lang)
                }
            }
            return ranked(items, by: \.title)
        case .language:
            return HDLLanguage.allCases.map { l in
                PaletteItem(id: l.rawValue, icon: l.icon, title: l.displayName, trailing: model.active?.language == l ? "current" : "") {
                    if let d = model.active { d.language = l; model.scheduleLint(d, delay: 0) }
                }
            }
        }
    }

    private func fileItems() -> [PaletteItem] {
        var urls: [URL] = []
        var seen = Set<String>()
        // open editors first
        for d in model.docs { if let u = d.url, seen.insert(u.path).inserted { urls.append(u) } }
        for p in model.recentFiles where !seen.contains(p) && FileManager.default.fileExists(atPath: p) && model.workspace.root.map({ p.hasPrefix($0.path) }) ?? true {
            seen.insert(p)
            urls.append(URL(fileURLWithPath: p))
        }
        for u in model.workspace.files where seen.insert(u.path).inserted { urls.append(u) }
        var items = urls.map { u in
            PaletteItem(id: u.path, icon: FileIcon.style(u.lastPathComponent, theme).0, iconColor: FileIcon.style(u.lastPathComponent, theme).1,
                        title: u.lastPathComponent, detail: model.workspace.relativePath(u.deletingLastPathComponent()),
                        trailing: model.docs.contains { $0.url?.path == u.path } ? "open" : "") {
                model.openFile(u)
            }
        }
        // untitled docs
        for d in model.docs where d.url == nil {
            items.insert(PaletteItem(id: d.key, icon: "doc", title: d.name, trailing: "open") { model.activate(d) }, at: 0)
        }
        guard !query.isEmpty else { return Array(items.prefix(60)) }
        var out: [PaletteItem] = []
        for var it in items {
            let nameScore = Fuzzy.score(query, it.title).map { $0 + 30 }
            let pathScore = Fuzzy.score(query, it.detail + "/" + it.title)
            if let s = [nameScore, pathScore].compactMap({ $0 }).max() { it.score = s; out.append(it) }
        }
        out.sort { $0.score > $1.score }
        return Array(out.prefix(100))
    }
}
