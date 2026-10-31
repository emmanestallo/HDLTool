import Foundation
import Observation

// MARK: - Codable helpers

extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }
}

// MARK: - Stimulus

enum StimKind: String, Codable, CaseIterable, Identifiable {
    case constant, clock, sequence, bitstream, counter, random
    var id: String { rawValue }

    var title: String {
        switch self {
        case .constant: return "Constant"
        case .clock: return "Clock"
        case .sequence: return "Sequence"
        case .bitstream: return "Bit Stream"
        case .counter: return "Counter"
        case .random: return "Random"
        }
    }

    var icon: String {
        switch self {
        case .constant: return "equal"
        case .clock: return "square.wave"   // drawn by hand, see StimIcon
        case .sequence: return "stairs"
        case .bitstream: return "barcode"
        case .counter: return "number"
        case .random: return "dice"
        }
    }

    var help: String {
        switch self {
        case .constant: return "Holds one value for the whole test."
        case .clock: return "A periodic clock with a set period and duty cycle."
        case .sequence: return "A list of values, each applied after a delay."
        case .bitstream: return "Shifts out a string of bits (or values), one every bit time."
        case .counter: return "Starts at a value and adds a step every interval."
        case .random: return "A new random value every interval."
        }
    }
}

struct SeqStep: Codable, Equatable, Identifiable {
    var id = UUID()
    var delay: Double
    var value: String
}

struct Stimulus: Codable, Equatable {
    var kind: StimKind = .constant

    var constant = "0"

    var period: Double = 10
    var duty: Double = 50
    var startHigh = false
    var clockDelay: Double = 0

    var seqInitial = "0"
    var steps: [SeqStep] = []
    var absoluteTimes = false
    var seqRepeat = false

    var bits = "10110010"
    var bitTime: Double = 10
    var bitDelay: Double = 0
    var bitIdle = "0"
    var bitRepeat = false

    var countStart = "0"
    var countStep = "1"
    var countInterval: Double = 10
    var countDelay: Double = 0

    var randInterval: Double = 10
    var randSeed = 1
    var randDelay: Double = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Stimulus()
        kind = c.v(.kind, d.kind)
        constant = c.v(.constant, d.constant)
        period = c.v(.period, d.period)
        duty = c.v(.duty, d.duty)
        startHigh = c.v(.startHigh, d.startHigh)
        clockDelay = c.v(.clockDelay, d.clockDelay)
        seqInitial = c.v(.seqInitial, d.seqInitial)
        steps = c.v(.steps, d.steps)
        absoluteTimes = c.v(.absoluteTimes, d.absoluteTimes)
        seqRepeat = c.v(.seqRepeat, d.seqRepeat)
        bits = c.v(.bits, d.bits)
        bitTime = c.v(.bitTime, d.bitTime)
        bitDelay = c.v(.bitDelay, d.bitDelay)
        bitIdle = c.v(.bitIdle, d.bitIdle)
        bitRepeat = c.v(.bitRepeat, d.bitRepeat)
        countStart = c.v(.countStart, d.countStart)
        countStep = c.v(.countStep, d.countStep)
        countInterval = c.v(.countInterval, d.countInterval)
        countDelay = c.v(.countDelay, d.countDelay)
        randInterval = c.v(.randInterval, d.randInterval)
        randSeed = c.v(.randSeed, d.randSeed)
        randDelay = c.v(.randDelay, d.randDelay)
    }

    static func constant(_ v: String) -> Stimulus {
        var s = Stimulus()
        s.constant = v
        return s
    }

    static func clock(period: Double) -> Stimulus {
        var s = Stimulus()
        s.kind = .clock
        s.period = period
        return s
    }

    /// Asserted from t = 0, released after `length`.
    static func reset(activeLow: Bool, length: Double) -> Stimulus {
        var s = Stimulus()
        s.kind = .sequence
        s.seqInitial = activeLow ? "0" : "1"
        s.steps = [SeqStep(delay: length, value: activeLow ? "1" : "0")]
        s.constant = activeLow ? "1" : "0"
        return s
    }

    /// A sensible starting stimulus from the pin name.
    static func guess(for port: PortInfo, clockPeriod: Double = 10) -> Stimulus {
        let n = port.name.lowercased()
        if port.dir == .bidir { return .constant("z") }
        let oneBit = port.ranges.isEmpty && port.baseWidth == 1
        if oneBit {
            if n == "clk" || n == "clock" || n.hasPrefix("clk_") || n.hasSuffix("_clk") || n.hasSuffix("clk") && n.count <= 6 {
                return .clock(period: clockPeriod)
            }
            let isReset = n.contains("rst") || n.contains("reset")
            if isReset {
                let low = n.hasSuffix("_n") || n.hasSuffix("rstn") || n.hasSuffix("resetn") || n.hasSuffix("_ni")
                    || n.hasPrefix("n") || n.hasSuffix("_b") || n.hasSuffix("_l") || n.hasSuffix("rstb") || n.hasSuffix("resetb")
                return .reset(activeLow: low, length: clockPeriod * 2)
            }
        }
        return .constant("0")
    }

    /// Short text shown on the pin chip.
    var summary: String {
        switch kind {
        case .constant: return constant.isEmpty ? "?" : constant
        case .clock: return Fmt.num(period)
        case .sequence: return steps.count <= 1 ? (steps.isEmpty ? seqInitial : "\(seqInitial)→\(steps[0].value)") : "\(steps.count) steps"
        case .bitstream:
            let t = bits.replacingOccurrences(of: " ", with: "")
            return t.count > 8 ? String(t.prefix(7)) + "…" : t
        case .counter: return "\(countStart)+\(countStep)"
        case .random: return "rand"
        }
    }

    /// True when both describe the same signal (ignores the ids of sequence steps).
    func sameSignal(as o: Stimulus) -> Bool {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        var a = self, b = o
        a.steps = a.steps.map { SeqStep(id: zero, delay: $0.delay, value: $0.value) }
        b.steps = b.steps.map { SeqStep(id: zero, delay: $0.delay, value: $0.value) }
        return a == b
    }

    /// Values listed in a bit stream.
    func streamTokens(width: Int?) -> [String] {
        let t = bits.trimmingCharacters(in: .whitespacesAndNewlines)
        if (width ?? 1) == 1 {
            let compact = t.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "\n", with: "")
            if compact.allSatisfy({ "01xzXZ".contains($0) }) {
                return compact.map { String($0).lowercased() }
            }
        }
        return t.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" || $0 == ";" }).map(String.init)
    }

    /// Steps converted to relative delays.
    var relativeSteps: [SeqStep] {
        guard absoluteTimes else { return steps }
        var t = 0.0
        return steps.sorted { $0.delay < $1.delay }.map { s in
            let d = max(0, s.delay - t)
            t = max(t, s.delay)
            return SeqStep(id: s.id, delay: d, value: s.value)
        }
    }
}

// MARK: - Wires & sources

struct PinRef: Codable, Hashable {
    var instance: UUID
    var pin: String
}

/// Connects an output (of a DUT or a source block) to a DUT input.
struct Wire: Codable, Equatable, Identifiable {
    var id = UUID()
    var from: PinRef
    var to: PinRef
}

enum InstanceKind: String, Codable {
    case dut, source
}

/// Ready-made source blocks: a stimulus with one output that can be wired to many inputs.
enum SourcePreset: String, CaseIterable, Identifiable {
    case clock, resetHigh, resetLow, sequence, bitstream, counter, random, constant
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: return "Clock"
        case .resetHigh: return "Reset (active high)"
        case .resetLow: return "Reset (active low)"
        case .sequence: return "Sequence"
        case .bitstream: return "Bit Stream"
        case .counter: return "Counter"
        case .random: return "Random"
        case .constant: return "Constant"
        }
    }

    /// Short name for tiles and buttons.
    var shortTitle: String {
        switch self {
        case .resetHigh: return "Reset (high)"
        case .resetLow: return "Reset (low)"
        default: return title
        }
    }

    var baseName: String {
        switch self {
        case .clock: return "clk"
        case .resetHigh: return "rst"
        case .resetLow: return "rst_n"
        case .sequence: return "seq"
        case .bitstream: return "stream"
        case .counter: return "count"
        case .random: return "rand"
        case .constant: return "const"
        }
    }

    var width: Int { self == .counter || self == .random ? 8 : 1 }

    var kind: StimKind {
        switch self {
        case .clock: return .clock
        case .resetHigh, .resetLow, .sequence: return .sequence
        case .bitstream: return .bitstream
        case .counter: return .counter
        case .random: return .random
        case .constant: return .constant
        }
    }

    /// The preset that suits an input, from its name (clk, rst_n, …).
    static func guess(for port: PortInfo) -> SourcePreset {
        let g = Stimulus.guess(for: port)
        switch g.kind {
        case .clock: return .clock
        case .sequence: return g.seqInitial == "0" ? .resetLow : .resetHigh
        default: return .constant
        }
    }

    func stimulus(period: Double) -> Stimulus {
        switch self {
        case .clock: return .clock(period: period)
        case .resetHigh: return .reset(activeLow: false, length: period * 2)
        case .resetLow: return .reset(activeLow: true, length: period * 2)
        case .sequence:
            var s = Stimulus()
            s.kind = .sequence
            s.steps = [SeqStep(delay: period * 2, value: "1"), SeqStep(delay: period * 2, value: "0")]
            return s
        case .bitstream:
            var s = Stimulus()
            s.kind = .bitstream
            s.bitTime = period
            return s
        case .counter:
            var s = Stimulus()
            s.kind = .counter
            s.countInterval = period
            return s
        case .random:
            var s = Stimulus()
            s.kind = .random
            s.randInterval = period
            return s
        case .constant: return .constant("0")
        }
    }
}

// MARK: - DUT instance

struct DUTInstance: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var moduleName: String
    var filePath: String
    var x: Double
    var y: Double
    var ports: [PortInfo]
    var params: [ParamInfo]
    var paramOverrides: [String: String] = [:]
    var stimuli: [String: Stimulus] = [:]
    var logged: [String] = []
    var kind: InstanceKind = .dut

    var isSource: Bool { kind == .source }

    static func sourcePort(width: Int) -> PortInfo {
        PortInfo(name: "out", dir: .output, ranges: width > 1 ? [PortRange(msb: "\(width - 1)", lsb: "0")] : [], dataType: "reg")
    }

    /// A source block: one output named `out` driven by `stimulus`.
    init(sourceNamed name: String, width: Int, stimulus: Stimulus, x: Double, y: Double) {
        self.name = name
        moduleName = ""
        filePath = ""
        self.x = x
        self.y = y
        ports = [Self.sourcePort(width: width)]
        params = []
        stimuli = ["out": stimulus]
        kind = .source
    }

    var sourceWidth: Int { resolve(ports.first ?? Self.sourcePort(width: 1))?.width ?? 1 }

    mutating func setSourceWidth(_ w: Int) {
        ports = [Self.sourcePort(width: max(1, min(w, 4096)))]
    }

    /// DUT inputs have no stimulus of their own: they are driven by wires from sources or other DUTs.
    init(module: ModuleInfo, name: String, x: Double, y: Double) {
        self.name = name
        moduleName = module.name
        filePath = module.file.path
        self.x = x
        self.y = y
        ports = module.ports
        params = module.params
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID())
        name = try c.decode(String.self, forKey: .name)
        moduleName = try c.decode(String.self, forKey: .moduleName)
        filePath = c.v(.filePath, "")
        x = c.v(.x, 100)
        y = c.v(.y, 100)
        ports = c.v(.ports, [])
        params = c.v(.params, [])
        paramOverrides = c.v(.paramOverrides, [:])
        stimuli = c.v(.stimuli, [:])
        logged = c.v(.logged, [])
        kind = c.v(.kind, .dut)
    }

    var inputs: [PortInfo] { ports.filter { $0.dir == .input } }
    var outputs: [PortInfo] { ports.filter { $0.dir == .output } }
    var inouts: [PortInfo] { ports.filter { $0.dir == .bidir } }

    func stimulus(_ port: String) -> Stimulus {
        if let s = stimuli[port] { return s }
        if let p = ports.first(where: { $0.name == port }) { return .guess(for: p) }
        return Stimulus()
    }

    /// Parameter values after overrides; nil where an expression could not be evaluated.
    func paramValues() -> [String: Int] {
        var env: [String: Int] = [:]
        for p in params {
            var text = p.value
            if !p.isLocal, let o = paramOverrides[p.name]?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
                text = o
            }
            if let v = ExprEval(env: env).eval(text) { env[p.name] = v }
        }
        return env
    }

    /// Resolved bit range of a port: (msb, lsb, total width).
    func resolve(_ port: PortInfo, env: [String: Int]? = nil) -> ResolvedWidth? {
        let env = env ?? paramValues()
        if port.ranges.isEmpty {
            let w = port.baseWidth
            return ResolvedWidth(msb: w - 1, lsb: 0, width: w, hasRange: w > 1)
        }
        var total = 1
        var first: (Int, Int)?
        let ev = ExprEval(env: env)
        for r in port.ranges {
            guard let m = ev.eval(r.msb), let l = ev.eval(r.lsb) else { return nil }
            if first == nil { first = (m, l) }
            total *= abs(m - l) + 1
        }
        guard total > 0, total <= 1 << 20 else { return nil }
        if port.ranges.count == 1, let (m, l) = first {
            return ResolvedWidth(msb: m, lsb: l, width: total, hasRange: true)
        }
        return ResolvedWidth(msb: total - 1, lsb: 0, width: total, hasRange: true)
    }

    func rangeLabel(_ port: PortInfo, env: [String: Int]) -> String {
        if let r = resolve(port, env: env) {
            return r.hasRange ? "[\(r.msb):\(r.lsb)]" : ""
        }
        return port.ranges.map { "[\($0.msb):\($0.lsb)]" }.joined()
    }
}

struct ResolvedWidth: Equatable {
    var msb: Int
    var lsb: Int
    var width: Int
    var hasRange: Bool
}

// MARK: - Test

struct TestState: Codable, Equatable {
    var name: String
    var instances: [DUTInstance] = []
    var wires: [Wire] = []
    var unit: TimeUnit = .ns
    var precision: TimeUnit = .ps
    var duration: Double = 200
    var outputDir: String? = nil
    var autoOpenVCD = true

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.v(.name, "Test")
        instances = c.v(.instances, [])
        wires = c.v(.wires, [])
        unit = c.v(.unit, .ns)
        precision = c.v(.precision, .ps)
        duration = c.v(.duration, 200)
        outputDir = c.v(.outputDir, nil)
        autoOpenVCD = c.v(.autoOpenVCD, true)
        migratePinStimuli()
    }

    /// Older tests gave each DUT input its own stimulus. Turns those into source blocks wired to the
    /// inputs (pins with the same name and the same stimulus share one source).
    mutating func migratePinStimuli() {
        // DUTs whose ports aren't known yet (tests can omit them) are migrated after their file loads.
        guard instances.contains(where: { !$0.isSource && !$0.stimuli.isEmpty && !$0.ports.isEmpty }) else { return }
        var groups: [(name: String, stim: Stimulus, width: Int, pins: [PinRef])] = []
        for inst in instances where !inst.isSource && !inst.ports.isEmpty {
            let env = inst.paramValues()
            for p in inst.inputs where p.unsupported == nil {
                let ref = PinRef(instance: inst.id, pin: p.name)
                guard wire(to: ref) == nil, let s = inst.stimuli[p.name] else { continue }
                let w = inst.resolve(p, env: env)?.width ?? 1
                if let g = groups.firstIndex(where: { $0.name == p.name && $0.width == w && $0.stim.sameSignal(as: s) }) {
                    groups[g].pins.append(ref)
                } else {
                    groups.append((p.name, s, w, [ref]))
                }
            }
        }
        for i in instances.indices where !instances[i].isSource && !instances[i].ports.isEmpty { instances[i].stimuli = [:] }
        guard !groups.isEmpty else { return }

        // New sources go in a column on the left; DUTs move right to make room.
        let columnX = 20.0, columnRight = 340.0
        if let minX = duts.map(\.x).min(), minX < columnRight {
            for i in instances.indices where !instances[i].isSource { instances[i].x += columnRight - minX }
        }
        if let minY = duts.map(\.y).min(), minY < 60 {
            for i in instances.indices where !instances[i].isSource { instances[i].y += 60 - minY }
        }
        var y = (sources.map { $0.y + 70 }.max() ?? 60)
        for g in groups {
            let src = DUTInstance(sourceNamed: uniqueName(Fmt.isIdentifier(g.name) ? g.name : "src"), width: g.width,
                                  stimulus: g.stim, x: columnX, y: y)
            instances.append(src)
            wires += g.pins.map { Wire(from: PinRef(instance: src.id, pin: "out"), to: $0) }
            y += 70
        }
    }

    func instance(_ id: UUID) -> DUTInstance? { instances.first { $0.id == id } }

    var duts: [DUTInstance] { instances.filter { !$0.isSource } }
    var sources: [DUTInstance] { instances.filter(\.isSource) }

    /// The wire driving an input, if any.
    func wire(to ref: PinRef) -> Wire? { wires.first { $0.to == ref } }
    func wires(from ref: PinRef) -> [Wire] { wires.filter { $0.from == ref } }

    func describe(_ ref: PinRef) -> String {
        guard let inst = instance(ref.instance) else { return "?" }
        return inst.isSource ? inst.name : "\(inst.name).\(ref.pin)"
    }

    /// Outputs that can drive a wire: source blocks first, then DUT outputs.
    var driverPins: [PinRef] {
        sources.map { PinRef(instance: $0.id, pin: "out") }
            + duts.flatMap { d in d.outputs.filter { $0.unsupported == nil }.map { PinRef(instance: d.id, pin: $0.name) } }
    }

    /// DUT inputs that can receive a wire.
    var inputPins: [PinRef] {
        duts.flatMap { d in d.inputs.filter { $0.unsupported == nil }.map { PinRef(instance: d.id, pin: $0.name) } }
    }

    func uniqueName(_ base: String, excluding: UUID? = nil) -> String {
        let taken = Set(instances.filter { $0.id != excluding }.map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    func uniqueInstanceName(for module: String, excluding: UUID? = nil) -> String {
        let taken = Set(instances.filter { $0.id != excluding }.map(\.name))
        let base = "u_" + module
        if !taken.contains(base) { return base }
        var n = 1
        while taken.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    /// The period of the first clock source, for new sources.
    var typicalClockPeriod: Double {
        for i in sources where i.stimulus("out").kind == .clock { return i.stimulus("out").period }
        return 10
    }

    /// An existing source that already makes the signal `preset` would, so a new pin can share it.
    func matchingSource(for preset: SourcePreset, width: Int) -> DUTInstance? {
        guard preset == .clock || preset == .resetLow || preset == .resetHigh else { return nil }
        let want = preset.stimulus(period: typicalClockPeriod)
        return sources.first { s in
            let have = s.stimulus("out")
            guard s.sourceWidth == width, have.kind == want.kind else { return false }
            if preset == .clock { return true }
            return have.seqInitial == want.seqInitial && have.steps.first?.value == want.steps.first?.value
        }
    }
}

/// On-disk format of a `.hdltest` file.
struct TestFile: Codable {
    var format = "hdltester-test"
    var version = 1
    var test: TestState
    /// Verilog files the test's DUTs come from, so opening the test restores them.
    var sources: [String]
    /// The folder the test was saved in. If the test and its Verilog files are later moved or cloned
    /// somewhere else together, paths are found again relative to the test's new folder.
    var savedDir: String?

    init(test: TestState, sources: [String], savedDir: String? = nil) {
        self.test = test
        self.sources = sources
        self.savedDir = savedDir
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.v(.format, "hdltester-test")
        version = c.v(.version, 1)
        test = try c.decode(TestState.self, forKey: .test)
        sources = c.v(.sources, [])
        savedDir = c.v(.savedDir, nil)
    }

    /// Re-points paths that no longer exist, for a test now in `testDir`: first by where each file
    /// sat relative to the test when it was saved, then by looking for a file of the same name next to the test.
    mutating func relocate(testDir: URL) {
        let fm = FileManager.default
        var cache: [String: String] = [:]
        func fix(_ path: String) -> String {
            if let c = cache[path] { return c }
            var result = path
            if !path.isEmpty, !fm.fileExists(atPath: path) {
                var candidates: [String] = []
                if let old = savedDir {
                    let rel = Library.relativePath(path, from: old)
                    candidates.append(testDir.appendingPathComponent(rel).standardizedFileURL.path)
                }
                candidates.append(testDir.appendingPathComponent((path as NSString).lastPathComponent).path)
                if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) { result = found }
            }
            cache[path] = result
            return result
        }
        sources = sources.map(fix)
        for i in test.instances.indices where !test.instances[i].isSource {
            test.instances[i].filePath = fix(test.instances[i].filePath)
        }
    }
}

enum CanvasSelection: Equatable, Hashable {
    case instance(UUID)
    case pin(UUID, String)
    case wire(UUID)

    var instanceID: UUID? {
        switch self {
        case .instance(let id): return id
        case .pin(let id, _): return id
        case .wire: return nil
        }
    }
}

struct DragState: Equatable {
    var id: UUID
    var offset: CGSize
}

struct PendingWire: Equatable {
    var start: PinRef
    var startIsOutput: Bool
    var point: CGPoint
    var target: PinRef?
}

enum RunStatus: Equatable {
    case idle, compiling, simulating, passed, failed(String), stopped

    var isRunning: Bool { self == .compiling || self == .simulating }
}

struct LogLine: Identifiable {
    enum Kind { case command, info, stdout, warning, error, success }
    let id = UUID()
    var kind: Kind
    var text: String
}

@MainActor
@Observable
final class TestDocument: Identifiable {
    let id = UUID()
    var state: TestState {
        didSet { stateChanged(from: oldValue) }
    }
    var fileURL: URL?
    var isDirty = false
    var selection: CanvasSelection?
    var zoom: Double = 1
    /// A DUT box being dragged (not yet committed), so wires can follow it.
    var dragging: DragState?
    /// A wire being drawn with the mouse.
    var pendingWire: PendingWire?

    var status: RunStatus = .idle
    var log: [LogLine] = []
    var lastVCD: URL?
    var lastRunSeconds: Double?

    @ObservationIgnored private var undoStack: [TestState] = []
    @ObservationIgnored private var redoStack: [TestState] = []
    @ObservationIgnored private var lastEdit = Date.distantPast
    @ObservationIgnored private var suppressUndo = false
    @ObservationIgnored private var forceCheckpoint = false
    @ObservationIgnored var process: Process?

    init(state: TestState, fileURL: URL? = nil) {
        self.state = state
        self.fileURL = fileURL
    }

    var name: String { state.name }

    private func stateChanged(from old: TestState) {
        guard !suppressUndo, old != state else { return }
        isDirty = true
        let now = Date()
        if forceCheckpoint || now.timeIntervalSince(lastEdit) > 1.2 {
            undoStack.append(old)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastEdit = now
        forceCheckpoint = false
    }

    /// A discrete edit that gets its own undo step.
    func edit(_ body: (inout TestState) -> Void) {
        forceCheckpoint = true
        var s = state
        body(&s)
        state = s
        forceCheckpoint = false
        lastEdit = .distantPast
    }

    /// Changes that should not be undoable or mark the file edited (e.g. refreshing ports from disk).
    func silently(_ body: (inout TestState) -> Void) {
        suppressUndo = true
        var s = state
        body(&s)
        state = s
        suppressUndo = false
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        suppressUndo = true
        state = prev
        suppressUndo = false
        isDirty = true
        lastEdit = .distantPast
        validateSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        suppressUndo = true
        state = next
        suppressUndo = false
        isDirty = true
        lastEdit = .distantPast
        validateSelection()
    }

    func validateSelection() {
        guard let sel = selection else { return }
        if case .wire(let wid) = sel {
            if !state.wires.contains(where: { $0.id == wid }) { selection = nil }
            return
        }
        guard let iid = sel.instanceID, let inst = state.instance(iid) else { selection = nil; return }
        if case .pin(_, let p) = sel, !inst.ports.contains(where: { $0.name == p }) {
            selection = .instance(inst.id)
        }
    }

    // MARK: Instance helpers

    func index(of id: UUID) -> Int? { state.instances.firstIndex { $0.id == id } }

    func setStimulus(_ s: Stimulus, instance: UUID, pin: String) {
        guard let i = index(of: instance) else { return }
        state.instances[i].stimuli[pin] = s
    }

    func removeInstance(_ id: UUID) {
        edit {
            $0.instances.removeAll { $0.id == id }
            $0.wires.removeAll { $0.from.instance == id || $0.to.instance == id }
        }
        if selection?.instanceID == id { selection = nil }
    }

    /// Wires `from` (an output) to `to` (an input), replacing the input's old wire.
    func connect(from: PinRef, to: PinRef) {
        let w = Wire(from: from, to: to)
        edit {
            $0.wires.removeAll { $0.to == to }
            $0.wires.append(w)
        }
        selection = .wire(w.id)
    }

    func removeWire(_ id: UUID) {
        edit { $0.wires.removeAll { $0.id == id } }
        if selection == .wire(id) { selection = nil }
    }

    func disconnect(input: PinRef) {
        guard state.wire(to: input) != nil else { return }
        edit { $0.wires.removeAll { $0.to == input } }
    }

    /// Adds a new source wired to `input`, placed to its left. Returns the source's id.
    @discardableResult
    func addSource(_ preset: SourcePreset, wiredTo input: PinRef) -> UUID? {
        guard let dut = state.instance(input.instance), let port = dut.ports.first(where: { $0.name == input.pin }) else { return nil }
        let width = dut.resolve(port)?.width ?? 1
        let pinY = dut.y + Double(BlockLayout.rowY(dut.inputs.firstIndex { $0.name == port.name } ?? 0) - BlockLayout.labelH)
        let snap = { (v: Double) in (v / 10).rounded() * 10 }
        let base = preset == .constant || preset == .counter || preset == .random || preset == .bitstream || preset == .sequence
            ? (Fmt.isIdentifier(port.name) ? port.name : preset.baseName) : preset.baseName
        var src = DUTInstance(sourceNamed: state.uniqueName(base), width: preset == .clock || preset == .resetLow || preset == .resetHigh ? 1 : width,
                              stimulus: preset.stimulus(period: state.typicalClockPeriod),
                              x: snap(max(10, dut.x - 300)), y: snap(max(10, pinY - Double(SourceLayout.pinY))))
        // Don't stack exactly on top of another block
        while state.instances.contains(where: { $0.isSource && abs($0.x - src.x) < 60 && abs($0.y - src.y) < 50 }) { src.y += 60 }
        edit {
            $0.instances.append(src)
            $0.wires.removeAll { $0.to == input }
            $0.wires.append(Wire(from: PinRef(instance: src.id, pin: "out"), to: input))
        }
        return src.id
    }

    /// Wires every unwired input of a DUT: clocks and resets reuse a matching source if there is one,
    /// everything else gets its own constant source. Returns how many inputs were wired.
    @discardableResult
    func addSourcesForUnwiredInputs(of id: UUID) -> Int {
        guard let dut = state.instance(id), !dut.isSource else { return 0 }
        var s = state
        let env = dut.paramValues()
        let snap = { (v: Double) in (v / 10).rounded() * 10 }
        var y = snap(max(10, dut.y - 10))
        var count = 0
        for p in dut.inputs where p.unsupported == nil {
            let ref = PinRef(instance: dut.id, pin: p.name)
            guard s.wire(to: ref) == nil else { continue }
            let width = dut.resolve(p, env: env)?.width ?? 1
            let preset = SourcePreset.guess(for: p)
            if let existing = s.matchingSource(for: preset, width: width) {
                s.wires.append(Wire(from: PinRef(instance: existing.id, pin: "out"), to: ref))
            } else {
                while s.instances.contains(where: { $0.isSource && abs($0.x - (dut.x - 300)) < 60 && abs($0.y - y) < 50 }) { y += 60 }
                let base = preset == .constant ? (Fmt.isIdentifier(p.name) ? p.name : "const") : preset.baseName
                let src = DUTInstance(sourceNamed: s.uniqueName(base), width: preset == .constant ? width : 1,
                                      stimulus: preset.stimulus(period: s.typicalClockPeriod),
                                      x: snap(max(10, dut.x - 300)), y: y)
                s.instances.append(src)
                s.wires.append(Wire(from: PinRef(instance: src.id, pin: "out"), to: ref))
                y += 70
            }
            count += 1
        }
        if count > 0 { edit { $0 = s } }
        return count
    }

    func duplicateInstance(_ id: UUID) {
        guard let inst = state.instance(id) else { return }
        var copy = inst
        copy.id = UUID()
        copy.name = inst.isSource ? state.uniqueName(inst.name) : state.uniqueInstanceName(for: inst.moduleName)
        copy.x += 40
        copy.y += 40
        edit { $0.instances.append(copy) }
        selection = .instance(copy.id)
    }

    // MARK: Run log

    func appendLog(_ kind: LogLine.Kind, _ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var k = kind
            let l = line.lowercased()
            if kind == .stdout {
                if l.contains("error") || l.contains("fatal") || l.contains("syntax") { k = .error }
                else if l.contains("warning") { k = .warning }
            }
            if line.isEmpty && kind == .stdout { continue }
            log.append(LogLine(kind: k, text: String(line)))
        }
        if log.count > 20000 { log.removeFirst(log.count - 20000) }
    }

    func toFile(sources: [String]) -> TestFile {
        TestFile(test: state, sources: sources)
    }
}
