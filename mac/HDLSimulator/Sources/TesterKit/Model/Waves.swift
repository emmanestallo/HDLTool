import Foundation

/// One stretch of constant value in a stimulus preview.
struct WaveSeg: Equatable {
    enum Level { case low, high, x, z, bus }
    var t: Double
    var level: Level
    var label: String
}

enum StimulusPreview {
    static let maxSegments = 20000

    static func seg(_ t: Double, _ text: String, width: Int) -> WaveSeg {
        guard let bits = LogicLiteral.parse(text)?.bits(width: max(width, 1)) else {
            return WaveSeg(t: t, level: .x, label: "?")
        }
        return seg(t, bits)
    }

    static func seg(_ t: Double, _ bits: [Bit]) -> WaveSeg {
        if bits.count == 1 {
            switch bits[0] {
            case .zero: return WaveSeg(t: t, level: .low, label: "0")
            case .one: return WaveSeg(t: t, level: .high, label: "1")
            case .x: return WaveSeg(t: t, level: .x, label: "x")
            case .z: return WaveSeg(t: t, level: .z, label: "z")
            }
        }
        if bits.allSatisfy({ $0 == .x }) { return WaveSeg(t: t, level: .x, label: "x") }
        if bits.allSatisfy({ $0 == .z }) { return WaveSeg(t: t, level: .z, label: "z") }
        return WaveSeg(t: t, level: .bus, label: BitsFormat.hex(bits))
    }

    /// Value changes of a stimulus from 0 up to `horizon`.
    static func segments(_ s: Stimulus, width: Int?, horizon: Double) -> [WaveSeg] {
        let w = max(width ?? 1, 1)
        var out: [WaveSeg] = []
        func add(_ seg: WaveSeg) {
            if let last = out.last, last.level == seg.level, last.label == seg.label { return }
            if let last = out.last, last.t == seg.t { out.removeLast() }
            out.append(seg)
        }
        switch s.kind {
        case .constant:
            add(seg(0, s.constant, width: w))

        case .clock:
            guard s.period > 0 else { return [seg(0, "x", width: 1)] }
            let duty = min(max(s.duty, 0.0001), 99.9999)
            let high = s.period * duty / 100, low = s.period - high
            var level = s.startHigh
            var t = 0.0
            add(seg(0, level ? "1" : "0", width: w))
            t = s.clockDelay
            while t <= horizon && out.count < maxSegments {
                t += level ? high : low
                level.toggle()
                add(seg(t, level ? "1" : "0", width: w))
            }

        case .sequence:
            add(seg(0, s.seqInitial, width: w))
            let steps = s.relativeSteps
            let total = steps.reduce(0) { $0 + $1.delay }
            var t = 0.0
            repeat {
                for st in steps {
                    t += max(0, st.delay)
                    if t > horizon { break }
                    add(seg(t, st.value, width: w))
                }
            } while s.seqRepeat && total > 0 && t <= horizon && out.count < maxSegments

        case .bitstream:
            add(seg(0, s.bitIdle, width: w))
            let toks = s.streamTokens(width: width)
            guard s.bitTime > 0, !toks.isEmpty else { break }
            var t = s.bitDelay
            repeat {
                for tok in toks {
                    if t > horizon { break }
                    add(seg(t, tok, width: w))
                    t += s.bitTime
                }
            } while s.bitRepeat && t <= horizon && out.count < maxSegments
            if !s.bitRepeat && t <= horizon { add(seg(t, s.bitIdle, width: w)) }

        case .counter:
            guard let startBits = LogicLiteral.parse(s.countStart)?.bits(width: w),
                  let stepBits = LogicLiteral.parse(s.countStep)?.bits(width: w),
                  w <= 64, var v = BitsFormat.uint(startBits), let step = BitsFormat.uint(stepBits) else {
                add(seg(0, s.countStart, width: w))
                break
            }
            let mask: UInt64 = w == 64 ? .max : (1 << UInt64(w)) - 1
            add(seg(0, BitsFormat.bits(v, width: w)))
            guard s.countInterval > 0 else { break }
            var t = s.countDelay + s.countInterval
            while t <= horizon && out.count < maxSegments {
                v = (v &+ step) & mask
                add(seg(t, BitsFormat.bits(v, width: w)))
                t += s.countInterval
            }

        case .random:
            add(seg(0, BitsFormat.bits(0, width: w)))
            guard s.randInterval > 0 else { break }
            var rng = UInt64(bitPattern: Int64(s.randSeed)) &* 6364136223846793005 &+ 1442695040888963407
            var t = s.randDelay
            while t <= horizon && out.count < maxSegments {
                var bits: [Bit] = []
                while bits.count < w {
                    rng = rng &* 6364136223846793005 &+ 1442695040888963407
                    bits += BitsFormat.bits(rng >> 11, width: min(53, w - bits.count))
                }
                add(seg(t, bits))
                t += s.randInterval
            }
        }
        return out
    }

    /// A horizon that shows the interesting part of a stimulus.
    static func suggestedHorizon(_ s: Stimulus, duration: Double) -> Double {
        let h: Double
        switch s.kind {
        case .constant: h = duration
        case .clock: h = s.clockDelay + s.period * 8
        case .sequence:
            let total = s.relativeSteps.reduce(0) { $0 + $1.delay }
            h = s.seqRepeat ? total * 2.5 : total * 1.25
        case .bitstream:
            h = s.bitDelay + s.bitTime * Double(max(1, s.streamTokens(width: nil).count)) * (s.bitRepeat ? 1.5 : 1.2)
        case .counter: h = s.countDelay + s.countInterval * 10
        case .random: h = s.randDelay + s.randInterval * 10
        }
        guard h > 0 else { return max(duration, 1) }
        return min(max(h, 1e-9), max(duration, 1e-9))
    }
}
