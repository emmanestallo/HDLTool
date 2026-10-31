import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(theme.sidebarFG)
                Spacer()
                if model.active?.selection != nil {
                    IconButton(icon: "gearshape", help: "Test Settings", color: theme.sidebarFG, size: 12) {
                        model.active?.selection = nil
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 35)
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.sidebar)
    }

    private var title: String {
        guard let doc = model.active else { return "TEST SETTINGS" }
        switch doc.selection {
        case .wire?: return "WIRE"
        case .pin(let id, _)?, .instance(let id)?:
            return doc.state.instance(id)?.isSource == true ? "SOURCE" : (doc.selection.map { if case .pin = $0 { return "PIN" }; return "DUT" } ?? "DUT")
        default: return "TEST SETTINGS"
        }
    }

    @ViewBuilder private var content: some View {
        if let doc = model.active {
            switch doc.selection {
            case .wire(let wid)?:
                if let w = doc.state.wires.first(where: { $0.id == wid }) {
                    WireInspector(doc: doc, wire: w).id(wid)
                }
            case .pin(let id, _)? where doc.state.instance(id)?.isSource == true:
                if let inst = doc.state.instance(id) { SourceInspector(doc: doc, inst: inst).id(id) }
            case .instance(let id)? where doc.state.instance(id)?.isSource == true:
                if let inst = doc.state.instance(id) { SourceInspector(doc: doc, inst: inst).id(id) }
            case .pin(let id, let pin)?:
                if let inst = doc.state.instance(id), let port = inst.ports.first(where: { $0.name == pin }) {
                    PinInspector(doc: doc, inst: inst, port: port).id("\(id)-\(pin)")
                }
            case .instance(let id)?:
                if let inst = doc.state.instance(id) {
                    InstanceInspector(doc: doc, inst: inst).id(id)
                }
            case nil:
                TestSettingsView(doc: doc).id(doc.id)
            }
        } else {
            Text("No test is open.").font(UI.uiFont).foregroundStyle(theme.dimFG)
        }
    }
}

struct InspectorHeading: View {
    let text: String
    @Environment(\.theme) private var theme
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(theme.dimFG)
            .padding(.top, 6)
    }
}

// MARK: - Pin

struct PinInspector: View {
    let doc: TestDocument
    let inst: DUTInstance
    let port: PortInfo
    /// Inside the source inspector: stimulus only (sources are the only blocks with a stimulus).
    var embedded = false
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var stim: Binding<Stimulus> {
        let id = inst.id, pin = port.name
        return Binding(
            get: { doc.state.instance(id)?.stimulus(pin) ?? Stimulus() },
            set: { new in
                if let i = doc.index(of: id) { doc.state.instances[i].stimuli[pin] = new }
            })
    }

    private func setKind(_ k: StimKind) {
        var s = stim.wrappedValue
        guard s.kind != k else { return }
        s.kind = k
        if k == .sequence && s.steps.isEmpty {
            s.seqInitial = "0"
            s.steps = [SeqStep(delay: 20, value: "1")]
        }
        apply(s)
    }

    private func apply(_ s: Stimulus) {
        let id = inst.id, pin = port.name
        doc.edit { st in
            if let i = st.instances.firstIndex(where: { $0.id == id }) { st.instances[i].stimuli[pin] = s }
        }
    }

    var body: some View {
        let env = inst.paramValues()
        let width = inst.resolve(port, env: env)?.width
        let range = inst.rangeLabel(port, env: env)
        let ref = PinRef(instance: inst.id, pin: port.name)
        let driver = doc.state.wire(to: ref)?.from
        VStack(alignment: .leading, spacing: 12) {
            if embedded {
                stimulusBody(width: width)
            } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text(inst.name + ".").foregroundStyle(theme.dimFG)
                    Text(port.name).foregroundStyle(theme.fg).fontWeight(.semibold)
                }
                .font(.system(size: 15, design: .monospaced))
                .lineLimit(1)
                HStack(spacing: 6) {
                    Text(port.dir.rawValue).foregroundStyle(theme.dirColor(port.dir))
                    Text("·")
                    Text(width.map { "\($0) bit\($0 == 1 ? "" : "s")" } ?? "width unknown")
                    if !range.isEmpty { Text(range).font(UI.monoSmall) }
                    if !port.dataType.isEmpty { Text("· \(port.dataType)") }
                }
                .font(.system(size: 12))
                .foregroundStyle(theme.dimFG)
            }
            if let u = port.unsupported {
                Notice(icon: "exclamationmark.triangle", color: theme.warning,
                       text: "This pin is left unconnected in the testbench: \(u).")
            } else if port.dir == .output {
                outputBody
                WiringList(doc: doc, from: ref)
            } else if port.dir == .input {
                DriverSection(doc: doc, input: ref, driver: driver)
            } else {
                Notice(icon: "info.circle", color: theme.dimFG,
                       text: "inout pins are connected to a testbench wire that nothing drives, and are recorded in the waveform.")
            }
            }
        }
    }

    private var outputBody: some View {
        let id = inst.id, name = port.name
        let logged = Binding(
            get: { doc.state.instance(id)?.logged.contains(name) ?? false },
            set: { on in
                doc.edit { st in
                    guard let i = st.instances.firstIndex(where: { $0.id == id }) else { return }
                    st.instances[i].logged.removeAll { $0 == name }
                    if on { st.instances[i].logged.append(name) }
                }
            })
        return VStack(alignment: .leading, spacing: 12) {
            InspectorHeading(text: "OUTPUT")
            Text("Every output is recorded in the waveform file (VCD), so you can inspect it in HDL Viewer after a run.")
                .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                .fixedSize(horizontal: false, vertical: true)
            VSCheckbox(title: "Print each value change in the Output panel", isOn: logged)
        }
    }

    @ViewBuilder private func stimulusBody(width: Int?) -> some View {
        let s = stim.wrappedValue
        InspectorHeading(text: "STIMULUS")
        KindPicker(selection: s.kind) { setKind($0) }
        Text(s.kind.help)
            .font(.system(size: 12))
            .foregroundStyle(theme.dimFG)
            .fixedSize(horizontal: false, vertical: true)

        Group {
            switch s.kind {
            case .constant: ConstantEditor(stim: stim, width: width)
            case .clock: ClockEditor(stim: stim, unit: doc.state.unit)
            case .sequence: SequenceEditor(stim: stim, unit: doc.state.unit, width: width, apply: apply)
            case .bitstream: BitstreamEditor(stim: stim, unit: doc.state.unit, width: width)
            case .counter: CounterEditor(stim: stim, unit: doc.state.unit)
            case .random: RandomEditor(stim: stim, unit: doc.state.unit)
            }
        }
        .padding(.top, 2)

        let problems = model.generated(for: doc).problems.filter { $0.instance == inst.id && $0.pin == port.name }
        ForEach(problems) { p in
            Notice(icon: p.severity == .error ? "xmark.octagon" : "exclamationmark.triangle",
                   color: p.severity == .error ? theme.error : theme.warning,
                   text: p.message.replacingOccurrences(of: "\(inst.name).\(port.name): ", with: ""))
        }

        let horizon = StimulusPreview.suggestedHorizon(s, duration: doc.state.duration)
        HStack {
            InspectorHeading(text: "PREVIEW")
            Spacer()
            Text("first \(Fmt.num(horizon)) \(doc.state.unit.rawValue)")
                .font(.system(size: 11)).foregroundStyle(theme.dimFG).padding(.top, 6)
        }
        VStack(spacing: 2) {
            StimWave(segs: StimulusPreview.segments(s, width: width, horizon: horizon), horizon: horizon,
                     color: theme.stimColor(s.kind))
                .frame(height: (width ?? 1) > 1 ? 30 : 36)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.editor))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.border))
            TimeRuler(horizon: horizon, unit: doc.state.unit)
                .frame(height: 16)
                .padding(.horizontal, 6)
        }
        if s.kind == .random {
            Text("Preview values are illustrative; the simulator's $random gives different numbers.")
                .font(.system(size: 11)).foregroundStyle(theme.dimFG)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            VSButton(title: "Copy", icon: "doc.on.doc", secondary: true) { model.stimulusClipboard = s }
            VSButton(title: "Paste", icon: "doc.on.clipboard", secondary: true) {
                if let c = model.stimulusClipboard { apply(c) }
            }
            .disabled(model.stimulusClipboard == nil)
            .opacity(model.stimulusClipboard == nil ? 0.5 : 1)
            presetMenu(width: width)
        }
        .padding(.top, 4)

    }

    private func presetMenu(width: Int?) -> some View {
        Menu {
            let p = doc.state.typicalClockPeriod
            Section("Clock") {
                ForEach([(10.0, "100 MHz"), (20, "50 MHz"), (8, "125 MHz"), (40, "25 MHz")], id: \.0) { per, label in
                    Button("\(label)  (\(Fmt.num(per)) \(doc.state.unit.rawValue))") { apply(.clock(period: per)) }
                }
            }
            Section("Reset") {
                Button("Active-high reset for 2 cycles") { apply(.reset(activeLow: false, length: p * 2)) }
                Button("Active-low reset for 2 cycles") { apply(.reset(activeLow: true, length: p * 2)) }
            }
            Section("Pulse") {
                Button("One-cycle pulse after 5 cycles") {
                    var s = Stimulus()
                    s.kind = .sequence
                    s.seqInitial = "0"
                    s.steps = [SeqStep(delay: p * 5, value: "1"), SeqStep(delay: p, value: "0")]
                    apply(s)
                }
            }
            Section("Constant") {
                Button("0") { apply(.constant("0")) }
                Button("1") { apply(.constant("1")) }
                if let w = width, w > 1 {
                    Button("All ones") { apply(.constant("\(w)'h" + String(repeating: "f", count: (w + 3) / 4))) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars").font(.system(size: 12))
                Text("Presets").font(UI.uiFont)
            }
            .foregroundStyle(theme.secondaryButtonFG)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 3).fill(theme.secondaryButtonBG))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

struct Notice: View {
    let icon: String
    let color: Color
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
            Text(text).font(.system(size: 12)).foregroundStyle(theme.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.4)))
    }
}

struct KindPicker: View {
    let selection: StimKind
    let onPick: (StimKind) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(StimKind.allCases) { k in
                let on = k == selection
                Button { onPick(k) } label: {
                    VStack(spacing: 5) {
                        StimIcon(kind: k, size: 15, color: on ? theme.stimColor(k) : theme.dimFG)
                            .frame(height: 16)
                        Text(k.title)
                            .font(.system(size: 11))
                            .foregroundStyle(on ? theme.fg : theme.dimFG)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 4).fill(on ? theme.stimColor(k).opacity(0.14) : theme.inputBG.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? theme.stimColor(k) : theme.inputBorder, lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(k.help)
            }
        }
    }
}

// MARK: - Stimulus editors

struct ConstantEditor: View {
    @Binding var stim: Stimulus
    let width: Int?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PropRow(label: "Value") { ValueField(text: $stim.constant) }
            HStack(spacing: 6) {
                Spacer().frame(width: 92)
                ForEach(["0", "1", "x", "z"], id: \.self) { v in
                    Button { stim.constant = v } label: {
                        Text(v).font(UI.monoSmall).foregroundStyle(theme.fg)
                            .frame(width: 26, height: 20)
                            .background(RoundedRectangle(cornerRadius: 3).fill(theme.secondaryButtonBG))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let w = width, w > 1, let bits = LogicLiteral.parse(stim.constant)?.bits(width: w), let v = BitsFormat.uint(bits) {
                Text("= \(v) · 0x\(BitsFormat.hex(bits))")
                    .font(UI.monoSmall).foregroundStyle(theme.dimFG)
                    .padding(.leading, 100)
            }
        }
    }
}

struct ClockEditor: View {
    @Binding var stim: Stimulus
    let unit: TimeUnit
    @Environment(\.theme) private var theme

    var body: some View {
        let u = unit.rawValue
        let high = stim.period * min(max(stim.duty, 0), 100) / 100
        let firstRise = stim.clockDelay + (stim.startHigh ? stim.period : stim.period - high)
        VStack(alignment: .leading, spacing: 8) {
            PropRow(label: "Period") {
                HStack {
                    NumField(value: $stim.period, unit: u, minValue: 0, width: 110)
                    Text(Fmt.frequency(period: stim.period, unit: unit)).font(.system(size: 12)).foregroundStyle(theme.dimFG)
                }
            }
            PropRow(label: "Duty cycle") { NumField(value: $stim.duty, unit: "%", minValue: 0, width: 110) }
            PropRow(label: "Starts") {
                Segmented(selection: $stim.startHigh, options: [(false, "Low"), (true, "High")]).frame(width: 140)
            }
            PropRow(label: "Start delay") { NumField(value: $stim.clockDelay, unit: u, minValue: 0, width: 110) }
            Text("First rising edge at \(Fmt.num(firstRise)) \(u)")
                .font(.system(size: 11)).foregroundStyle(theme.dimFG)
                .padding(.leading, 100)
        }
    }
}

struct SequenceEditor: View {
    @Binding var stim: Stimulus
    let unit: TimeUnit
    let width: Int?
    let apply: (Stimulus) -> Void
    @Environment(\.theme) private var theme
    @ViewState private var showText = false
    @ViewState private var text = ""

    var body: some View {
        let u = unit.rawValue
        VStack(alignment: .leading, spacing: 8) {
            PropRow(label: "Initial value") { ValueField(text: $stim.seqInitial) }
            PropRow(label: "Times are") {
                Segmented(selection: $stim.absoluteTimes, options: [(false, "Delays"), (true, "Absolute")]).frame(width: 160)
            }
            HStack(spacing: 6) {
                Text("#").frame(width: 18, alignment: .trailing)
                Text(stim.absoluteTimes ? "At time (\(u))" : "After (\(u))").frame(width: 104, alignment: .leading)
                Text("Set to").frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 20)
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.dimFG)
            .padding(.top, 4)
            ForEach(Array(stim.steps.enumerated()), id: \.element.id) { i, step in
                HStack(spacing: 6) {
                    Text("\(i + 1)").font(UI.monoSmall).foregroundStyle(theme.dimFG).frame(width: 18, alignment: .trailing)
                    NumField(value: stepBinding(step.id).delay, minValue: 0, width: 104)
                    ValueField(text: stepBinding(step.id).value)
                    Button {
                        var s = stim
                        s.steps.removeAll { $0.id == step.id }
                        apply(s)
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(theme.dimFG)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Remove step")
                }
            }
            HStack(spacing: 8) {
                VSButton(title: "Add Step", icon: "plus", secondary: true) {
                    var s = stim
                    let last = s.steps.last
                    let lastValue = last?.value ?? s.seqInitial
                    var next = "1"
                    if (width ?? 1) == 1 { next = lastValue == "1" ? "0" : "1" } else if let v = LogicLiteral.parse(lastValue)?.intValue { next = String(v + 1) }
                    let d = s.absoluteTimes ? (last?.delay ?? 0) + 10 : (last?.delay ?? 10)
                    s.steps.append(SeqStep(delay: d, value: next))
                    apply(s)
                }
                VSButton(title: "Edit as Text", icon: "text.alignleft", secondary: true) {
                    text = stim.steps.map { "\(Fmt.num($0.delay)) \($0.value)" }.joined(separator: "\n")
                    showText = true
                }
            }
            VSCheckbox(title: "Repeat the steps forever", isOn: $stim.seqRepeat)
            let total = stim.absoluteTimes ? (stim.steps.map(\.delay).max() ?? 0) : stim.steps.reduce(0) { $0 + $1.delay }
            Text("Last change at \(Fmt.num(total)) \(u)" + (stim.seqRepeat ? ", then starts over" : ""))
                .font(.system(size: 11)).foregroundStyle(theme.dimFG)
        }
        .sheet(isPresented: $showText) {
            SequenceTextSheet(text: $text, absolute: stim.absoluteTimes, unit: u) { lines in
                var s = stim
                s.steps = lines
                apply(s)
            }
        }
    }

    private func stepBinding(_ id: UUID) -> (delay: Binding<Double>, value: Binding<String>) {
        let delay = Binding<Double>(
            get: { stim.steps.first { $0.id == id }?.delay ?? 0 },
            set: { v in if let i = stim.steps.firstIndex(where: { $0.id == id }) { stim.steps[i].delay = v } })
        let value = Binding<String>(
            get: { stim.steps.first { $0.id == id }?.value ?? "" },
            set: { v in if let i = stim.steps.firstIndex(where: { $0.id == id }) { stim.steps[i].value = v } })
        return (delay, value)
    }
}

struct SequenceTextSheet: View {
    @Binding var text: String
    let absolute: Bool
    let unit: String
    let onApply: ([SeqStep]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var parsed: ([SeqStep], [Int]) {
        var steps: [SeqStep] = []
        var bad: [Int] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.split(separator: "//").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
            guard parts.count == 2, let d = Double(parts[0].replacingOccurrences(of: "#", with: "")), LogicLiteral.parse(parts[1]) != nil else {
                bad.append(i + 1)
                continue
            }
            steps.append(SeqStep(delay: d, value: parts[1]))
        }
        return (steps, bad)
    }

    var body: some View {
        let (steps, bad) = parsed
        VStack(alignment: .leading, spacing: 10) {
            Text("Sequence steps").font(.system(size: 15, weight: .semibold))
            Text("One step per line: \(absolute ? "time" : "delay") in \(unit), then the value.  Example:  20 8'hA5")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.inputBG))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(bad.isEmpty ? theme.inputBorder : theme.error))
            HStack {
                if !bad.isEmpty {
                    Text("Can't read line\(bad.count == 1 ? "" : "s") \(bad.map(String.init).joined(separator: ", "))")
                        .font(.system(size: 12)).foregroundStyle(theme.error)
                } else {
                    Text("\(steps.count) step\(steps.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(steps)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!bad.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

struct BitstreamEditor: View {
    @Binding var stim: Stimulus
    let unit: TimeUnit
    let width: Int?
    @Environment(\.theme) private var theme

    var body: some View {
        let u = unit.rawValue
        let toks = stim.streamTokens(width: width)
        let bad = toks.contains { LogicLiteral.parse($0) == nil }
        VStack(alignment: .leading, spacing: 8) {
            PropRow(label: (width ?? 1) == 1 ? "Bits" : "Values") {
                VSTextField(text: $stim.bits, placeholder: (width ?? 1) == 1 ? "10110010" : "A5 3C FF 00", mono: true, invalid: bad)
            }
            Text((width ?? 1) == 1 ? "Sent left to right, one bit per bit time." : "Separate values with spaces, e.g.  8'hA5 8'h3C 255")
                .font(.system(size: 11)).foregroundStyle(theme.dimFG)
                .padding(.leading, 100)
                .fixedSize(horizontal: false, vertical: true)
            PropRow(label: "Bit time") { NumField(value: $stim.bitTime, unit: u, minValue: 0, width: 110) }
            PropRow(label: "Start delay") { NumField(value: $stim.bitDelay, unit: u, minValue: 0, width: 110) }
            PropRow(label: "Idle value") { ValueField(text: $stim.bitIdle).frame(width: 110) }
            VSCheckbox(title: "Repeat the stream forever", isOn: $stim.bitRepeat)
            Text("\(toks.count) value\(toks.count == 1 ? "" : "s") · \(Fmt.num(Double(toks.count) * stim.bitTime)) \(u) per pass")
                .font(.system(size: 11)).foregroundStyle(theme.dimFG)
        }
    }
}

struct CounterEditor: View {
    @Binding var stim: Stimulus
    let unit: TimeUnit

    var body: some View {
        let u = unit.rawValue
        VStack(alignment: .leading, spacing: 8) {
            PropRow(label: "Start value") { ValueField(text: $stim.countStart) }
            PropRow(label: "Step") { ValueField(text: $stim.countStep, placeholder: "1") }
            PropRow(label: "Every") { NumField(value: $stim.countInterval, unit: u, minValue: 0, width: 110) }
            PropRow(label: "Start delay") { NumField(value: $stim.countDelay, unit: u, minValue: 0, width: 110) }
        }
    }
}

struct RandomEditor: View {
    @Binding var stim: Stimulus
    let unit: TimeUnit

    var body: some View {
        let u = unit.rawValue
        let seed = Binding<Double>(get: { Double(stim.randSeed) }, set: { stim.randSeed = Int($0) })
        VStack(alignment: .leading, spacing: 8) {
            PropRow(label: "Every") { NumField(value: $stim.randInterval, unit: u, minValue: 0, width: 110) }
            PropRow(label: "Seed") { NumField(value: seed, width: 110) }
            PropRow(label: "Start delay") { NumField(value: $stim.randDelay, unit: u, minValue: 0, width: 110) }
        }
    }
}

// MARK: - DUT instance

struct InstanceInspector: View {
    let doc: TestDocument
    let inst: DUTInstance
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var name = ""

    var body: some View {
        let env = inst.paramValues()
        let nameTaken = doc.state.instances.contains { $0.id != inst.id && $0.name == name }
        let nameBad = !Fmt.isIdentifier(name) || nameTaken
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: "cpu").foregroundStyle(theme.dirColor(.output))
                    Text(inst.moduleName).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(theme.fg)
                }
                Button((inst.filePath as NSString).abbreviatingWithTildeInPath) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: inst.filePath)])
                }
                .buttonStyle(LinkButtonStyle(color: theme.accent))
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.head)
                .help("Reveal in Finder")
            }
            PropRow(label: "Instance") {
                VSTextField(text: $name, mono: true, invalid: nameBad)
            }
            if nameBad {
                Text(nameTaken ? "Another DUT already uses this name." : "Use letters, digits and _ (not starting with a digit).")
                    .font(.system(size: 11)).foregroundStyle(theme.error).padding(.leading, 100)
            }

            if !inst.params.isEmpty {
                InspectorHeading(text: "PARAMETERS")
                ForEach(inst.params) { p in
                    PropRow(label: p.name) {
                        if p.isLocal {
                            Text(env[p.name].map(String.init) ?? p.value)
                                .font(UI.mono).foregroundStyle(theme.dimFG)
                                .help("localparam \(p.name) = \(p.value)")
                        } else {
                            let b = Binding<String>(
                                get: { doc.state.instance(inst.id)?.paramOverrides[p.name] ?? "" },
                                set: { v in
                                    if let i = doc.index(of: inst.id) {
                                        doc.state.instances[i].paramOverrides[p.name] = v.isEmpty ? nil : v
                                    }
                                })
                            let bad = !b.wrappedValue.isEmpty && ExprEval(env: env).eval(b.wrappedValue) == nil
                            VSTextField(text: b, placeholder: p.value + (env[p.name].map { ExprEval(env: [:]).eval(p.value) == nil ? "  (= \($0))" : "" } ?? ""),
                                        mono: true, invalid: bad)
                                .help("Leave empty to use the default (\(p.value)).")
                        }
                    }
                }
            }

            InspectorHeading(text: "PINS")
            VStack(spacing: 0) {
                ForEach(inst.ports) { p in
                    PinListRow(doc: doc, inst: inst, port: p, range: inst.rangeLabel(p, env: env))
                }
            }

            let unwired = inst.inputs.filter { $0.unsupported == nil && doc.state.wire(to: PinRef(instance: inst.id, pin: $0.name)) == nil }
            if !unwired.isEmpty {
                VSButton(title: "Add Sources for \(unwired.count) Unwired Input\(unwired.count == 1 ? "" : "s")", icon: "plus") {
                    doc.addSourcesForUnwiredInputs(of: inst.id)
                }
                .help("Clock pins get a clock, reset pins a reset (shared with existing ones), everything else a constant 0")
                .padding(.top, 4)
            }

            HStack(spacing: 8) {
                VSButton(title: "Duplicate", icon: "plus.square.on.square", secondary: true) { doc.duplicateInstance(inst.id) }
                VSButton(title: "Remove", icon: "trash", secondary: true) { doc.removeInstance(inst.id) }
            }
            .padding(.top, 6)
        }
        .onAppear { name = inst.name }
        .onChange(of: inst.name) { _, n in if n != name { name = n } }
        .onChange(of: name) { _, n in
            guard Fmt.isIdentifier(n), !doc.state.instances.contains(where: { $0.id != inst.id && $0.name == n }),
                  let i = doc.index(of: inst.id), doc.state.instances[i].name != n else { return }
            doc.state.instances[i].name = n
        }
    }
}

struct PinListRow: View {
    let doc: TestDocument
    let inst: DUTInstance
    let port: PortInfo
    let range: String
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: port.dir == .output ? "arrow.left" : (port.dir == .input ? "arrow.right" : "arrow.left.arrow.right"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.dirColor(port.dir))
                .frame(width: 12)
            Text(port.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.fg)
            Text(range).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.dimFG)
            Spacer(minLength: 4)
            if port.unsupported != nil {
                Text("not connected").font(.system(size: 11)).foregroundStyle(theme.warning)
            } else if let d = doc.state.wire(to: PinRef(instance: inst.id, pin: port.name))?.from {
                Text("← " + doc.state.describe(d)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.dimFG).lineLimit(1)
            } else if port.dir == .input {
                Text("not wired").font(.system(size: 11)).foregroundStyle(theme.warning)
            } else if inst.logged.contains(port.name) {
                Image(systemName: "text.alignleft").font(.system(size: 10)).foregroundStyle(theme.dimFG)
            }
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(theme.dimFG.opacity(hovering ? 1 : 0))
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 3).fill(hovering ? theme.listHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { doc.selection = .pin(inst.id, port.name) }
    }
}

// MARK: - Test settings

struct TestSettingsView: View {
    let doc: TestDocument
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var doc = doc
        let s = doc.state
        let outDir = Runner.outputDir(for: doc)
        VStack(alignment: .leading, spacing: 12) {
            PropRow(label: "Name") { VSTextField(text: $doc.state.name) }
            PropRow(label: "Duration") {
                NumField(value: $doc.state.duration, unit: s.unit.rawValue, minValue: 0, width: 130)
            }
            PropRow(label: "Time unit") {
                Picker("", selection: $doc.state.unit) {
                    ForEach(TimeUnit.allCases) { Text("1 \($0.rawValue)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            PropRow(label: "Precision") {
                Picker("", selection: $doc.state.precision) {
                    ForEach(TimeUnit.allCases) { Text("1 \($0.rawValue)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            Text("`timescale 1\(s.unit.rawValue)/1\(s.precision.rawValue) — every delay in this test is in \(s.unit.rawValue).")
                .font(.system(size: 11)).foregroundStyle(theme.dimFG)
                .fixedSize(horizontal: false, vertical: true)

            InspectorHeading(text: "OUTPUT")
            VStack(alignment: .leading, spacing: 6) {
                Text((outDir.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.fg)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(s.outputDir == nil ? "Default folder. Testbench, compiled sim and VCD go here." : "Custom folder.")
                    .font(.system(size: 11)).foregroundStyle(theme.dimFG)
                HStack(spacing: 6) {
                    VSButton(title: "Choose…", secondary: true) { chooseFolder() }
                    VSButton(title: "Reveal", secondary: true) {
                        if FileManager.default.fileExists(atPath: outDir.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([outDir])
                        } else {
                            NSSound.beep()
                        }
                    }
                    if s.outputDir != nil {
                        VSButton(title: "Default", secondary: true) { doc.edit { $0.outputDir = nil } }
                    }
                }
            }
            VSCheckbox(title: "Open the waveform in HDL Viewer after each run", isOn: $doc.state.autoOpenVCD)
            if Runner.viewerURL == nil {
                Text("HDL Viewer isn't installed, so the VCD opens in its default app.")
                    .font(.system(size: 11)).foregroundStyle(theme.dimFG).padding(.leading, 24)
            }

            InspectorHeading(text: "SUMMARY")
            let outs = s.duts.reduce(0) { $0 + $1.outputs.count }
            Text("\(s.duts.count) DUT\(s.duts.count == 1 ? "" : "s") · \(s.sources.count) source\(s.sources.count == 1 ? "" : "s") · \(s.wires.count) wire\(s.wires.count == 1 ? "" : "s") · \(outs) output\(outs == 1 ? "" : "s")")
                .font(.system(size: 12)).foregroundStyle(theme.fg)
            if let v = doc.lastVCD {
                Button("Open last waveform (\(v.lastPathComponent))") { Runner.openInViewer(v) }
                    .buttonStyle(LinkButtonStyle(color: theme.accent))
            }
            VSButton(title: doc.status.isRunning ? "Running…" : "Run Test", icon: "play.fill") { model.runActive() }
                .disabled(doc.status.isRunning || s.duts.isEmpty)
                .opacity(s.duts.isEmpty ? 0.5 : 1)
                .padding(.top, 4)
            Text("Select a DUT or a pin on the canvas to edit it.")
                .font(.system(size: 11)).foregroundStyle(theme.dimFG)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where the testbench, simulation and waveform are written"
        if panel.runModal() == .OK, let u = panel.url {
            doc.edit { $0.outputDir = u.path }
        }
    }
}

// MARK: - Wiring

/// "Driven by": the source or DUT output wired to an input.
struct DriverSection: View {
    let doc: TestDocument
    let input: PinRef
    let driver: PinRef?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorHeading(text: "DRIVEN BY")
            Menu {
                if driver != nil {
                    Button("Not wired") { doc.disconnect(input: input) }
                }
                let sources = doc.state.sources.map { PinRef(instance: $0.id, pin: "out") }
                if !sources.isEmpty {
                    Section("Sources") {
                        ForEach(sources, id: \.self) { d in Button(doc.state.describe(d)) { doc.connect(from: d, to: input) } }
                    }
                }
                let outs = doc.state.driverPins.filter { doc.state.instance($0.instance)?.isSource == false }
                if !outs.isEmpty {
                    Section("DUT outputs") {
                        ForEach(outs, id: \.self) { d in Button(doc.state.describe(d)) { doc.connect(from: d, to: input) } }
                    }
                }
                Section("New source") {
                    ForEach(SourcePreset.allCases) { p in Button(p.title) { newSource(p) } }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: driver == nil ? "exclamationmark.triangle" : "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 11))
                        .foregroundStyle(driver == nil ? theme.warning : theme.dimFG)
                    Text(driver.map { "Wire from \(doc.state.describe($0))" } ?? "Not wired")
                        .font(.system(size: 12, design: driver == nil ? .default : .monospaced))
                        .foregroundStyle(theme.fg)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(theme.dimFG)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 2).fill(theme.inputBG))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.inputBorder))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            if driver == nil {
                Text("Inputs are driven only by wires. Drag from the pin's dot to a source or a DUT output, pick one above, or add a new source:")
                    .font(.system(size: 11)).foregroundStyle(theme.dimFG)
                    .fixedSize(horizontal: false, vertical: true)
                let guess = guessedPreset
                HStack(spacing: 8) {
                    VSButton(title: "New \(guess.shortTitle)", icon: "plus", secondary: true) { newSource(guess) }
                    if guess != .constant {
                        VSButton(title: "New Constant", icon: "plus", secondary: true) { newSource(.constant) }
                    }
                }
                if let match = doc.state.matchingSource(for: guess, width: inputWidth) {
                    VSButton(title: "Wire to \(match.name)", icon: "link", secondary: true) {
                        doc.connect(from: PinRef(instance: match.id, pin: "out"), to: input)
                    }
                }
            }
            if let d = driver {
                HStack(spacing: 8) {
                    VSButton(title: "Go to Driver", icon: "arrow.uturn.left", secondary: true) {
                        doc.selection = doc.state.instance(d.instance)?.isSource == true ? .instance(d.instance) : .pin(d.instance, d.pin)
                    }
                    VSButton(title: "Disconnect", icon: "scissors", secondary: true) { doc.disconnect(input: input) }
                }
                if let src = doc.state.instance(d.instance), src.isSource {
                    Text("Edit the signal by selecting the \(src.name) source block.")
                        .font(.system(size: 11)).foregroundStyle(theme.dimFG)
                }
                let same = doc.state.inputPins.filter { $0.pin == input.pin && $0 != input && doc.state.wire(to: $0)?.from != d }
                if !same.isEmpty {
                    VSButton(title: "Wire every “\(input.pin)” pin to \(doc.state.describe(d)) (\(same.count) more)", icon: "square.on.square", secondary: true) {
                        doc.edit { st in
                            st.wires.removeAll { w in same.contains(w.to) }
                            st.wires += same.map { Wire(from: d, to: $0) }
                        }
                    }
                }
            }
        }
    }
}

extension DriverSection {
    private var port: PortInfo? { doc.state.instance(input.instance)?.ports.first { $0.name == input.pin } }
    var guessedPreset: SourcePreset { port.map(SourcePreset.guess(for:)) ?? .constant }
    var inputWidth: Int { port.flatMap { doc.state.instance(input.instance)?.resolve($0)?.width } ?? 1 }

    func newSource(_ p: SourcePreset) {
        if let id = doc.addSource(p, wiredTo: input) { doc.selection = .instance(id) }
    }
}

/// The wires leaving an output, with a menu to add more.
struct WiringList: View {
    let doc: TestDocument
    let from: PinRef
    @Environment(\.theme) private var theme

    var body: some View {
        let wires = doc.state.wires(from: from)
        VStack(alignment: .leading, spacing: 6) {
            InspectorHeading(text: "WIRED TO")
            if wires.isEmpty {
                Text("Not wired. Drag from the pin's dot to an input, or pick one below.")
                    .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(wires) { w in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.dirColor(.input))
                    Button(doc.state.describe(w.to)) { doc.selection = .pin(w.to.instance, w.to.pin) }
                        .buttonStyle(LinkButtonStyle(color: theme.fg))
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button { doc.removeWire(w.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.dimFG)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this wire")
                }
                .frame(height: 22)
            }
            let free = doc.state.inputPins.filter { doc.state.wire(to: $0)?.from != from }
            if !free.isEmpty {
                Menu {
                    ForEach(free, id: \.self) { t in
                        Button(doc.state.describe(t) + (doc.state.wire(to: t) != nil ? "  (replaces its wire)" : "")) {
                            doc.connect(from: from, to: t)
                            doc.selection = doc.state.instance(from.instance)?.isSource == true ? .instance(from.instance) : .pin(from.instance, from.pin)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11))
                        Text("Wire to an Input").font(UI.uiFont)
                    }
                    .foregroundStyle(theme.secondaryButtonFG)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 3).fill(theme.secondaryButtonBG))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
    }
}

struct WireInspector: View {
    let doc: TestDocument
    let wire: Wire
    @Environment(\.theme) private var theme

    var body: some View {
        let st = doc.state
        let probs = AppModel.shared.generated(for: doc).problems.filter { $0.wire == wire.id }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                endpoint("From", wire.from, isSource: st.instance(wire.from.instance)?.isSource == true)
                endpoint("To", wire.to, isSource: false)
            }
            ForEach(probs) { p in
                Notice(icon: "exclamationmark.triangle", color: p.severity == .error ? theme.error : theme.warning, text: p.message)
            }
            Text("In the testbench, the input uses the same signal as the output it is wired from.")
                .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                .fixedSize(horizontal: false, vertical: true)
            VSButton(title: "Delete Wire", icon: "trash", secondary: true) { doc.removeWire(wire.id) }
            Text("Tip: select a wire and press ⌫ to delete it.")
                .font(.system(size: 11)).foregroundStyle(theme.dimFG)
        }
    }

    private func endpoint(_ label: String, _ ref: PinRef, isSource: Bool) -> some View {
        let w: Int? = doc.state.instance(ref.instance).flatMap { i in i.ports.first { $0.name == ref.pin }.flatMap { i.resolve($0)?.width } }
        return PropRow(label: label, labelWidth: 44) {
            HStack(spacing: 6) {
                Button(doc.state.describe(ref)) {
                    doc.selection = isSource ? .instance(ref.instance) : .pin(ref.instance, ref.pin)
                }
                .buttonStyle(LinkButtonStyle(color: theme.accent))
                .font(.system(size: 13, design: .monospaced))
                if let w { Text("\(w) bit\(w == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(theme.dimFG) }
            }
        }
    }
}

struct SourceInspector: View {
    let doc: TestDocument
    let inst: DUTInstance
    @Environment(\.theme) private var theme
    @ViewState private var name = ""

    var body: some View {
        let nameTaken = doc.state.instances.contains { $0.id != inst.id && $0.name == name }
        let nameBad = !Fmt.isIdentifier(name) || nameTaken
        let width = Binding<Double>(
            get: { Double(doc.state.instance(inst.id)?.sourceWidth ?? 1) },
            set: { v in if let i = doc.index(of: inst.id) { doc.state.instances[i].setSourceWidth(Int(v.rounded())) } })
        VStack(alignment: .leading, spacing: 12) {
            Text("A source drives every input it is wired to with the same signal.")
                .font(.system(size: 12)).foregroundStyle(theme.dimFG)
                .fixedSize(horizontal: false, vertical: true)
            PropRow(label: "Name") { VSTextField(text: $name, mono: true, invalid: nameBad) }
            if nameBad {
                Text(nameTaken ? "Another block already uses this name." : "Use letters, digits and _ (not starting with a digit).")
                    .font(.system(size: 11)).foregroundStyle(theme.error).padding(.leading, 100)
            }
            PropRow(label: "Width") { NumField(value: width, unit: "bits", minValue: 1, width: 110) }
            WiringList(doc: doc, from: PinRef(instance: inst.id, pin: "out"))
            if let out = inst.ports.first {
                PinInspector(doc: doc, inst: inst, port: out, embedded: true)
            }
            HStack(spacing: 8) {
                VSButton(title: "Duplicate", icon: "plus.square.on.square", secondary: true) { doc.duplicateInstance(inst.id) }
                VSButton(title: "Delete", icon: "trash", secondary: true) { doc.removeInstance(inst.id) }
            }
            .padding(.top, 6)
        }
        .onAppear { name = inst.name }
        .onChange(of: inst.name) { _, n in if n != name { name = n } }
        .onChange(of: name) { _, n in
            guard Fmt.isIdentifier(n), !doc.state.instances.contains(where: { $0.id != inst.id && $0.name == n }),
                  let i = doc.index(of: inst.id), doc.state.instances[i].name != n else { return }
            doc.state.instances[i].name = n
        }
    }
}
