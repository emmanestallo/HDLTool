// Renders the app icon to a 1024×1024 PNG.  Usage: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
            blue: CGFloat(h & 0xFF) / 255, alpha: a)
}

// Squircle background
let inset: CGFloat = 100
let bg = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.45))
ctx.addPath(bgPath)
ctx.setFillColor(rgb(0x1F1F1F))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(0x2A2D33), rgb(0x16181C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: bg.maxY), end: CGPoint(x: 0, y: bg.minY), options: [])

// Grid
ctx.setStrokeColor(rgb(0xFFFFFF, 0.06))
ctx.setLineWidth(4)
for i in 1..<6 {
    let x = bg.minX + CGFloat(i) * bg.width / 6
    ctx.move(to: CGPoint(x: x, y: bg.minY)); ctx.addLine(to: CGPoint(x: x, y: bg.maxY))
}
ctx.strokePath()

let left = bg.minX + 70, right = bg.maxX - 70

// Clock-ish square wave (teal)
let hi1: CGFloat = 640, lo1: CGFloat = 540
var x = left
var high = false
let wave = CGMutablePath()
wave.move(to: CGPoint(x: x, y: lo1))
let step: CGFloat = (right - left) / 8
while x < right - 1 {
    let y = high ? hi1 : lo1
    wave.addLine(to: CGPoint(x: x, y: y))
    x += step
    wave.addLine(to: CGPoint(x: min(x, right), y: y))
    high.toggle()
}
ctx.addPath(wave)
ctx.setStrokeColor(rgb(0x4EC9B0))
ctx.setLineWidth(22)
ctx.setLineJoin(.miter)
ctx.setLineCap(.square)
ctx.strokePath()

// Bus hexagons (blue)
let top: CGFloat = 450, bot: CGFloat = 340, mid = (top + bot) / 2
let cuts: [CGFloat] = [left, left + 230, left + 400, right]
for i in 0..<(cuts.count - 1) {
    let a = cuts[i] + 6, b = cuts[i + 1] - 6, s: CGFloat = 32
    let p = CGMutablePath()
    p.move(to: CGPoint(x: a, y: mid))
    p.addLine(to: CGPoint(x: a + s, y: top))
    p.addLine(to: CGPoint(x: b - s, y: top))
    p.addLine(to: CGPoint(x: b, y: mid))
    p.addLine(to: CGPoint(x: b - s, y: bot))
    p.addLine(to: CGPoint(x: a + s, y: bot))
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(rgb(0x4FC1FF, 0.16))
    ctx.fillPath()
    ctx.addPath(p)
    ctx.setStrokeColor(rgb(0x4FC1FF))
    ctx.setLineWidth(16)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

// Cursor line
ctx.setStrokeColor(rgb(0x3794FF))
ctx.setLineWidth(12)
let cx = left + 520
ctx.move(to: CGPoint(x: cx, y: bg.minY + 120)); ctx.addLine(to: CGPoint(x: cx, y: bg.maxY - 110))
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
