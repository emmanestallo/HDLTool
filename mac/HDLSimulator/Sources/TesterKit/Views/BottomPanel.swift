import AppKit
import SwiftUI

struct BottomPanel: View {
    let doc: TestDocument
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let gen = model.generated(for: doc)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(PanelTab.allCases) { tab in
                    tabButton(tab, gen: gen)
                }
                Spacer()
                actions(gen: gen)
                IconButton(icon: "xmark", help: "Close Panel (⌘J)", size: 12) { model.showPanel = false }
                    .padding(.trailing, 8)
            }
            .frame(height: 35)
            switch model.panelTab {
            case .testbench: CodeView(source: gen.source)
            case .output: LogView(doc: doc)
            case .problems: ProblemsView(doc: doc, problems: gen.problems)
            case .stimulus: StimulusTimeline(doc: doc)
            }
        }
        .background(theme.editor)
    }

    private func tabButton(_ tab: PanelTab, gen: TBGenerator.Output) -> some View {
        let on = model.panelTab == tab
        let count = tab == .problems ? gen.problems.count : 0
        return Button { model.panelTab = tab } label: {
            HStack(spacing: 5) {
                Text(tab.title).font(.system(size: 11))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.buttonFG)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(gen.problems.contains { $0.severity == .error } ? theme.error : theme.accent))
                }
                if tab == .output && doc.status.isRunning {
                    ProgressView().controlSize(.mini)
                }
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

    @ViewBuilder private func actions(gen: TBGenerator.Output) -> some View {
        switch model.panelTab {
        case .testbench:
            IconButton(icon: "doc.on.doc", help: "Copy Testbench", size: 12) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(gen.source, forType: .string)
            }
            IconButton(icon: "square.and.arrow.down", help: "Save Testbench As…", size: 12) {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = gen.topName + ".v"
                if panel.runModal() == .OK, let url = panel.url {
                    try? gen.source.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        case .output:
            if let v = doc.lastVCD {
                IconButton(icon: "waveform.path", help: "Open \(v.lastPathComponent) in HDL Viewer (⌘Y)", size: 12) { Runner.openInViewer(v) }
            }
            IconButton(icon: "folder", help: "Reveal Output Folder", size: 12) {
                let d = Runner.outputDir(for: doc)
                if FileManager.default.fileExists(atPath: d.path) { NSWorkspace.shared.activateFileViewerSelecting([d]) }
            }
            IconButton(icon: "doc.on.doc", help: "Copy Output", size: 12) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(doc.log.map(\.text).joined(separator: "\n"), forType: .string)
            }
            IconButton(icon: "trash", help: "Clear Output", size: 12) { doc.log = [] }
        default:
            EmptyView()
        }
    }
}

// MARK: - Testbench code

struct CodeView: View {
    let source: String
    @Environment(\.theme) private var theme

    var body: some View {
        let lines = source.components(separatedBy: "\n")
        let gutter = CGFloat(String(lines.count).count) * 7.5 + 22
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    HStack(spacing: 0) {
                        Text("\(i + 1)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.lineNumber)
                            .frame(width: gutter, alignment: .trailing)
                            .padding(.trailing, 18)
                        Text(Highlighter.line(line, theme: theme))
                            .font(.system(size: 12, design: .monospaced))
                            .fixedSize()
                    }
                    .frame(height: 18)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 6)
            .padding(.trailing, 20)
        }
    }
}

enum Highlighter {
    static let types: Set<String> = ["reg", "wire", "integer", "logic", "signed", "real", "time", "genvar", "localparam", "parameter"]

    static func line(_ s: String, theme: Theme) -> AttributedString {
        var out = AttributedString()
        func add(_ t: String, _ c: Color) {
            var a = AttributedString(t)
            a.foregroundColor = c
            out += a
        }
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                add(String(chars[i...]), theme.synComment)
                break
            }
            if c == "\"" {
                var j = i + 1
                while j < chars.count && chars[j] != "\"" { if chars[j] == "\\" { j += 1 }; j += 1 }
                j = min(j + 1, chars.count)
                add(String(chars[i..<j]), theme.synString)
                i = j
                continue
            }
            if c == "`" || c == "$" {
                var j = i + 1
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                add(String(chars[i..<j]), c == "`" ? theme.synDirective : theme.synSystem)
                i = j
                continue
            }
            if c.isNumber || (c == "'" && i + 1 < chars.count && "bodhsBODHS".contains(chars[i + 1])) || (c == "#" && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i + 1
                while j < chars.count && (chars[j].isHexDigit || "'xXzZ_.bodhsBODHS".contains(chars[j])) { j += 1 }
                add(String(chars[i..<j]), theme.synNumber)
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i + 1
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$") { j += 1 }
                let w = String(chars[i..<j])
                if types.contains(w) {
                    add(w, theme.synType)
                } else if VerilogParser.keywords.contains(w) {
                    add(w, theme.synKeyword)
                } else {
                    add(w, theme.synIdent)
                }
                i = j
                continue
            }
            add(String(c), theme.fg)
            i += 1
        }
        return out
    }
}

// MARK: - Output log

struct LogView: View {
    let doc: TestDocument
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if doc.log.isEmpty {
                        Text(doc.status == .idle ? "Run the test (⌘R) to compile it with Icarus Verilog and simulate it." : "")
                            .font(UI.mono)
                            .foregroundStyle(theme.dimFG)
                            .padding(.vertical, 4)
                    }
                    ForEach(doc.log) { l in
                        Text(l.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(color(l.kind))
                            .fontWeight(l.kind == .success ? .semibold : .regular)
                            .fixedSize()
                            .frame(minHeight: 17, alignment: .leading)
                            .id(l.id)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
            .onChange(of: doc.log.count) { _, _ in
                if let last = doc.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(_ k: LogLine.Kind) -> Color {
        switch k {
        case .command: return theme.synSystem
        case .info: return theme.dimFG
        case .stdout: return theme.fg
        case .warning: return theme.warning
        case .error: return theme.error
        case .success: return theme.success
        }
    }
}

// MARK: - Problems

struct ProblemsView: View {
    let doc: TestDocument
    let problems: [Problem]
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if problems.isEmpty {
                    Text("No problems have been detected in this test.")
                        .font(UI.uiFont)
                        .foregroundStyle(theme.dimFG)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 20)
                }
                ForEach(problems) { p in
                    ProblemRow(doc: doc, problem: p)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct ProblemRow: View {
    let doc: TestDocument
    let problem: Problem
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: problem.severity == .error ? "xmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(problem.severity == .error ? theme.error : theme.warning)
            Text(problem.message).font(UI.uiFont).foregroundStyle(theme.fg)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 24)
        .background(hovering ? theme.listHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let w = problem.wire { doc.selection = .wire(w); return }
            guard let id = problem.instance else { doc.selection = nil; return }
            doc.selection = problem.pin.map { .pin(id, $0) } ?? .instance(id)
        }
    }
}

// MARK: - Stimulus timeline

struct StimulusTimeline: View {
    let doc: TestDocument
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var zoom: Double = 1
    @ViewState private var position: Double = 0

    var body: some View {
        let duration = max(doc.state.duration, 1e-9)
        let span = duration / zoom
        let start = (duration - span) * position
        let labelW: CGFloat = 190
        let st = doc.state
        let rows = st.sources.compactMap { s in s.ports.first.map { (s, $0) } }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Zoom").font(.system(size: 11)).foregroundStyle(theme.dimFG)
                Slider(value: Binding(get: { log2(zoom) }, set: { zoom = pow(2, $0) }), in: 0...8)
                    .frame(width: 140)
                    .controlSize(.mini)
                Text("Position").font(.system(size: 11)).foregroundStyle(theme.dimFG)
                Slider(value: $position, in: 0...1)
                    .frame(width: 180)
                    .controlSize(.mini)
                    .disabled(zoom <= 1.001)
                Spacer()
                Text("Inputs over the whole test (\(Fmt.num(doc.state.duration)) \(doc.state.unit.rawValue)). Outputs appear after a run, in HDL Viewer.")
                    .font(.system(size: 11)).foregroundStyle(theme.dimFG).lineLimit(1)
            }
            .padding(.horizontal, 20)
            .frame(height: 26)
            HStack(spacing: 0) {
                Spacer().frame(width: labelW)
                TimeRulerWindow(start: start, end: start + span, unit: doc.state.unit)
                    .frame(height: 18)
            }
            .padding(.trailing, 20)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("Add a source block (Clock, Reset, …) to see its signal here.")
                            .font(UI.uiFont).foregroundStyle(theme.dimFG).padding(12)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        let (inst, port) = row
                        let s = inst.stimulus(port.name)
                        let w = inst.resolve(port)?.width
                        let selected = inst.isSource ? doc.selection?.instanceID == inst.id : doc.selection == .pin(inst.id, port.name)
                        HStack(spacing: 0) {
                            HStack(spacing: 6) {
                                StimIcon(kind: s.kind, size: 9, color: theme.stimColor(s.kind)).frame(width: 14)
                                Text(inst.isSource ? "" : inst.name + ".").foregroundStyle(theme.dimFG)
                                    + Text(inst.isSource ? inst.name : port.name).foregroundStyle(theme.fg)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .frame(width: labelW - 10, alignment: .leading)
                            .padding(.leading, 10)
                            StimWave(segs: StimulusPreview.segments(s, width: w, horizon: start + span),
                                     horizon: start + span, color: theme.stimColor(s.kind), start: start)
                                .frame(height: 24)
                        }
                        .padding(.trailing, 20)
                        .frame(height: 30)
                        .background(selected ? theme.listSelection.opacity(0.6) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { doc.selection = inst.isSource ? .instance(inst.id) : .pin(inst.id, port.name) }
                    }
                }
            }
        }
    }
}

struct TimeRulerWindow: View {
    let start: Double
    let end: Double
    let unit: TimeUnit
    @Environment(\.theme) private var theme

    var body: some View {
        let dim = theme.dimFG, border = theme.border
        Canvas { ctx, size in
            let span = end - start
            guard span > 0 else { return }
            let step = Ticks.step(span: span, maxTicks: max(1, Int(size.width / 90)))
            var t = (start / step).rounded(.up) * step
            while t <= end + step * 0.001 {
                let x = CGFloat((t - start) / span) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 5))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(tick, with: .color(border), lineWidth: 1)
                ctx.draw(Text(Fmt.num(t) + " " + unit.rawValue).font(.system(size: 10, design: .monospaced)).foregroundColor(dim),
                         at: CGPoint(x: x + 3, y: size.height / 2 - 1), anchor: x > size.width - 50 ? .trailing : .leading)
                t += step
            }
        }
    }
}
