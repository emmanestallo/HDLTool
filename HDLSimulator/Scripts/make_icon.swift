// Renders the app icon to a 1024×1024 PNG.  Usage: swift make_icon.swift out.png
// Same squircle as HDL Viewer / Coder / Tester: code brackets (Coder) above a DUT block (Tester).
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

// Dot grid
ctx.setFillColor(rgb(0xFFFFFF, 0.07))
var gy = bg.minY + 52
while gy < bg.maxY {
    var gx = bg.minX + 52
    while gx < bg.maxX {
        ctx.fillEllipse(in: CGRect(x: gx - 4, y: gy - 4, width: 8, height: 8))
        gx += 64
    }
    gy += 64
}

ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Code brackets </> (top)
ctx.setStrokeColor(rgb(0x4FC1FF))
ctx.setLineWidth(40)
let cy: CGFloat = 690
ctx.move(to: CGPoint(x: 400, y: cy + 90)); ctx.addLine(to: CGPoint(x: 300, y: cy)); ctx.addLine(to: CGPoint(x: 400, y: cy - 90))
ctx.move(to: CGPoint(x: 624, y: cy + 90)); ctx.addLine(to: CGPoint(x: 724, y: cy)); ctx.addLine(to: CGPoint(x: 624, y: cy - 90))
ctx.strokePath()
ctx.setStrokeColor(rgb(0xC586C0))
ctx.move(to: CGPoint(x: 550, y: cy + 110)); ctx.addLine(to: CGPoint(x: 474, y: cy - 110))
ctx.strokePath()

// DUT block with pins (bottom)
let box = CGRect(x: 372, y: 210, width: 280, height: 250)
ctx.setStrokeColor(rgb(0x75BEFF))
ctx.setLineWidth(18)
for i in 0..<3 {
    let y = box.minY + 60 + CGFloat(i) * 65
    ctx.move(to: CGPoint(x: box.minX - 90, y: y)); ctx.addLine(to: CGPoint(x: box.minX, y: y))
}
ctx.strokePath()
ctx.setStrokeColor(rgb(0xEE9D28))
for i in 0..<2 {
    let y = box.minY + 92 + CGFloat(i) * 65
    ctx.move(to: CGPoint(x: box.maxX, y: y)); ctx.addLine(to: CGPoint(x: box.maxX + 90, y: y))
}
ctx.strokePath()
let boxPath = CGPath(roundedRect: box, cornerWidth: 30, cornerHeight: 30, transform: nil)
ctx.addPath(boxPath)
ctx.setFillColor(rgb(0x252526))
ctx.fillPath()
ctx.addPath(boxPath)
ctx.setStrokeColor(rgb(0x0078D4))
ctx.setLineWidth(16)
ctx.strokePath()
// Green "run" triangle inside the block
ctx.setFillColor(rgb(0x16C47F))
ctx.move(to: CGPoint(x: box.midX - 45, y: box.midY + 60))
ctx.addLine(to: CGPoint(x: box.midX + 65, y: box.midY))
ctx.addLine(to: CGPoint(x: box.midX - 45, y: box.midY - 60))
ctx.closePath()
ctx.fillPath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
