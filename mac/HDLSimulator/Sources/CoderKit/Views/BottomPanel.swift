import AppKit
import SwiftUI

struct BottomPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(PanelTab.allCases) { tabButton($0) }
                Spacer()
                actions
                IconButton(icon: "xmark", help: "Close Panel (⌘J)", size: 12) { model.showPanel = false }
                    .padding(.trailing, 8)
            }
            .frame(height: 35)
            switch model.panelTab {
            case .problems: ProblemsView()
            case .output: OutputView()
            }
        }
        .background(theme.editor)
    }

    private func tabButton(_ tab: PanelTab) -> some View {
        let on = model.panelTab == tab
        let count = tab == .problems ? model.allProblems.count : 0
        return Button { model.panelTab = tab } label: {
            HStack(spacing: 5) {
                Text(tab.title).font(.system(size: 11))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.buttonFG)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(model.allProblems.contains { $0.severity == .error } ? theme.error : theme.accent))
                }
                if tab == .output && model.runStatus.isRunning { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(on ? theme.tabActiveFG : theme.tabInactiveFG)
            .padding(.horizontal, 10)
            .frame(height: 35)
            .overlay(alignment: .bottom) {
                if on { Rectangle().fill(theme.tabActiveFG.opacity(0.85)).frame(height: 1).padding(.horizontal, 10) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var actions: some View {
        switch model.panelTab {
        case .problems:
            IconButton(icon: "arrow.clockwise", help: "Check Again (⇧⌘B)", size: 12, disabled: model.active == nil) { model.lintActive() }
        case .output:
            if model.lastVCD != nil {
                IconButton(icon: "waveform.path", help: "Open Waveform in HDL Viewer (⌘Y)", size: 12) { model.openLastWaveform() }
            }
            if let dir = model.active?.url?.deletingLastPathComponent().appendingPathComponent("sim_out"),
               FileManager.default.fileExists(atPath: dir.path) {
                IconButton(icon: "folder", help: "Reveal sim_out Folder", size: 12) { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
            }
            IconButton(icon: "doc.on.doc", help: "Copy Output", size: 12) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.output.map(\.text).joined(separator: "\n"), forType: .string)
            }
            IconButton(icon: "trash", help: "Clear Output", size: 12) { model.output = [] }
        }
    }
}

struct ProblemsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var collapsed: Set<String> = []

    var body: some View {
        let problems = model.allProblems
        let files = Dictionary(grouping: problems, by: \.file)
        let order = files.keys.sorted { a, b in
            if a == model.active?.key { return true }
            if b == model.active?.key { return false }
            return a < b
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if problems.isEmpty {
                    emptyState
                }
                ForEach(order, id: \.self) { file in
                    let list = files[file] ?? []
                    let name = displayName(file)
                    TreeRow(depth: 0, expandable: true, expanded: !collapsed.contains(file), title: name.0, detail: name.1,
                            leading: { FileIcon(name: name.0) },
                            trailing: {
                                Text("\(list.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.fg)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Capsule().fill(theme.secondaryButtonBG))
                            },
                            onTap: { if collapsed.contains(file) { collapsed.remove(file) } else { collapsed.insert(file) } })
                    if !collapsed.contains(file) {
                        ForEach(list) { d in row(d) }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private var emptyState: some View {
        let t = model.tools
        let hasLinter = t.iverilog != nil || t.verilator != nil || (model.active?.language == .vhdl && t.ghdl != nil)
        VStack(alignment: .leading, spacing: 4) {
            if !hasLinter {
                Text(model.active?.language == .vhdl
                     ? "Install GHDL to check VHDL files as you type."
                     : "Install Icarus Verilog to check your code as you type:  brew install icarus-verilog")
            } else if model.linterKind == .off {
                Text("Checking is turned off in Settings.")
            } else {
                Text("No problems have been detected" + (model.lastLintTool.map { " (checked with \($0))" } ?? "") + ".")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.dimFG)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .textSelection(.enabled)
    }

    private func displayName(_ key: String) -> (String, String) {
        if key.hasPrefix("untitled:"), let d = model.docs.first(where: { $0.key == key }) { return (d.name, "") }
        let url = URL(fileURLWithPath: key)
        return (url.lastPathComponent, model.workspace.relativePath(url.deletingLastPathComponent()))
    }

    private func row(_ d: Diagnostic) -> some View {
        let color = d.severity == .error ? theme.error : (d.severity == .warning ? theme.warning : theme.info)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: d.severity.icon).font(.system(size: 11)).foregroundStyle(color)
            Text(d.message).font(.system(size: 12.5)).foregroundStyle(theme.fg).lineLimit(2)
            Text(d.source).font(.system(size: 11.5)).foregroundStyle(theme.dimFG)
            Text("[Ln \(d.line)\(d.column.map { ", Col \($0)" } ?? "")]").font(.system(size: 11.5)).foregroundStyle(theme.dimFG)
            Spacer(minLength: 0)
        }
        .padding(.leading, 34)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .onTapGesture { model.goTo(path: d.file, line: d.line, column: d.column) }
        .modifier(HoverHighlight())
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(d.file):\(d.line): \(d.message)", forType: .string)
            }
        }
    }
}

struct OutputView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.output.isEmpty {
                        Text("Press Run (⌘R) to compile and simulate the active file. The top module without ports is used as the testbench; modules it instantiates are found in the open folder.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.dimFG)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                    ForEach(model.output) { line in
                        lineView(line).id(line.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .textSelection(.enabled)
            }
            .onChange(of: model.output.count) { _, _ in
                if let last = model.output.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func lineView(_ l: LogLine) -> some View {
        let color: Color = {
            switch l.kind {
            case .info: return theme.dimFG
            case .command: return theme.synKeyword
            case .stdout: return theme.fg
            case .error: return theme.error
            case .warning: return theme.warning
            case .success: return theme.success
            }
        }()
        if let link = l.link {
            Text(l.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color)
                .underline(true, color: color.opacity(0.5))
                .onTapGesture { model.goTo(path: link.path, line: link.line) }
                .help("Go to \((link.path as NSString).lastPathComponent):\(link.line)")
        } else {
            Text(l.text.isEmpty ? " " : l.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}
