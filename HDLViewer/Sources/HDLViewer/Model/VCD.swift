import Foundation

/// All value changes for one VCD identifier code (several variables can share one).
final class Trace: @unchecked Sendable {
    let width: Int
    let isReal: Bool
    let isString: Bool
    var times: [UInt64] = []
    var values: [String] = []
    var cachedAutoRange: (lo: Double, hi: Double)?

    init(width: Int, isReal: Bool, isString: Bool = false) {
        self.width = max(width, 1)
        self.isReal = isReal
        self.isString = isString
    }

    var isBit: Bool { width == 1 && !isReal && !isString }

    @inline(__always)
    func append(_ t: UInt64, _ v: String) {
        let c = times.count
        if c > 0 {
            if times[c - 1] == t {
                // Several changes at the same timestamp: keep the last one.
                if c >= 2 && values[c - 2] == v {
                    times.removeLast(); values.removeLast()
                } else {
                    values[c - 1] = v
                }
                return
            }
            if values[c - 1] == v { return }
        }
        times.append(t)
        values.append(v)
    }

    /// Index of the last change at or before `t`.
    func lastIndex(atOrBefore t: Double) -> Int? {
        var lo = 0, hi = times.count
        while lo < hi {
            let m = (lo + hi) >> 1
            if Double(times[m]) <= t { lo = m + 1 } else { hi = m }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// Index of the first change at or after `t` (may equal `times.count`).
    func firstIndex(atOrAfter t: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let m = (lo + hi) >> 1
            if Double(times[m]) < t { lo = m + 1 } else { hi = m }
        }
        return lo
    }

    func value(at t: Double) -> String? {
        lastIndex(atOrBefore: t).map { values[$0] }
    }
}

final class VCDVar: Identifiable, @unchecked Sendable {
    let id: Int
    let name: String
    let range: String
    let kind: String
    let width: Int
    let scopePath: String
    let trace: Trace

    init(id: Int, name: String, range: String, kind: String, width: Int, scopePath: String, trace: Trace) {
        self.id = id
        self.name = name
        self.range = range
        self.kind = kind
        self.width = width
        self.scopePath = scopePath
        self.trace = trace
    }

    var fullPath: String { scopePath.isEmpty ? name + range : scopePath + "." + name + range }
}

final class VCDScope: Identifiable, @unchecked Sendable {
    let id: Int
    let name: String
    let kind: String
    let path: String
    var children: [VCDScope] = []
    var vars: [VCDVar] = []

    init(id: Int, name: String, kind: String, path: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
    }
}

final class VCDFile: @unchecked Sendable {
    let url: URL
    let root: VCDScope
    let allVars: [VCDVar]
    let timescale: TimeScale
    let startTime: UInt64
    let endTime: UInt64
    let version: String

    init(url: URL, root: VCDScope, allVars: [VCDVar], timescale: TimeScale, startTime: UInt64, endTime: UInt64, version: String) {
        self.url = url
        self.root = root
        self.allVars = allVars
        self.timescale = timescale
        self.startTime = startTime
        self.endTime = endTime
        self.version = version
    }

    func scope(withID id: Int) -> VCDScope? {
        if root.id == id { return root }
        var stack = root.children
        while let s = stack.popLast() {
            if s.id == id { return s }
            stack.append(contentsOf: s.children)
        }
        return nil
    }
}

enum VCDError: LocalizedError {
    case empty
    case noSignals

    var errorDescription: String? {
        switch self {
        case .empty: return "The file is empty."
        case .noSignals: return "No signals were found. Is this a VCD file?"
        }
    }
}

enum VCDParser {
    static func parse(url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> VCDFile {
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        guard !data.isEmpty else { throw VCDError.empty }
        return try data.withUnsafeBytes { raw -> VCDFile in
            var state = ParserState(buf: raw.bindMemory(to: UInt8.self), url: url, progress: progress)
            return try state.run()
        }
    }
}

private struct ParserState {
    let buf: UnsafeBufferPointer<UInt8>
    let n: Int
    let url: URL
    let progress: (@Sendable (Double) -> Void)?
    var p = 0

    var shortMap: [UInt64: Trace] = [:]
    var longMap: [String: Trace] = [:]

    init(buf: UnsafeBufferPointer<UInt8>, url: URL, progress: (@Sendable (Double) -> Void)?) {
        self.buf = buf
        self.n = buf.count
        self.url = url
        self.progress = progress
    }

    // MARK: Tokenizer

    @inline(__always) static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 12 }

    @inline(__always)
    mutating func token() -> Range<Int>? {
        while p < n && ParserState.isSpace(buf[p]) { p += 1 }
        if p >= n { return nil }
        let s = p
        while p < n && !ParserState.isSpace(buf[p]) { p += 1 }
        return s..<p
    }

    @inline(__always)
    func string(_ r: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: buf[r]), as: UTF8.self)
    }

    @inline(__always)
    func isEnd(_ r: Range<Int>) -> Bool {
        r.count == 4 && buf[r.lowerBound] == 0x24 && buf[r.lowerBound + 1] == 0x65
            && buf[r.lowerBound + 2] == 0x6E && buf[r.lowerBound + 3] == 0x64
    }

    mutating func tokensUntilEnd() -> [String] {
        var out: [String] = []
        while let t = token() {
            if isEnd(t) { break }
            out.append(string(t))
        }
        return out
    }

    mutating func skipUntilEnd() {
        while let t = token() { if isEnd(t) { break } }
    }

    @inline(__always)
    func packedKey(_ r: Range<Int>) -> UInt64? {
        guard r.count <= 8 else { return nil }
        var k: UInt64 = 0
        for i in r { k = (k << 8) | UInt64(buf[i]) }
        return k
    }

    static func packedKey(_ s: String) -> UInt64? {
        let b = Array(s.utf8)
        guard b.count <= 8 else { return nil }
        var k: UInt64 = 0
        for c in b { k = (k << 8) | UInt64(c) }
        return k
    }

    @inline(__always)
    func trace(_ r: Range<Int>) -> Trace? {
        if let k = packedKey(r) { return shortMap[k] }
        return longMap[string(r)]
    }

    func parseUInt(_ r: Range<Int>) -> UInt64 {
        var v: UInt64 = 0
        for i in r {
            let d = buf[i] &- 48
            if d > 9 { break }
            v = v &* 10 &+ UInt64(d)
        }
        return v
    }

    // MARK: Values

    static let s0 = "0", s1 = "1", sx = "x", sz = "z"

    func vectorValue(_ r: Range<Int>, width: Int) -> String {
        // Fast path: already full-width and plain binary.
        if r.count == width {
            var plain = true
            for i in r where buf[i] != 0x30 && buf[i] != 0x31 { plain = false; break }
            if plain { return string(r) }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(max(width, r.count))
        for i in r {
            let c = buf[i] | 0x20
            switch c {
            case 0x30, 0x31, 0x78, 0x7A: bytes.append(c)
            case 0x68: bytes.append(0x31) // h
            case 0x6C: bytes.append(0x30) // l
            default: bytes.append(0x78)   // u, w, -, ...
            }
        }
        if bytes.isEmpty { bytes.append(0x78) }
        if bytes.count < width {
            let f = bytes[0]
            let pad: UInt8 = (f == 0x78 || f == 0x7A) ? f : 0x30
            bytes.insert(contentsOf: repeatElement(pad, count: width - bytes.count), at: 0)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Main

    mutating func run() throws -> VCDFile {
        var scopeID = 0
        let root = VCDScope(id: scopeID, name: "", kind: "root", path: "")
        var stack: [VCDScope] = [root]
        var allVars: [VCDVar] = []
        var timescale = TimeScale()
        var version = ""

        header: while let t = token() {
            let kw = string(t)
            switch kw {
            case "$scope":
                let toks = tokensUntilEnd()
                let kind = toks.first ?? "module"
                let name = toks.count > 1 ? toks[1] : "unnamed"
                let parent = stack[stack.count - 1]
                scopeID += 1
                let s = VCDScope(id: scopeID, name: name, kind: kind,
                                 path: parent.path.isEmpty ? name : parent.path + "." + name)
                parent.children.append(s)
                stack.append(s)
            case "$upscope":
                skipUntilEnd()
                if stack.count > 1 { stack.removeLast() }
            case "$var":
                let toks = tokensUntilEnd()
                guard toks.count >= 4 else { continue }
                let kind = toks[0]
                let width = Int(toks[1]) ?? 1
                let code = toks[2]
                var name = toks[3]
                var range = toks.count > 4 ? toks[4...].joined() : ""
                if range.isEmpty, !name.hasPrefix("\\"), name.hasSuffix("]"), let br = name.firstIndex(of: "[") {
                    range = String(name[br...])
                    name = String(name[..<br])
                }
                let isReal = kind == "real" || kind == "realtime" || kind == "shortreal"
                let isString = kind == "string"
                let tr: Trace
                if let k = ParserState.packedKey(code) {
                    if let existing = shortMap[k] { tr = existing } else {
                        tr = Trace(width: width, isReal: isReal, isString: isString); shortMap[k] = tr
                    }
                } else {
                    if let existing = longMap[code] { tr = existing } else {
                        tr = Trace(width: width, isReal: isReal, isString: isString); longMap[code] = tr
                    }
                }
                let scope = stack[stack.count - 1]
                let v = VCDVar(id: allVars.count, name: name, range: range, kind: kind,
                               width: width, scopePath: scope.path, trace: tr)
                scope.vars.append(v)
                allVars.append(v)
            case "$timescale":
                timescale = TimeScale.parse(tokensUntilEnd().joined())
            case "$version":
                version = tokensUntilEnd().joined(separator: " ")
            case "$enddefinitions":
                skipUntilEnd()
                break header
            default:
                if kw.hasPrefix("$") { skipUntilEnd() }
            }
        }

        guard !allVars.isEmpty else { throw VCDError.noSignals }

        var time: UInt64 = 0
        var firstTime: UInt64? = nil
        var maxTime: UInt64 = 0
        var lastReport = p

        while let t = token() {
            let c = buf[t.lowerBound]
            switch c {
            case 0x23: // '#'
                time = parseUInt((t.lowerBound + 1)..<t.upperBound)
                if firstTime == nil { firstTime = time }
                if time > maxTime { maxTime = time }
                if p - lastReport > 8_000_000 {
                    progress?(Double(p) / Double(n))
                    lastReport = p
                }
            case 0x30, 0x31, 0x78, 0x58, 0x7A, 0x5A, 0x75, 0x55, 0x77, 0x57, 0x2D, 0x6C, 0x4C, 0x68, 0x48:
                guard t.count >= 2, let tr = trace((t.lowerBound + 1)..<t.upperBound) else { continue }
                let v: String
                switch c | 0x20 {
                case 0x30, 0x6C: v = ParserState.s0
                case 0x31, 0x68: v = ParserState.s1
                case 0x7A: v = ParserState.sz
                default: v = ParserState.sx
                }
                tr.append(time, v)
            case 0x62, 0x42: // 'b'
                guard let idR = token(), let tr = trace(idR) else { continue }
                tr.append(time, vectorValue((t.lowerBound + 1)..<t.upperBound, width: tr.width))
            case 0x72, 0x52, 0x73, 0x53: // 'r' real / 's' string
                guard let idR = token(), let tr = trace(idR) else { continue }
                tr.append(time, string((t.lowerBound + 1)..<t.upperBound))
            case 0x24: // '$'
                if t.count == 8 && string(t) == "$comment" { skipUntilEnd() }
            default:
                continue
            }
        }
        progress?(1)

        return VCDFile(url: url, root: root, allVars: allVars, timescale: timescale,
                       startTime: firstTime ?? 0, endTime: maxTime, version: version)
    }
}
