import Foundation

struct Problem: Identifiable, Equatable {
    enum Severity { case error, warning }
    let id = UUID()
    var severity: Severity
    var message: String
    var instance: UUID? = nil
    var pin: String? = nil
    var wire: UUID? = nil

    static func == (a: Problem, b: Problem) -> Bool {
        a.severity == b.severity && a.message == b.message && a.instance == b.instance && a.pin == b.pin && a.wire == b.wire
    }
}

/// Builds a self-checking-free stimulus testbench for every DUT placed in a test.
struct TBGenerator {
    let state: TestState
    /// Modules known to the library, for finding source files of sub-modules.
    let library: [ModuleInfo]

    struct Output {
        var topName: String
        var source: String
        var problems: [Problem]
        var sourceFiles: [URL]
        var vcdName: String
    }

    var topName: String { "tb_" + Fmt.identifier(state.name) }
    var vcdName: String { Fmt.identifier(state.name) + ".vcd" }

    func generate(date: Date = Date()) -> Output {
        var problems: [Problem] = []
        var L: [String] = []
        let top = topName
        let u = state.unit
        let duts = state.duts
        let sources = state.sources

        if duts.isEmpty {
            problems.append(Problem(severity: .error, message: "The test has no DUTs. Drag a module from Available DUTs onto the canvas."))
        }
        if state.duration <= 0 {
            problems.append(Problem(severity: .error, message: "Test duration must be greater than 0."))
        }
        if state.precision.exponent > state.unit.exponent {
            problems.append(Problem(severity: .error, message: "Time precision (\(state.precision.rawValue)) must not be coarser than the time unit (\(state.unit.rawValue))."))
        }
        var seenNames: Set<String> = []
        for inst in state.instances {
            if !Fmt.isIdentifier(inst.name) {
                problems.append(Problem(severity: .error, message: "“\(inst.name)” is not a valid name.", instance: inst.id))
            }
            if !seenNames.insert(inst.name).inserted {
                problems.append(Problem(severity: .error, message: "Two blocks are named \(inst.name).", instance: inst.id))
            }
        }

        // ---- Widths of every pin
        var envs: [UUID: [String: Int]] = [:]
        var widths: [PinRef: ResolvedWidth] = [:]
        for inst in state.instances {
            let env = inst.paramValues()
            envs[inst.id] = env
            for p in inst.ports {
                if let r = inst.resolve(p, env: env) { widths[PinRef(instance: inst.id, pin: p.name)] = r }
            }
        }

        // ---- Net names: sources first so they keep their own names
        var usedNets: Set<String> = [top]
        func unique(_ base: String) -> String {
            var n = base
            var k = 2
            while usedNets.contains(n) || VerilogParser.keywords.contains(n) { n = "\(base)_\(k)"; k += 1 }
            usedNets.insert(n)
            return n
        }
        var nets: [PinRef: String] = [:]
        for s in sources { nets[PinRef(instance: s.id, pin: "out")] = unique(s.name) }
        for inst in duts { usedNets.insert(inst.name) }

        // ---- Wires: which inputs take their value from another net
        var driverOf: [PinRef: PinRef] = [:]
        for w in state.wires {
            guard let fromInst = state.instance(w.from.instance), let toInst = state.instance(w.to.instance),
                  let fromPort = fromInst.ports.first(where: { $0.name == w.from.pin }),
                  let toPort = toInst.ports.first(where: { $0.name == w.to.pin }) else {
                problems.append(Problem(severity: .warning, message: "A wire points to a pin that no longer exists and is ignored.", wire: w.id))
                continue
            }
            let label = "\(state.describe(w.from)) → \(state.describe(w.to))"
            guard fromPort.dir == .output, toPort.dir == .input, !toInst.isSource else {
                problems.append(Problem(severity: .warning, message: "Wire \(label) must go from an output to an input; it is ignored.", wire: w.id))
                continue
            }
            if let why = fromPort.unsupported ?? toPort.unsupported {
                problems.append(Problem(severity: .warning, message: "Wire \(label) is ignored: \(why).", wire: w.id))
                continue
            }
            if driverOf[w.to] != nil {
                problems.append(Problem(severity: .error, message: "\(state.describe(w.to)) has more than one wire driving it.", instance: w.to.instance, pin: w.to.pin, wire: w.id))
                continue
            }
            driverOf[w.to] = w.from
            if let a = widths[w.from]?.width, let b = widths[w.to]?.width, a != b {
                problems.append(Problem(severity: .warning,
                    message: "Wire \(label) joins \(a) bit\(a == 1 ? "" : "s") to \(b) bit\(b == 1 ? "" : "s"); " + (a > b ? "the upper bits are dropped." : "the upper bits are 0."),
                    wire: w.id))
            }
        }

        for inst in duts {
            for p in inst.ports where p.unsupported == nil {
                let ref = PinRef(instance: inst.id, pin: p.name)
                if p.dir == .input && driverOf[ref] != nil { continue }
                nets[ref] = unique("\(inst.name)_\(p.name)")
            }
        }
        func net(_ ref: PinRef) -> String? {
            if let d = driverOf[ref] { return nets[d] }
            return nets[ref]
        }

        // ---- Header
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        L.append("// ============================================================================")
        L.append("// \(top).v — generated by HDL Tester on \(df.string(from: date))")
        L.append("// Test: \(state.name)   ·   duration \(Fmt.num(state.duration)) \(u.rawValue)")
        L.append("// DUTs: " + (duts.isEmpty ? "(none)" : duts.map { "\($0.name) (\($0.moduleName))" }.joined(separator: ", ")))
        if !sources.isEmpty { L.append("// Sources: " + sources.map(\.name).joined(separator: ", ")) }
        if !driverOf.isEmpty {
            L.append("// Wires: " + state.wires.filter { driverOf[$0.to] == $0.from }
                .map { "\(state.describe($0.from)) → \(state.describe($0.to))" }.joined(separator: ", "))
        }
        L.append("// This file is regenerated on every run; edit the test in HDL Tester instead.")
        L.append("// ============================================================================")
        L.append("`timescale 1\(u.rawValue)/1\(state.precision.rawValue)")
        L.append("")
        L.append("module \(top);")
        L.append("")

        func rangeText(_ ref: PinRef) -> String {
            guard let r = widths[ref], r.hasRange else { return "" }
            return "[\(r.msb):\(r.lsb)]"
        }

        var stimBlocks: [String] = []
        var logBlocks: [String] = []

        // ---- Source blocks
        if !sources.isEmpty {
            L.append("  // ---------------------------------------------------------------------------")
            L.append("  // Sources (each can drive several DUT inputs)")
            L.append("  // ---------------------------------------------------------------------------")
            let rows = sources.map { s -> (String, String) in
                let ref = PinRef(instance: s.id, pin: "out")
                return (rangeText(ref), nets[ref]!)
            }
            let rw = rows.map(\.0.count).max() ?? 0
            for (r, n) in rows {
                L.append("  reg " + (rw > 0 ? r + String(repeating: " ", count: rw - r.count + 1) : "") + "\(n);")
            }
            L.append("")
            for s in sources {
                let ref = PinRef(instance: s.id, pin: "out")
                let fanout = state.wires(from: ref).filter { driverOf[$0.to] == ref }.count
                if fanout == 0 {
                    problems.append(Problem(severity: .warning, message: "Source \(s.name) is not wired to anything.", instance: s.id, pin: "out"))
                }
                let block = StimulusCode(stim: s.stimulus("out"), target: nets[ref]!, width: widths[ref]?.width, unit: u,
                                         label: s.name, instance: s.id, pin: "out")
                let (code, probs) = block.emit()
                problems += probs
                stimBlocks.append(contentsOf: code)
                stimBlocks.append("")
            }
        }

        // ---- DUTs
        for inst in duts {
            let env = envs[inst.id] ?? [:]
            L.append("  // ---------------------------------------------------------------------------")
            L.append("  // \(inst.name) : \(inst.moduleName)   (\((inst.filePath as NSString).lastPathComponent))")
            L.append("  // ---------------------------------------------------------------------------")

            // Parameter localparams are only needed when a width could not be computed here.
            let needParamDecls = inst.ports.contains { widths[PinRef(instance: inst.id, pin: $0.name)] == nil }
            let prefix = inst.name + "_"
            if needParamDecls {
                for p in inst.params {
                    var text = p.value
                    if !p.isLocal, let o = inst.paramOverrides[p.name], !o.trimmingCharacters(in: .whitespaces).isEmpty { text = o }
                    L.append("  localparam \(prefix)\(p.name) = \(renameParams(text, in: inst, prefix: prefix));")
                }
            }
            _ = env

            var conns: [(String, String, String?)] = []   // port, net, comment
            var declRows: [(String, String, String)] = []   // type, range, name
            for p in inst.ports {
                let ref = PinRef(instance: inst.id, pin: p.name)
                if let why = p.unsupported {
                    problems.append(Problem(severity: .warning, message: "\(inst.name).\(p.name) is left unconnected: \(why).", instance: inst.id, pin: p.name))
                    conns.append((p.name, "", nil))
                    continue
                }
                if p.dir == .input, let d = driverOf[ref] {
                    conns.append((p.name, nets[d] ?? "", "wired from \(state.describe(d))"))
                    continue
                }
                let n = nets[ref]!
                conns.append((p.name, n, nil))
                var range = rangeText(ref)
                if widths[ref] == nil {
                    problems.append(Problem(severity: .warning, message: "Could not compute the width of \(inst.name).\(p.name); the testbench uses the expression instead.", instance: inst.id, pin: p.name))
                    range = p.ranges.map { "[\(renameParams($0.msb, in: inst, prefix: prefix)):\(renameParams($0.lsb, in: inst, prefix: prefix))]" }.joined()
                }
                let signed = p.isSigned || (p.isIntegerType && !p.dataType.contains("unsigned")) ? " signed" : ""
                if p.dir == .input {
                    problems.append(Problem(severity: .warning,
                        message: "\(inst.name).\(p.name) is not wired, so it floats (z). Wire a source or a DUT output to it.",
                        instance: inst.id, pin: p.name))
                    conns[conns.count - 1].2 = "not wired: floats (z)"
                }
                declRows.append(("wire" + signed, range, n))
            }
            let typeW = declRows.map(\.0.count).max() ?? 4
            let rangeW = declRows.map(\.1.count).max() ?? 0
            for (t, r, n) in declRows {
                let pad = String(repeating: " ", count: typeW - t.count + 1)
                let rpad = rangeW > 0 ? r + String(repeating: " ", count: rangeW - r.count + 1) : ""
                L.append("  \(t)\(pad)\(rpad)\(n);")
            }

            // Instantiation
            let overrides = inst.params.filter { !$0.isLocal }.compactMap { p -> (String, String)? in
                guard let o = inst.paramOverrides[p.name]?.trimmingCharacters(in: .whitespaces), !o.isEmpty else { return nil }
                return (p.name, needParamDecls ? prefix + p.name : o)
            }
            L.append("")
            if overrides.isEmpty {
                L.append("  \(inst.moduleName) \(inst.name) (")
            } else {
                L.append("  \(inst.moduleName) #(")
                for (k, (n, v)) in overrides.enumerated() {
                    L.append("    .\(n)(\(v))" + (k < overrides.count - 1 ? "," : ""))
                }
                L.append("  ) \(inst.name) (")
            }
            let nameW = conns.map(\.0.count).max() ?? 0
            let connW = conns.map { $0.1.count + 3 + $0.0.count }.max() ?? 0
            for (k, (p, n, comment)) in conns.enumerated() {
                let pad = String(repeating: " ", count: nameW - p.count)
                var line = "    .\(p)\(pad) (\(n))" + (k < conns.count - 1 ? "," : "")
                if let comment {
                    line += String(repeating: " ", count: max(1, connW + 8 - line.count)) + "// " + comment
                }
                L.append(line)
            }
            L.append("  );")
            L.append("")

            for name in inst.logged {
                let ref = PinRef(instance: inst.id, pin: name)
                guard let p = inst.ports.first(where: { $0.name == name }), let n = net(ref) else { continue }
                let w = widths[ref]?.width ?? 2
                let fmt = w == 1 ? "%b" : "0x%h (%0d)"
                let args = w == 1 ? n : "\(n), \(n)"
                logBlocks.append("  always @(\(n)) $display(\"%t  \(inst.name).\(p.name) = \(fmt)\", $time, \(args));")
            }
        }

        if !stimBlocks.isEmpty {
            L.append("  // ===== Sources ==============================================================")
            L.append("")
            L.append(contentsOf: stimBlocks)
        }
        if !logBlocks.isEmpty {
            L.append("  // ===== Output log ===========================================================")
            L.append(contentsOf: logBlocks)
            L.append("")
        }

        let digits = max(0, u.exponent - state.precision.exponent)
        L.append("  // ===== Waveform dump & end of test ===========================================")
        L.append("  initial begin")
        L.append("    $timeformat(\(u.exponent), \(digits), \" \(u.rawValue)\", 0);")
        L.append("    $dumpfile(\"\(vcdName)\");")
        L.append("    $dumpvars(0, \(top));")
        L.append("    #\(Fmt.num(state.duration));")
        L.append("    $display(\"HDL Tester: simulation finished at %t\", $time);")
        L.append("    $finish;")
        L.append("  end")
        L.append("")
        L.append("endmodule")
        L.append("")

        return Output(topName: top, source: L.joined(separator: "\n"), problems: problems,
                      sourceFiles: sourceFiles(problems: &problems), vcdName: vcdName)
    }

    /// Prefixes parameter names in an expression so they refer to the testbench localparams.
    private func renameParams(_ expr: String, in inst: DUTInstance, prefix: String) -> String {
        let names = Set(inst.params.map(\.name))
        let toks = VerilogLexer.lex(expr)
        guard !toks.isEmpty else { return expr }
        let bytes = Array(expr.utf8)
        var out = ""
        var last = 0
        for t in toks {
            out += String(decoding: bytes[last..<t.start], as: UTF8.self)
            out += (t.kind == .ident && names.contains(t.text)) ? prefix + t.text : t.text
            last = t.end
        }
        out += String(decoding: bytes[last...], as: UTF8.self)
        return out
    }

    /// Verilog files needed by the DUTs, sub-modules included.
    private func sourceFiles(problems: inout [Problem]) -> [URL] {
        var files: [URL] = []
        var seenFiles: Set<String> = []
        var visited: Set<String> = []
        func add(_ url: URL) {
            if seenFiles.insert(url.standardizedFileURL.path).inserted { files.append(url) }
        }
        func lookup(_ name: String, prefer: String?) -> ModuleInfo? {
            let all = library.filter { $0.name == name }
            return all.first { prefer != nil && Library.samePath($0.file.path, prefer!) } ?? all.first
        }
        func visit(_ name: String, prefer: String?) {
            guard visited.insert(name).inserted, let m = lookup(name, prefer: prefer) else { return }
            add(m.file)
            for sub in m.instantiates { visit(sub, prefer: m.file.path) }
        }
        for inst in state.duts {
            if FileManager.default.fileExists(atPath: inst.filePath) {
                add(URL(fileURLWithPath: inst.filePath))
            } else if let m = lookup(inst.moduleName, prefer: nil) {
                add(m.file)
            } else {
                problems.append(Problem(severity: .error, message: "Source file for \(inst.moduleName) not found: \(inst.filePath)", instance: inst.id))
            }
            visit(inst.moduleName, prefer: inst.filePath)
        }
        return files
    }
}

// MARK: - Stimulus code

struct StimulusCode {
    let stim: Stimulus
    let target: String
    let width: Int?
    let unit: TimeUnit
    let label: String
    let instance: UUID
    let pin: String

    private func problem(_ msg: String, _ sev: Problem.Severity = .error) -> Problem {
        Problem(severity: sev, message: "\(label): \(msg)", instance: instance, pin: pin)
    }

    private func lit(_ text: String, _ what: String, _ probs: inout [Problem]) -> String {
        guard let l = LogicLiteral.parse(text) else {
            probs.append(problem("“\(text)” is not a valid \(what) value."))
            return "'bx"
        }
        if let w = width, let size = l.size, size > w {
            probs.append(problem("value \(text) is wider than the pin (\(w) bits) and will be truncated.", .warning))
        }
        return l.verilog(width: width)
    }

    private func d(_ v: Double) -> String { Fmt.num(v) }

    func emit() -> ([String], [Problem]) {
        var p: [Problem] = []
        var c: [String] = []
        let t = target
        let un = unit.rawValue
        switch stim.kind {
        case .constant:
            let v = lit(stim.constant, "constant", &p)
            c.append("  // \(label): constant \(stim.constant)")
            c.append("  initial \(t) = \(v);")

        case .clock:
            guard stim.period > 0 else {
                p.append(problem("clock period must be greater than 0."))
                return (["  initial \(t) = 1'b0;"], p)
            }
            let duty = min(max(stim.duty, 0.0001), 99.9999)
            if stim.duty <= 0 || stim.duty >= 100 { p.append(problem("duty cycle must be between 0 and 100 %.")) }
            if let w = width, w != 1 { p.append(problem("a clock on a \(w)-bit pin drives only bit 0.", .warning)) }
            let high = stim.period * duty / 100
            let low = stim.period - high
            c.append("  // \(label): clock, period \(d(stim.period)) \(un) (\(Fmt.frequency(period: stim.period, unit: unit))), \(d(duty))% duty"
                     + (stim.clockDelay > 0 ? ", starts after \(d(stim.clockDelay)) \(un)" : ""))
            c.append("  initial begin")
            c.append("    \(t) = 1'b\(stim.startHigh ? 1 : 0);")
            if stim.clockDelay > 0 { c.append("    #\(d(stim.clockDelay));") }
            c.append("    forever begin")
            if stim.startHigh {
                c.append("      #\(d(high)) \(t) = 1'b0;")
                c.append("      #\(d(low)) \(t) = 1'b1;")
            } else {
                c.append("      #\(d(low)) \(t) = 1'b1;")
                c.append("      #\(d(high)) \(t) = 1'b0;")
            }
            c.append("    end")
            c.append("  end")

        case .sequence:
            let steps = stim.relativeSteps
            let total = steps.reduce(0) { $0 + $1.delay }
            var loop = stim.seqRepeat
            if loop && total <= 0 {
                p.append(problem("a repeating sequence needs a total delay greater than 0; it will run once."))
                loop = false
            }
            c.append("  // \(label): sequence of \(steps.count) step\(steps.count == 1 ? "" : "s")" + (loop ? ", repeating" : ""))
            c.append("  initial begin")
            c.append("    \(t) = \(lit(stim.seqInitial, "initial", &p));")
            let ind = loop ? "      " : "    "
            if loop { c.append("    forever begin") }
            for s in steps {
                if s.delay < 0 { p.append(problem("step delays cannot be negative.")) }
                let v = lit(s.value, "step", &p)
                c.append(s.delay > 0 ? "\(ind)#\(d(s.delay)) \(t) = \(v);" : "\(ind)\(t) = \(v);")
            }
            if loop { c.append("    end") }
            c.append("  end")

        case .bitstream:
            let toks = stim.streamTokens(width: width)
            if toks.isEmpty { p.append(problem("the bit stream is empty.", .warning)) }
            guard stim.bitTime > 0 else {
                p.append(problem("bit time must be greater than 0."))
                return (["  initial \(t) = \(lit(stim.bitIdle, "idle", &p));"], p)
            }
            let idle = lit(stim.bitIdle, "idle", &p)
            c.append("  // \(label): bit stream of \(toks.count) value\(toks.count == 1 ? "" : "s"), \(d(stim.bitTime)) \(un) each"
                     + (stim.bitRepeat ? ", repeating" : ""))
            c.append("  initial begin")
            c.append("    \(t) = \(idle);")
            if stim.bitDelay > 0 { c.append("    #\(d(stim.bitDelay));") }
            let ind = stim.bitRepeat ? "      " : "    "
            if stim.bitRepeat && !toks.isEmpty { c.append("    forever begin") }
            for tok in toks {
                let v = width == 1 && tok.count == 1 ? "1'b\(tok)" : lit(tok, "bit stream", &p)
                c.append("\(ind)\(t) = \(v); #\(d(stim.bitTime));")
            }
            if stim.bitRepeat && !toks.isEmpty {
                c.append("    end")
            } else {
                c.append("    \(t) = \(idle);")
            }
            c.append("  end")

        case .counter:
            guard stim.countInterval > 0 else {
                p.append(problem("counter interval must be greater than 0."))
                return (["  initial \(t) = \(lit(stim.countStart, "start", &p));"], p)
            }
            let start = lit(stim.countStart, "start", &p)
            let step = lit(stim.countStep, "step", &p)
            c.append("  // \(label): counter from \(stim.countStart), step \(stim.countStep) every \(d(stim.countInterval)) \(un)")
            c.append("  initial begin")
            c.append("    \(t) = \(start);")
            if stim.countDelay > 0 { c.append("    #\(d(stim.countDelay));") }
            c.append("    forever #\(d(stim.countInterval)) \(t) = \(t) + (\(step));")
            c.append("  end")

        case .random:
            guard stim.randInterval > 0 else {
                p.append(problem("random interval must be greater than 0."))
                return (["  initial \(t) = 0;"], p)
            }
            let seed = "\(target)_seed"
            let words = max(1, ((width ?? 32) + 31) / 32)
            let rand = words == 1 ? "$random(\(seed))" : "{" + Array(repeating: "$random(\(seed))", count: words).joined(separator: ", ") + "}"
            c.append("  // \(label): random value every \(d(stim.randInterval)) \(un), seed \(stim.randSeed)")
            c.append("  integer \(seed);")
            c.append("  initial begin")
            c.append("    \(seed) = \(stim.randSeed);")
            c.append("    \(t) = 0;")
            if stim.randDelay > 0 { c.append("    #\(d(stim.randDelay));") }
            c.append("    forever begin")
            c.append("      \(t) = \(rand);")
            c.append("      #\(d(stim.randInterval));")
            c.append("    end")
            c.append("  end")
        }
        return (c, p)
    }
}
