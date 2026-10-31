import Foundation

// MARK: - Time

struct TimeScale: Sendable, CustomStringConvertible {
    var magnitude: Double = 1
    var exponent: Int = -9

    static let units: [(exp: Int, name: String)] = [
        (0, "s"), (-3, "ms"), (-6, "µs"), (-9, "ns"), (-12, "ps"), (-15, "fs"),
    ]

    var description: String { "\(Int(magnitude)) \(Self.unitName(exponent))" }

    static func unitName(_ e: Int) -> String {
        units.first { $0.exp == e }?.name ?? "e\(e) s"
    }

    static func parse(_ text: String) -> TimeScale {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = t.prefix { $0.isNumber || $0 == "." }
        let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let exp: Int
        switch unit {
        case "s": exp = 0
        case "ms": exp = -3
        case "us", "µs": exp = -6
        case "ns": exp = -9
        case "ps": exp = -12
        case "fs": exp = -15
        default: exp = -9
        }
        return TimeScale(magnitude: Double(digits) ?? 1, exponent: exp)
    }

    func femtoseconds(_ t: Double) -> Double { t * magnitude * pow(10, Double(exponent + 15)) }
    func seconds(_ t: Double) -> Double { t * magnitude * pow(10, Double(exponent)) }

    /// Unit of the timescale itself, rounded down to a multiple of 3.
    var baseUnit: Int {
        let e = Int((Double(exponent) / 3).rounded(.down)) * 3
        return min(0, max(-15, e))
    }

    func bestUnit(forTime t: Double) -> Int {
        let fs = abs(femtoseconds(t))
        if fs == 0 { return baseUnit }
        for u in Self.units where fs >= pow(10, Double(u.exp + 15)) { return u.exp }
        return -15
    }

    func format(_ t: Double, unit: Int? = nil, decimals: Int? = nil) -> String {
        let u = unit ?? bestUnit(forTime: t)
        let v = femtoseconds(t) / pow(10, Double(u + 15))
        let s: String
        if let d = decimals {
            s = String(format: "%.\(d)f", v)
        } else {
            s = Self.trim(String(format: "%.3f", v))
        }
        return s + " " + Self.unitName(u)
    }

    static func trim(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var r = s
        while r.hasSuffix("0") { r.removeLast() }
        if r.hasSuffix(".") { r.removeLast() }
        return r
    }

    static func frequency(period seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let f = 1 / seconds
        let (v, u): (Double, String) =
            f >= 1e9 ? (f / 1e9, "GHz") : f >= 1e6 ? (f / 1e6, "MHz") : f >= 1e3 ? (f / 1e3, "kHz") : (f, "Hz")
        return trim(String(format: "%.3f", v)) + " " + u
    }
}

struct TickInfo {
    let step: Double
    let minor: Double?
    let unit: Int
    let decimals: Int

    static func compute(start: Double, tpp: Double, width: CGFloat, timescale ts: TimeScale) -> TickInfo {
        let raw = max(110 * tpp, 1e-9)
        let p = pow(10, floor(log10(raw)))
        var step = p * 10
        for m in [1.0, 2.0, 5.0, 10.0] where m * p >= raw { step = m * p; break }
        step = max(step, 1)
        let minor: Double? = step >= 5 ? step / 5 : (step >= 2 ? step / 2 : nil)
        let unit = ts.bestUnit(forTime: max(abs(start), abs(start + Double(width) * tpp)))
        let stepInUnit = ts.femtoseconds(step) / pow(10, Double(unit + 15))
        let decimals = stepInUnit >= 1 ? 0 : min(6, Int(ceil(-log10(stepInUnit) - 1e-9)))
        return TickInfo(step: step, minor: minor, unit: unit, decimals: decimals)
    }
}

// MARK: - Values

enum Radix: String, CaseIterable, Identifiable, Codable {
    case hex, binary, octal, unsigned, signed, ascii

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: return "Hexadecimal"
        case .binary: return "Binary"
        case .octal: return "Octal"
        case .unsigned: return "Unsigned Decimal"
        case .signed: return "Signed Decimal"
        case .ascii: return "ASCII"
        }
    }
}

enum ValueFormatter {
    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    static func format(_ v: String, trace: Trace, radix: Radix) -> String {
        if trace.isReal { return formatReal(v) }
        if trace.isString || trace.width == 1 { return v }
        let bits = Array(v.utf8)
        switch radix {
        case .binary: return v
        case .hex: return group(bits, 4)
        case .octal: return group(bits, 3)
        case .unsigned: return decimal(bits, signed: false)
        case .signed: return decimal(bits, signed: true)
        case .ascii: return ascii(bits)
        }
    }

    static func isUnknown(_ v: String) -> Bool { v.utf8.contains { $0 == 0x78 || $0 == 0x58 } }
    static func isHighZ(_ v: String) -> Bool { !v.isEmpty && v.utf8.allSatisfy { $0 == 0x7A } }

    static func formatReal(_ v: String) -> String {
        guard let d = Double(v) else { return v }
        return String(format: "%g", d)
    }

    static func group(_ bits: [UInt8], _ size: Int) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bits.count / size + 1)
        var end = bits.count
        while end > 0 {
            let start = max(0, end - size)
            var val = 0, xs = 0, zs = 0
            for i in start..<end {
                val <<= 1
                switch bits[i] {
                case 0x31: val |= 1
                case 0x30: break
                case 0x7A: zs += 1
                default: xs += 1
                }
            }
            let cnt = end - start
            let ch: UInt8
            if xs == cnt { ch = 0x78 }
            else if zs == cnt { ch = 0x7A }
            else if xs > 0 { ch = 0x58 }
            else if zs > 0 { ch = 0x5A }
            else { ch = digits[val] }
            out.append(ch)
            end = start
        }
        return String(decoding: out.reversed(), as: UTF8.self)
    }

    static func decimal(_ bits: [UInt8], signed: Bool) -> String {
        if bits.contains(where: { $0 != 0x30 && $0 != 0x31 }) {
            return bits.allSatisfy { $0 == 0x7A } ? "z" : "x"
        }
        if signed, bits.first == 0x31 {
            var inv = bits.map { $0 == 0x31 ? UInt8(0x30) : UInt8(0x31) }
            var i = inv.count - 1
            while i >= 0 {
                if inv[i] == 0x30 { inv[i] = 0x31; break }
                inv[i] = 0x30
                i -= 1
            }
            return "-" + unsignedString(inv)
        }
        return unsignedString(bits)
    }

    static func unsignedString(_ bits: [UInt8]) -> String {
        if bits.count <= 64 {
            var v: UInt64 = 0
            for b in bits { v = (v << 1) | (b == 0x31 ? 1 : 0) }
            return String(v)
        }
        var limbs: [UInt32] = [0] // base 1e9, little endian
        for b in bits {
            var carry: UInt64 = b == 0x31 ? 1 : 0
            for j in 0..<limbs.count {
                let x = UInt64(limbs[j]) * 2 + carry
                limbs[j] = UInt32(x % 1_000_000_000)
                carry = x / 1_000_000_000
            }
            if carry > 0 { limbs.append(UInt32(carry)) }
        }
        var s = String(limbs[limbs.count - 1])
        for limb in limbs.dropLast().reversed() {
            let part = String(limb)
            s += String(repeating: "0", count: 9 - part.count) + part
        }
        return s
    }

    static func ascii(_ bits: [UInt8]) -> String {
        var b = bits
        let rem = b.count % 8
        if rem != 0 { b.insert(contentsOf: repeatElement(0x30, count: 8 - rem), at: 0) }
        var out = ""
        var started = false
        for i in stride(from: 0, to: b.count, by: 8) {
            var v: UInt8 = 0
            var known = true
            for j in i..<(i + 8) {
                v <<= 1
                if b[j] == 0x31 { v |= 1 } else if b[j] != 0x30 { known = false }
            }
            if known && v == 0 && !started { continue }
            started = true
            out.append(known && v >= 32 && v < 127 ? Character(UnicodeScalar(v)) : "·")
        }
        return "\"" + out + "\""
    }
}

// MARK: - Analog display

enum DisplayMode: String, CaseIterable, Identifiable, Codable {
    case digital, analogUnsigned, analogSigned, analogAuto

    var id: String { rawValue }
    var isAnalog: Bool { self != .digital }

    var title: String {
        switch self {
        case .digital: return "Digital"
        case .analogUnsigned: return "Analog Unsigned  (code / 2ᴺ  →  0 … 1)"
        case .analogSigned: return "Analog Signed  (code / 2ᴺ⁻¹  →  −1 … +1)"
        case .analogAuto: return "Analog  (auto range)"
        }
    }

    var shortTitle: String {
        switch self {
        case .digital: return "digital"
        case .analogUnsigned: return "analog · unsigned, FS = 1"
        case .analogSigned: return "analog · signed, FS = ±1"
        case .analogAuto: return "analog · auto range"
        }
    }
}

enum Interpolation: String, CaseIterable, Identifiable, Codable {
    case step, linear
    var id: String { rawValue }
    var title: String { self == .step ? "Step  (sample & hold)" : "Linear" }
}

enum Analog {
    /// Converts a stored value to its analog level, or nil for X / Z.
    /// Unsigned: code / 2^N in [0, 1).  Signed (two's complement): code / 2^(N-1) in [-1, 1).
    static func level(_ v: String, trace: Trace, mode: DisplayMode) -> Double? {
        if trace.isReal { return Double(v) }
        if trace.isString { return nil }
        let n = v.utf8.count
        guard n > 0 else { return nil }
        var acc = 0.0
        var msb: UInt8 = 0
        var first = true
        for c in v.utf8 {
            let bit: Double
            switch c {
            case 0x30: bit = 0
            case 0x31: bit = 1
            default: return nil
            }
            if first { msb = c; first = false }
            acc = acc * 2 + bit
        }
        switch mode {
        case .analogSigned:
            if msb == 0x31 { acc -= pow(2, Double(n)) }
            return acc / pow(2, Double(n - 1))
        case .analogAuto:
            return acc
        default:
            return acc / pow(2, Double(n))
        }
    }

    /// Plot range for a mode.
    static func range(trace: Trace, mode: DisplayMode) -> (lo: Double, hi: Double) {
        switch mode {
        case .analogSigned: return (-1, 1)
        case .analogUnsigned, .digital: return (0, 1)
        case .analogAuto:
            let r = trace.levelRange(mode: mode)
            if r.hi - r.lo < 1e-12 { return (r.lo - 1, r.hi + 1) }
            let pad = (r.hi - r.lo) * 0.05
            return (r.lo - pad, r.hi + pad)
        }
    }

    /// Decimal places that show one LSB for an N-bit full-scale value.
    static func decimals(width: Int) -> Int { min(9, max(3, Int((Double(width) * log10(2)).rounded(.up)))) }

    static func format(_ level: Double, trace: Trace, mode: DisplayMode) -> String {
        switch mode {
        case .analogSigned: return String(format: "%+.\(decimals(width: trace.width - 1))f", level)
        case .analogUnsigned: return String(format: "%.\(decimals(width: trace.width))f", level)
        default: return String(format: "%g", level)
        }
    }
}

extension Trace {
    /// Min and max analog level over the whole trace (used for auto range).
    func levelRange(mode: DisplayMode) -> (lo: Double, hi: Double) {
        if let c = cachedAutoRange { return c }
        var lo = Double.infinity, hi = -Double.infinity
        for v in values {
            if let x = Analog.level(v, trace: self, mode: mode) { lo = min(lo, x); hi = max(hi, x) }
        }
        let r = lo.isFinite ? (lo, hi) : (0.0, 1.0)
        cachedAutoRange = r
        return r
    }
}
