import AppKit
import SwiftUI

struct WaveStyle {
    let color: Color
    let x: Color
    let z: Color
    let text: Color
    var guide: Color = .gray.opacity(0.2)
    var label: Color = .gray
    var labelBG: Color = .clear
}

/// Draws one signal row. Changes that fall into the same pixel column are
/// collapsed into a single "busy" bar, so cost scales with width, not file size.
enum WaveRenderer {
    static let font = Font.system(size: 11, design: .monospaced)
    static let charWidth: CGFloat = {
        let f = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: f]).width
    }()

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, trace: Trace, start: Double, tpp: Double,
                     endTime: Double, radix: Radix, style: WaveStyle) {
        let n = trace.times.count
        guard n > 0, tpp > 0 else { return }
        let w = size.width, h = size.height
        let top: CGFloat = 5, bot = h - 6, mid = (top + bot) / 2
        let endX = CGFloat((endTime - start) / tpp)

        @inline(__always) func X(_ i: Int) -> CGFloat { CGFloat((Double(trace.times[i]) - start) / tpp) }

        var k = trace.lastIndex(atOrBefore: start) ?? 0
        var busy = Path()

        // Walks segments; calls body(segmentStartX, segmentEndX, value, wasBusy).
        func walk(_ body: (CGFloat, CGFloat, String, Bool) -> Void) {
            while k < n {
                let xs = X(k)
                if xs > w + 2 { break }
                var kEnd = k
                var isBusy = false
                let col = xs.rounded(.down)
                if k + 1 < n && X(k + 1) < col + 1 {
                    let tNext = start + Double(col + 1) * tpp
                    kEnd = max(k, trace.firstIndex(atOrAfter: tNext) - 1)
                    busy.addRect(CGRect(x: col, y: top, width: 1, height: bot - top))
                    isBusy = true
                }
                let xe = kEnd + 1 < n ? X(kEnd + 1) : max(endX, X(kEnd))
                body(isBusy ? col + 1 : xs, xe, trace.values[kEnd], isBusy)
                k = kEnd + 1
            }
        }

        if trace.isBit {
            var line = Path(), fill = Path(), xr = Path(), zl = Path()
            var prevY: CGFloat?
            walk { xs, xe, v, wasBusy in
                let x0 = max(xs, -2), x1 = min(xe, w + 2)
                let y: CGFloat
                switch v {
                case "1":
                    y = top
                    if x1 > x0 { fill.addRect(CGRect(x: x0, y: top, width: x1 - x0, height: bot - top)) }
                case "0":
                    y = bot
                case "z":
                    y = mid
                default:
                    y = mid
                    if x1 > x0 { xr.addRect(CGRect(x: x0, y: top, width: x1 - x0, height: bot - top)) }
                }
                if let py = prevY, !wasBusy, xs >= -2, py != y {
                    line.move(to: CGPoint(x: xs, y: py))
                    line.addLine(to: CGPoint(x: xs, y: y))
                }
                if x1 > x0 {
                    if v == "z" {
                        zl.move(to: CGPoint(x: x0, y: y)); zl.addLine(to: CGPoint(x: x1, y: y))
                    } else if v == "0" || v == "1" {
                        line.move(to: CGPoint(x: x0, y: y)); line.addLine(to: CGPoint(x: x1, y: y))
                    }
                }
                prevY = y
            }
            ctx.fill(fill, with: .color(style.color.opacity(0.13)))
            ctx.fill(xr, with: .color(style.x.opacity(0.28)))
            ctx.stroke(xr, with: .color(style.x.opacity(0.9)), lineWidth: 1)
            ctx.stroke(zl, with: .color(style.z), lineWidth: 1.5)
            ctx.stroke(line, with: .color(style.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .square, lineJoin: .miter))
            ctx.fill(busy, with: .color(style.color))
            return
        }

        // Vectors, reals and strings: hexagon "bus" segments with value labels.
        var outline = Path(), xFill = Path(), xLine = Path(), zLine = Path()
        var labels: [(String, CGFloat, Color)] = []
        let isNumeric = !trace.isReal && !trace.isString
        walk { xs, xe, v, _ in
            guard xe - xs >= 1 else { return }
            let x0 = max(xs, -20), x1 = min(xe, w + 20)
            guard x1 > x0 else { return }
            let s = min(3, (xe - xs) / 2)
            let unknown = isNumeric && ValueFormatter.isUnknown(v)
            let highZ = isNumeric && ValueFormatter.isHighZ(v)
            if highZ {
                zLine.move(to: CGPoint(x: x0, y: mid)); zLine.addLine(to: CGPoint(x: x1, y: mid))
                if xs >= -2 {
                    zLine.move(to: CGPoint(x: xs, y: top)); zLine.addLine(to: CGPoint(x: xs, y: bot))
                }
            } else {
                var p = Path()
                p.move(to: CGPoint(x: xs, y: mid))
                p.addLine(to: CGPoint(x: xs + s, y: top))
                p.addLine(to: CGPoint(x: xe - s, y: top))
                p.addLine(to: CGPoint(x: xe, y: mid))
                p.addLine(to: CGPoint(x: xe - s, y: bot))
                p.addLine(to: CGPoint(x: xs + s, y: bot))
                p.closeSubpath()
                if unknown { xFill.addPath(p); xLine.addPath(p) } else { outline.addPath(p) }
            }
            let vis0 = max(xs + s + 3, 2), vis1 = min(xe - s - 3, w - 2)
            let avail = vis1 - vis0
            guard avail >= charWidth else { return }
            var label = ValueFormatter.format(v, trace: trace, radix: radix)
            let maxChars = Int(avail / charWidth)
            if label.count > maxChars {
                guard maxChars >= 2 else { return }
                label = String(label.prefix(maxChars - 1)) + "…"
            }
            let color = highZ ? style.z : (unknown ? style.x : style.text)
            labels.append((label, (vis0 + vis1) / 2, color))
        }
        ctx.fill(outline, with: .color(style.color.opacity(0.10)))
        ctx.stroke(outline, with: .color(style.color), lineWidth: 1.2)
        ctx.fill(xFill, with: .color(style.x.opacity(0.22)))
        ctx.stroke(xLine, with: .color(style.x), lineWidth: 1.2)
        ctx.stroke(zLine, with: .color(style.z), lineWidth: 1.5)
        ctx.fill(busy, with: .color(style.color))
        for (label, cx, color) in labels {
            ctx.draw(Text(label).font(font).foregroundColor(color), at: CGPoint(x: cx, y: mid), anchor: .center)
        }
    }

    // MARK: Analog

    static let axisFont = Font.system(size: 9, design: .monospaced)

    /// Plots a vector or real signal as an analog trace. Levels are scaled to full scale
    /// (see `Analog.level`). Several changes in one pixel column become a min–max bar.
    static func drawAnalog(_ ctx: inout GraphicsContext, size: CGSize, trace: Trace, start: Double, tpp: Double,
                           endTime: Double, mode: DisplayMode, interpolation: Interpolation, style: WaveStyle) {
        let w = size.width, h = size.height
        let plotTop: CGFloat = 7, plotBot = h - 8
        let (lo, hi) = Analog.range(trace: trace, mode: mode)
        func Y(_ v: Double) -> CGFloat {
            let f = (v - lo) / (hi - lo)
            return plotBot - CGFloat(f) * (plotBot - plotTop)
        }

        // Reference lines and axis labels.
        var guides: [(Double, Bool)] = []   // (level, solid)
        switch mode {
        case .analogSigned: guides = [(1, false), (0.5, false), (0, true), (-0.5, false), (-1, false)]
        case .analogUnsigned: guides = [(1, false), (0.5, false), (0, true)]
        default:
            let r = trace.levelRange(mode: mode)
            guides = r.hi - r.lo < 1e-12 ? [(r.lo, false)] : [(r.hi, false), ((r.hi + r.lo) / 2, false), (r.lo, false)]
        }
        let showLabels = h >= 60
        let showHalf = h >= 80
        var labels: [(String, CGFloat)] = []
        for (level, solid) in guides {
            if !solid && abs(abs(level) - 0.5) < 1e-12 && mode != .analogAuto && !showHalf { continue }
            let y = Y(level).rounded() + 0.5
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(p, with: .color(style.guide.opacity(solid ? 1.6 : 1)),
                       style: StrokeStyle(lineWidth: 1, dash: solid ? [] : [2, 3]))
            if showLabels {
                let text: String
                switch mode {
                case .analogSigned: text = level == 0 ? "0" : String(format: "%+g", level)
                case .analogUnsigned: text = String(format: "%g", level)
                default: text = String(format: "%.4g", level)
                }
                labels.append((text, y))
            }
        }

        // Axis labels go on top of the curve, on a small backing so both stay readable.
        func drawLabels() {
            for (text, y) in labels {
                let resolved = ctx.resolve(Text(text).font(axisFont).foregroundColor(style.label))
                let sz = resolved.measure(in: CGSize(width: 200, height: 20))
                let rect = CGRect(x: 2, y: y - sz.height / 2 - 0.5, width: sz.width + 6, height: sz.height + 1)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(style.labelBG))
                ctx.draw(resolved, at: CGPoint(x: rect.minX + 3, y: y), anchor: .leading)
            }
        }

        let n = trace.times.count
        guard n > 0, tpp > 0 else { drawLabels(); return }
        let endX = CGFloat((endTime - start) / tpp)
        @inline(__always) func X(_ i: Int) -> CGFloat { CGFloat((Double(trace.times[i]) - start) / tpp) }
        @inline(__always) func level(_ i: Int) -> Double? { Analog.level(trace.values[i], trace: trace, mode: mode) }

        let baseY = Y(min(max(0, lo), hi))
        var stroke = Path(), fill = Path(), bars = Path(), unknown = Path()
        var run: [CGPoint] = []

        func flushRun() {
            guard run.count >= 2, let first = run.first, let last = run.last else { run.removeAll(); return }
            var line = Path()
            line.addLines(run)
            stroke.addPath(line)
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: baseY))
            area.addLine(to: CGPoint(x: first.x, y: baseY))
            area.closeSubpath()
            fill.addPath(area)
            run.removeAll(keepingCapacity: true)
        }

        var k = trace.lastIndex(atOrBefore: start) ?? 0
        while k < n {
            let xs = X(k)
            if xs > w + 2 { break }
            var kEnd = k
            var segStart = xs
            let col = xs.rounded(.down)
            if k + 1 < n && X(k + 1) < col + 1 {
                // Many changes inside this pixel: draw their min–max range as a bar.
                let j = max(k + 1, trace.firstIndex(atOrAfter: start + Double(col + 1) * tpp))
                var mn = Double.infinity, mx = -Double.infinity, sawUnknown = false
                let count = j - k
                let stride = max(1, count / 256)
                var i = k
                while i < j {
                    if let v = level(i) { mn = min(mn, v); mx = max(mx, v) } else { sawUnknown = true }
                    i += stride
                }
                if let v = level(j - 1) { mn = min(mn, v); mx = max(mx, v) }
                if mn.isFinite {
                    bars.move(to: CGPoint(x: col + 0.5, y: Y(mx)))
                    bars.addLine(to: CGPoint(x: col + 0.5, y: Y(mn)))
                }
                if sawUnknown { unknown.addRect(CGRect(x: col, y: plotTop, width: 1, height: plotBot - plotTop)) }
                kEnd = j - 1
                segStart = col + 1
            }
            let xe = kEnd + 1 < n ? X(kEnd + 1) : max(endX, X(kEnd))
            if let v = level(kEnd) {
                let y = Y(v)
                if interpolation == .step {
                    if let last = run.last { run.append(CGPoint(x: segStart, y: last.y)) }
                    run.append(CGPoint(x: segStart, y: y))
                    if kEnd + 1 >= n { run.append(CGPoint(x: xe, y: y)) }
                } else {
                    run.append(CGPoint(x: segStart, y: y))
                    if kEnd + 1 >= n { run.append(CGPoint(x: xe, y: y)) }
                    else if level(kEnd + 1) == nil { run.append(CGPoint(x: xe, y: y)) }
                }
            } else {
                flushRun()
                let a = max(segStart, -2), b = min(xe, w + 2)
                if b > a { unknown.addRect(CGRect(x: a, y: plotTop, width: b - a, height: plotBot - plotTop)) }
            }
            k = kEnd + 1
        }
        // Carry the last level to the next change (or the right edge) in step mode.
        if interpolation == .step, let last = run.last, k < n {
            run.append(CGPoint(x: X(k), y: last.y))
        } else if interpolation == .linear, let last = run.last, k < n, let v = level(k) {
            run.append(CGPoint(x: X(k), y: Y(v)))
            _ = last
        }
        flushRun()

        ctx.fill(unknown, with: .color(style.x.opacity(0.22)))
        ctx.fill(fill, with: .color(style.color.opacity(0.10)))
        ctx.stroke(stroke, with: .color(style.color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        ctx.stroke(bars, with: .color(style.color), lineWidth: 1)
        drawLabels()
    }
}
