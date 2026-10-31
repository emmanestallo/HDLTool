import SwiftUI

/// Draws a stimulus as a waveform.
struct StimWave: View {
    let segs: [WaveSeg]
    let horizon: Double
    let color: Color
    var start: Double = 0
    @Environment(\.theme) private var theme

    var body: some View {
        let xColor = theme.waveX, zColor = theme.waveZ, textColor = theme.fg
        Canvas { ctx, size in
            guard horizon > start, !segs.isEmpty else { return }
            let w = size.width
            let top: CGFloat = 4, bot = size.height - 4, mid = size.height / 2
            let span = horizon - start
            func x(_ t: Double) -> CGFloat { CGFloat((t - start) / span) * w }
            let isBus = segs.contains { $0.level == .bus }

            var line = Path()
            var lastY: CGFloat?
            for (i, s) in segs.enumerated() {
                let x0 = max(0, x(s.t))
                let x1 = min(w, i + 1 < segs.count ? x(segs[i + 1].t) : w)
                if x1 < 0 { continue }
                if x0 > w { break }
                if isBus || s.level == .bus {
                    // Hexagon per value
                    let slant = min(3, max(0, (x1 - x0) / 2))
                    var hex = Path()
                    hex.move(to: CGPoint(x: x0, y: mid))
                    hex.addLine(to: CGPoint(x: x0 + slant, y: top))
                    hex.addLine(to: CGPoint(x: x1 - slant, y: top))
                    hex.addLine(to: CGPoint(x: x1, y: mid))
                    hex.addLine(to: CGPoint(x: x1 - slant, y: bot))
                    hex.addLine(to: CGPoint(x: x0 + slant, y: bot))
                    hex.closeSubpath()
                    let c: Color = s.level == .x ? xColor : (s.level == .z ? zColor : color)
                    ctx.fill(hex, with: .color(c.opacity(s.level == .x ? 0.28 : 0.12)))
                    ctx.stroke(hex, with: .color(c), lineWidth: 1.2)
                    let label = s.label
                    if x1 - x0 > CGFloat(label.count) * 6.2 + 10 {
                        ctx.draw(Text(label).font(.system(size: 9.5, design: .monospaced)).foregroundColor(textColor),
                                 at: CGPoint(x: (x0 + x1) / 2, y: mid))
                    }
                    continue
                }
                let y: CGFloat
                switch s.level {
                case .high: y = top
                case .low: y = bot
                default: y = mid
                }
                if let ly = lastY {
                    line.addLine(to: CGPoint(x: x0, y: ly))
                    line.addLine(to: CGPoint(x: x0, y: y))
                } else {
                    line.move(to: CGPoint(x: x0, y: y))
                }
                lastY = y
                if s.level == .x {
                    ctx.fill(Path(CGRect(x: x0, y: top, width: x1 - x0, height: bot - top)), with: .color(xColor.opacity(0.25)))
                } else if s.level == .z {
                    var zl = Path()
                    zl.move(to: CGPoint(x: x0, y: mid))
                    zl.addLine(to: CGPoint(x: x1, y: mid))
                    ctx.stroke(zl, with: .color(zColor), lineWidth: 1.5)
                }
                if i == segs.count - 1 || x1 >= w {
                    line.addLine(to: CGPoint(x: x1, y: y))
                }
            }
            if !isBus {
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .miter))
            }
        }
    }
}

/// Picks tick spacing for a time axis.
enum Ticks {
    static func step(span: Double, maxTicks: Int) -> Double {
        guard span > 0, maxTicks > 0 else { return 1 }
        let raw = span / Double(maxTicks)
        let mag = pow(10, floor(log10(raw)))
        for m in [1.0, 2, 5, 10] where mag * m >= raw { return mag * m }
        return mag * 10
    }
}

struct TimeRuler: View {
    let horizon: Double
    let unit: TimeUnit
    @Environment(\.theme) private var theme

    var body: some View {
        let dim = theme.dimFG, border = theme.border
        Canvas { ctx, size in
            guard horizon > 0 else { return }
            let step = Ticks.step(span: horizon, maxTicks: max(1, Int(size.width / 90)))
            var t = 0.0
            while t <= horizon + step * 0.01 {
                let x = CGFloat(t / horizon) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 5))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(tick, with: .color(border), lineWidth: 1)
                let label = Text(Fmt.num(t) + (t == 0 ? "" : " " + unit.rawValue))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(dim)
                ctx.draw(label, at: CGPoint(x: min(max(x + 3, 0), size.width - 2), y: size.height / 2 - 1),
                         anchor: x > size.width - 40 ? .trailing : .leading)
                t += step
            }
        }
    }
}
