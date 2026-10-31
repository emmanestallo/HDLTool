import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Prefixes of drag payloads from the sidebar.
let dutDragPrefix = "hdltester-dut:"
let sourceDragPrefix = "hdltester-source:"

struct TestCanvasView: View {
    let doc: TestDocument
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @ViewState private var dropTarget = false
    @ViewState private var zoomAtGestureStart: Double?

    var body: some View {
        let zoom = doc.zoom
        let gen = model.generated(for: doc)
        let badPins = Set(gen.problems.filter { $0.severity == .error }.compactMap { p in
            p.instance.map { "\($0.uuidString).\(p.pin ?? "")" }
        })
        GeometryReader { geo in
            let size = canvasSize(viewport: geo.size, zoom: zoom)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    GridDots(color: theme.canvasDot)
                        .frame(width: size.width, height: size.height)
                    WireLayer(doc: doc)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                    ForEach(doc.state.instances) { inst in
                        if inst.isSource {
                            SourceBlockView(doc: doc, inst: inst, zoom: zoom, bad: badPins.contains("\(inst.id.uuidString).out"))
                        } else {
                            BlockView(doc: doc, inst: inst, zoom: zoom, badPins: badPins)
                        }
                    }
                    PendingWireLayer(doc: doc)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
                .contentShape(Rectangle())
                .coordinateSpace(name: "canvas")
                .onTapGesture(coordinateSpace: .named("canvas")) { loc in
                    let p = CGPoint(x: loc.x / zoom, y: loc.y / zoom)
                    if let w = PinGeo.wire(at: p, in: doc.state, tolerance: 6 / min(zoom, 1)) {
                        doc.selection = .wire(w)
                    } else {
                        doc.selection = nil
                    }
                }
                .onDrop(of: [.utf8PlainText, .plainText, .fileURL], isTargeted: $dropTarget) { providers, loc in
                    handleDrop(providers, at: CGPoint(x: loc.x / zoom, y: loc.y / zoom))
                }
            }
            .scrollIndicators(.automatic)
        }
        .background(theme.editor)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { v in
                    if zoomAtGestureStart == nil { zoomAtGestureStart = doc.zoom }
                    doc.zoom = min(2, max(0.4, (zoomAtGestureStart ?? 1) * v.magnification))
                }
                .onEnded { _ in zoomAtGestureStart = nil }
        )
        .overlay { if doc.state.duts.isEmpty { emptyHint.allowsHitTesting(model.library.files.isEmpty) } }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.focusBorder, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) { addSourceMenu.padding(12) }
        .overlay(alignment: .bottomTrailing) { zoomControls.padding(12) }
    }

    private func canvasSize(viewport: CGSize, zoom: Double) -> CGSize {
        var w = viewport.width / zoom, h = viewport.height / zoom
        for inst in doc.state.instances {
            w = max(w, inst.x + 700)
            h = max(h, inst.y + 500)
        }
        return CGSize(width: max(w, 1200), height: max(h, 800))
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.dashed.inset.filled")
                .font(.system(size: 34, weight: .ultraLight))
            if model.library.files.isEmpty {
                Text("Open a Verilog file to see its modules under Available DUTs")
                    .font(.system(size: 14))
                Button("Open Verilog File…  ⌘O") { model.showOpenPanel() }
                    .buttonStyle(LinkButtonStyle(color: theme.accent))
            } else {
                Text("Drag a DUT from Available DUTs and drop it here")
                    .font(.system(size: 14))
                Text("Double-clicking a module also adds it. Drag from a pin's dot to another pin to wire them.")
                    .font(.system(size: 12))
            }
        }
        .foregroundStyle(theme.dimFG)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        )
        .padding(40)
    }

    private var addSourceMenu: some View {
        Menu {
            ForEach(SourcePreset.allCases) { p in
                Button(p.title) { model.placeSource(p, in: doc) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("Add Source").font(.system(size: 12))
            }
            .foregroundStyle(theme.fg)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a clock, reset or other source that can be wired to several DUT inputs")
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            IconButton(icon: "minus", help: "Zoom Out (⌘-)", size: 11) { doc.zoom = max(0.4, doc.zoom / 1.25) }
            Button { doc.zoom = 1 } label: {
                Text("\(Int((doc.zoom * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.fg)
                    .frame(width: 44)
            }
            .buttonStyle(.plain)
            .help("Actual Size (⌘0)")
            IconButton(icon: "plus", help: "Zoom In (⌘=)", size: 11) { doc.zoom = min(2, doc.zoom * 1.25) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
    }

    private func handleDrop(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in AppModel.shared.open([url]) }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                handled = true
                let docID = doc.id
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    Task { @MainActor in
                        let model = AppModel.shared
                        guard let doc = model.tests.first(where: { $0.id == docID }) else { return }
                        if s.hasPrefix(dutDragPrefix), let m = model.library.module(id: String(s.dropFirst(dutDragPrefix.count))) {
                            model.place(m, in: doc, at: point)
                        } else if s.hasPrefix(sourceDragPrefix), let preset = SourcePreset(rawValue: String(s.dropFirst(sourceDragPrefix.count))) {
                            model.placeSource(preset, in: doc, at: point)
                        }
                    }
                }
            }
        }
        return handled
    }
}

/// Dot grid background.
struct GridDots: View {
    let color: Color
    var spacing: CGFloat = 20

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var y = spacing
            while y < size.height {
                var x = spacing
                while x < size.width {
                    path.addRect(CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    x += spacing
                }
                y += spacing
            }
            ctx.fill(path, with: .color(color))
        }
    }
}

// MARK: - Pin geometry (canvas coordinates)

enum PinGeo {
    struct Pin {
        let ref: PinRef
        let dir: PortDir
        let isSource: Bool
        let point: CGPoint
        let rowRect: CGRect
        let width: Int?
    }

    static func pins(of inst: DUTInstance, offset: CGSize = .zero) -> [Pin] {
        let ox = inst.x + offset.width, oy = inst.y + offset.height
        if inst.isSource {
            let L = SourceLayout(inst: inst)
            let pt = CGPoint(x: ox + L.boxW + SourceLayout.stub, y: oy + SourceLayout.pinY)
            return [Pin(ref: PinRef(instance: inst.id, pin: "out"), dir: .output, isSource: true, point: pt,
                        rowRect: CGRect(x: ox, y: oy, width: L.boxW + SourceLayout.stub + 12, height: L.boxH), width: inst.sourceWidth)]
        }
        let env = inst.paramValues()
        let L = BlockLayout(inst: inst, env: env)
        var out: [Pin] = []
        func y(_ i: Int) -> CGFloat { oy + BlockLayout.rowY(i) - BlockLayout.labelH }
        for (i, p) in L.left.enumerated() where p.unsupported == nil {
            let pt = CGPoint(x: ox - BlockLayout.stub, y: y(i))
            out.append(Pin(ref: PinRef(instance: inst.id, pin: p.name), dir: .input, isSource: false, point: pt,
                           rowRect: CGRect(x: ox - 140, y: pt.y - BlockLayout.rowH / 2, width: 140 + L.boxW / 2, height: BlockLayout.rowH),
                           width: inst.resolve(p, env: env)?.width))
        }
        for (i, p) in L.right.enumerated() where p.unsupported == nil && p.dir == .output {
            let pt = CGPoint(x: ox + L.boxW + BlockLayout.stub, y: y(i))
            out.append(Pin(ref: PinRef(instance: inst.id, pin: p.name), dir: .output, isSource: false, point: pt,
                           rowRect: CGRect(x: ox + L.boxW / 2, y: pt.y - BlockLayout.rowH / 2, width: L.boxW / 2 + BlockLayout.stub + 40, height: BlockLayout.rowH),
                           width: inst.resolve(p, env: env)?.width))
        }
        return out
    }

    static func allPins(_ state: TestState, dragging: DragState?) -> [PinRef: Pin] {
        var d: [PinRef: Pin] = [:]
        for inst in state.instances {
            let off = dragging?.id == inst.id ? dragging!.offset : .zero
            for p in pins(of: inst, offset: off) { d[p.ref] = p }
        }
        return d
    }

    /// The pin a wire being drawn would connect to.
    static func target(_ state: TestState, at point: CGPoint, wantOutput: Bool, excluding: PinRef) -> PinRef? {
        let candidates = allPins(state, dragging: nil).values.filter {
            $0.ref != excluding && (wantOutput ? $0.dir == .output : $0.dir == .input)
        }
        if let hit = candidates.first(where: { $0.rowRect.contains(point) }) { return hit.ref }
        let near = candidates.min { dist($0.point, point) < dist($1.point, point) }
        if let near, dist(near.point, point) < 26 { return near.ref }
        return nil
    }

    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Right-angle routing

    /// How far a wire runs straight out of a pin before its first bend.
    static let lead: CGFloat = 14
    static let laneGap: CGFloat = 8

    /// The x of a wire's vertical run, snapped to the grid so wires from one driver share it.
    static func trunkX(_ a: CGPoint, _ b: CGPoint) -> CGFloat? {
        guard b.x - a.x >= 2 * lead else { return nil }
        let mid = ((a.x + b.x) / 2 / 10).rounded() * 10
        return min(max(mid, a.x + lead), b.x - lead)
    }

    /// Corner points of a wire from output `a` to input `b`, using only horizontal and vertical runs.
    static func route(_ a: CGPoint, _ b: CGPoint, trunk: CGFloat? = nil) -> [CGPoint] {
        if let x = trunk ?? trunkX(a, b) {
            if abs(a.y - b.y) < 0.5 { return [a, b] }
            return [a, CGPoint(x: x, y: a.y), CGPoint(x: x, y: b.y), b]
        }
        // The input is left of the output: leave right, cross over, come in from the left.
        let x1 = a.x + lead, x2 = b.x - lead
        let my = abs(a.y - b.y) >= 50 ? ((a.y + b.y) / 2 / 10).rounded() * 10 : max(a.y, b.y) + 40
        return [a, CGPoint(x: x1, y: a.y), CGPoint(x: x1, y: my), CGPoint(x: x2, y: my), CGPoint(x: x2, y: b.y), b]
    }

    static func path(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for q in pts.dropFirst() { p.addLine(to: q) }
        return p
    }

    struct Routed {
        let wire: Wire
        let points: [CGPoint]
        let width: Int?
        /// Where this wire branches off a run it shares with other wires from the same driver.
        let junctions: [CGPoint]
    }

    /// Routes every wire. Wires from different drivers that would share a vertical run get their own lanes.
    /// Areas wires should stay out of: every block, with a margin (smaller than a pin stub, so pin dots stay outside).
    static func obstacles(_ state: TestState, dragging: DragState?) -> [CGRect] {
        state.instances.map { inst in
            let off = dragging?.id == inst.id ? dragging!.offset : .zero
            let ox = inst.x + off.width, oy = inst.y + off.height
            if inst.isSource {
                let L = SourceLayout(inst: inst)
                return CGRect(x: ox - 8, y: oy - 8, width: L.boxW + 24, height: L.boxH + 16)
            }
            let L = BlockLayout(inst: inst, env: inst.paramValues())
            return CGRect(x: ox - 16, y: oy - BlockLayout.labelH - 4, width: L.boxW + 32, height: L.boxH + BlockLayout.labelH + 12)
        }
    }

    private static func crossings(_ pts: [CGPoint], _ rects: [CGRect]) -> Int {
        var n = 0
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let seg = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            for r in rects {
                if a.y == b.y {
                    if a.y > r.minY && a.y < r.maxY && seg.maxX > r.minX && seg.minX < r.maxX { n += 1 }
                } else if a.x > r.minX && a.x < r.maxX && seg.maxY > r.minY && seg.minY < r.maxY { n += 1 }
            }
        }
        return n
    }

    /// Drops repeated points and points in the middle of a straight run.
    private static func simplify(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts {
            if let l = out.last, abs(l.x - p.x) < 0.01 && abs(l.y - p.y) < 0.01 { continue }
            if out.count >= 2 {
                let a = out[out.count - 2], b = out[out.count - 1]
                if (abs(a.x - b.x) < 0.01 && abs(b.x - p.x) < 0.01) || (abs(a.y - b.y) < 0.01 && abs(b.y - p.y) < 0.01) {
                    out[out.count - 1] = p
                    continue
                }
            }
            out.append(p)
        }
        return out
    }

    /// Picks the shortest right-angle route from `a` to `b` that crosses the fewest blocks.
    static func smartRoute(_ a: CGPoint, _ b: CGPoint, obstacles rects: [CGRect]) -> [CGPoint] {
        let snap = { (v: CGFloat) in (v / 10).rounded() * 10 }
        var best: [CGPoint] = route(a, b)
        var bestCost = CGFloat.infinity
        func consider(_ raw: [CGPoint]) {
            let pts = simplify(raw)
            guard pts.count >= 2 else { return }
            var len: CGFloat = 0
            for i in 1..<pts.count { len += abs(pts[i].x - pts[i - 1].x) + abs(pts[i].y - pts[i - 1].y) }
            let cost = CGFloat(crossings(pts, rects)) * 10_000 + len + CGFloat(pts.count - 2) * 30
            if cost < bestCost { bestCost = cost; best = pts }
        }
        let x0 = a.x + lead, x3 = b.x - lead
        // One vertical run between the two pins
        if x3 >= x0 {
            var xs: Set<CGFloat> = [min(max(snap((a.x + b.x) / 2), x0), x3)]
            for r in rects { xs.insert(snap(r.minX - 12)); xs.insert(snap(r.maxX + 12)) }
            // Sorted: Set order is random, and equal-cost routes must always resolve the same way.
            for x in xs.sorted() where x >= x0 && x <= x3 {
                consider([a, CGPoint(x: x, y: a.y), CGPoint(x: x, y: b.y), b])
            }
        }
        // Around blocks: out, across a free row, and back in
        if bestCost >= 10_000 || x3 < x0 {
            let x1s = ([x0] + rects.map { snap($0.maxX + 12) }.filter { $0 > x0 }.sorted()).prefix(4)
            let x2s = ([x3] + rects.map { snap($0.minX - 12) }.filter { $0 < x3 }.sorted(by: >)).prefix(4)
            var ys: Set<CGFloat> = [a.y, b.y, snap((a.y + b.y) / 2)]
            for r in rects { ys.insert(snap(r.minY - 10)); ys.insert(snap(r.maxY + 10)) }
            for x1 in x1s {
                for x2 in x2s {
                    for y in ys.sorted() {
                        consider([a, CGPoint(x: x1, y: a.y), CGPoint(x: x1, y: y), CGPoint(x: x2, y: y), CGPoint(x: x2, y: b.y), b])
                    }
                }
            }
        }
        return best
    }

    /// Routes every wire around the blocks. Different drivers sharing a vertical run get their own lanes.
    static func routeAll(_ state: TestState, pins: [PinRef: Pin], dragging: DragState? = nil) -> [Routed] {
        let rects = obstacles(state, dragging: dragging)
        var items: [(w: Wire, pts: [CGPoint], width: Int?)] = state.wires.compactMap { w in
            guard let a = pins[w.from], let b = pins[w.to] else { return nil }
            return (w, smartRoute(a.point, b.point, obstacles: rects), a.width)
        }
        // Lanes: when wires from different drivers would run along the same line, spread them apart.
        for vertical in [true, false] {
            var groups: [CGFloat: [(item: Int, seg: Int)]] = [:]
            for (i, it) in items.enumerated() where it.pts.count >= 4 {
                for k in 1...(it.pts.count - 3) {
                    let p = it.pts[k], q = it.pts[k + 1]
                    if vertical ? abs(p.x - q.x) < 0.01 : abs(p.y - q.y) < 0.01 {
                        groups[vertical ? p.x : p.y, default: []].append((i, k))
                    }
                }
            }
            for (_, segs) in groups {
                var drivers: [(PinRef, CGFloat)] = []
                for (i, _) in segs where !drivers.contains(where: { $0.0 == items[i].w.from }) {
                    drivers.append((items[i].w.from, vertical ? items[i].pts[0].y : items[i].pts[0].x))
                }
                guard drivers.count > 1 else { continue }
                drivers.sort { $0.1 < $1.1 }
                for (i, k) in segs {
                    let n = drivers.firstIndex { $0.0 == items[i].w.from } ?? 0
                    let d = (CGFloat(n) - CGFloat(drivers.count - 1) / 2) * laneGap
                    if vertical { items[i].pts[k].x += d; items[i].pts[k + 1].x += d }
                    else { items[i].pts[k].y += d; items[i].pts[k + 1].y += d }
                }
            }
        }
        // Junction dots where wires from one driver split off a shared vertical run.
        var junctions: [UUID: [CGPoint]] = [:]
        let trunks = Dictionary(grouping: items.filter { $0.pts.count == 4 }, by: { "\($0.w.from.instance).\($0.w.from.pin)@\($0.pts[1].x)" })
        for (_, group) in trunks where group.count > 1 {
            let ay = group[0].pts[0].y
            let ys = group.map { $0.pts[2].y } + [ay]
            let lo = ys.min()!, hi = ys.max()!
            for it in group where it.pts[2].y > lo + 0.5 && it.pts[2].y < hi - 0.5 {
                junctions[it.w.id, default: []].append(it.pts[2])
            }
            if ay > lo + 0.5 && ay < hi - 0.5 {
                junctions[group[0].w.id, default: []].append(group[0].pts[1])
            }
        }
        return items.map { Routed(wire: $0.w, points: $0.pts, width: $0.width, junctions: junctions[$0.w.id] ?? []) }
    }

    /// The wire under a click, if any.
    static func wire(at p: CGPoint, in state: TestState, tolerance: CGFloat) -> UUID? {
        var best: (UUID, CGFloat)?
        for r in routeAll(state, pins: allPins(state, dragging: nil)) {
            let w = r.wire
            let pts = r.points
            for i in 1..<pts.count {
                let d = segmentDistance(p, pts[i - 1], pts[i])
                if d < tolerance, d < (best?.1 ?? .infinity) { best = (w.id, d) }
            }
        }
        return best?.0
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

extension TestDocument {
    func updatePendingWire(start: PinRef, startIsOutput: Bool, point: CGPoint) {
        let target = PinGeo.target(state, at: point, wantOutput: !startIsOutput, excluding: start)
        pendingWire = PendingWire(start: start, startIsOutput: startIsOutput, point: point, target: target)
    }

    func finishPendingWire() {
        guard let p = pendingWire else { return }
        pendingWire = nil
        guard let t = p.target else { return }
        if p.startIsOutput { connect(from: p.start, to: t) } else { connect(from: t, to: p.start) }
    }
}

// MARK: - Wires

struct WireLayer: View {
    let doc: TestDocument
    @Environment(\.theme) private var theme

    var body: some View {
        let pins = PinGeo.allPins(doc.state, dragging: doc.dragging)
        let selectedWire: UUID? = { if case .wire(let w)? = doc.selection { return w }; return nil }()
        let selInst = doc.selection?.instanceID
        let items: [(Path, [CGPoint], CGPoint, CGPoint, Color, CGFloat, Bool)] = PinGeo.routeAll(doc.state, pins: pins, dragging: doc.dragging).map { r in
            let w = r.wire
            let hot = w.id == selectedWire || w.from.instance == selInst || w.to.instance == selInst
            return (PinGeo.path(r.points), r.junctions, r.points.first!, r.points.last!, wireColor(w.from),
                    (r.width ?? 1) > 1 ? 3 : 1.6, hot)
        }
        let focus = theme.focusBorder
        let joint = StrokeStyle(lineWidth: 1, lineCap: .square, lineJoin: .miter)
        Canvas { ctx, _ in
            for (path, _, _, _, color, width, hot) in items where !hot {
                var st = joint; st.lineWidth = width
                ctx.stroke(path, with: .color(color.opacity(0.85)), style: st)
            }
            for (path, _, _, _, color, width, hot) in items where hot {
                var halo = joint; halo.lineWidth = width + 5
                var st = joint; st.lineWidth = width + 0.5
                ctx.stroke(path, with: .color(focus.opacity(0.35)), style: halo)
                ctx.stroke(path, with: .color(color), style: st)
            }
            for (_, junctions, a, b, color, width, _) in items {
                ctx.fill(Path(ellipseIn: CGRect(x: a.x - 3.5, y: a.y - 3.5, width: 7, height: 7)), with: .color(color))
                ctx.fill(Path(ellipseIn: CGRect(x: b.x - 3.5, y: b.y - 3.5, width: 7, height: 7)), with: .color(color))
                let r = width > 2 ? 4.0 : 3.0
                for j in junctions {
                    ctx.fill(Path(ellipseIn: CGRect(x: j.x - r, y: j.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
                }
            }
        }
    }

    private func wireColor(_ from: PinRef) -> Color {
        if let inst = doc.state.instance(from.instance), inst.isSource {
            return theme.stimColor(inst.stimulus("out").kind)
        }
        return theme.dirColor(.output)
    }
}

/// The wire following the mouse while connecting.
struct PendingWireLayer: View {
    let doc: TestDocument
    @Environment(\.theme) private var theme

    var body: some View {
        let pw = doc.pendingWire
        let pins = PinGeo.allPins(doc.state, dragging: nil)
        let focus = theme.focusBorder
        Canvas { ctx, _ in
            guard let pw, let start = pins[pw.start]?.point else { return }
            let end = pw.target.flatMap { pins[$0]?.point } ?? pw.point
            let rects = PinGeo.obstacles(doc.state, dragging: nil)
            let path = PinGeo.path(pw.startIsOutput ? PinGeo.smartRoute(start, end, obstacles: rects) : PinGeo.smartRoute(end, start, obstacles: rects))
            ctx.stroke(path, with: .color(focus), style: StrokeStyle(lineWidth: 2, lineJoin: .miter, dash: pw.target == nil ? [6, 4] : []))
            if let t = pw.target, let tp = pins[t] {
                ctx.stroke(Path(ellipseIn: CGRect(x: tp.point.x - 8, y: tp.point.y - 8, width: 16, height: 16)), with: .color(focus), lineWidth: 2)
                ctx.fill(Path(tp.rowRect.insetBy(dx: 0, dy: 1)), with: .color(focus.opacity(0.12)))
            }
        }
    }
}

/// Drag from this dot to another pin to make a wire.
struct ConnectorDot: View {
    let doc: TestDocument
    let ref: PinRef
    let isOutput: Bool
    let color: Color
    let zoom: Double
    let connected: Bool
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let active = doc.pendingWire?.start == ref || doc.pendingWire?.target == ref
        ZStack {
            Circle()
                .fill(connected || hovering || active ? color : theme.editor)
                .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                .frame(width: hovering || active ? 11 : 8, height: hovering || active ? 11 : 8)
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle())
        .onHover { h in
            hovering = h
            if h { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                .onChanged { v in
                    doc.updatePendingWire(start: ref, startIsOutput: isOutput,
                                          point: CGPoint(x: v.location.x / zoom, y: v.location.y / zoom))
                }
                .onEnded { _ in doc.finishPendingWire() }
        )
        .help(isOutput ? "Drag to an input pin to wire it" : "Drag to an output or source to wire this input")
    }
}

/// Moves a block with the mouse and commits the new position on release.
struct MoveOnDrag: ViewModifier {
    let doc: TestDocument
    let inst: DUTInstance
    let zoom: Double
    let minX: Double
    let minY: Double
    @Environment(\.theme) private var theme
    @ViewState private var drag: CGSize = .zero
    @ViewState private var dragging = false

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(dragging ? 0.35 : (theme.isDark ? 0.18 : 0.06)), radius: dragging ? 10 : 3, y: dragging ? 4 : 1)
            .offset(x: drag.width, y: drag.height)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        dragging = true
                        drag = CGSize(width: v.translation.width / zoom, height: v.translation.height / zoom)
                        doc.dragging = DragState(id: inst.id, offset: drag)
                        if doc.selection?.instanceID != inst.id { doc.selection = .instance(inst.id) }
                    }
                    .onEnded { _ in
                        let snap = { (v: Double) in (v / 10).rounded() * 10 }
                        let nx = max(minX, snap(inst.x + drag.width)), ny = max(minY, snap(inst.y + drag.height))
                        drag = .zero
                        dragging = false
                        doc.dragging = nil
                        if let i = doc.index(of: inst.id), nx != inst.x || ny != inst.y {
                            doc.edit { $0.instances[i].x = nx; $0.instances[i].y = ny }
                        }
                    }
            )
    }
}

// MARK: - DUT block

struct BlockLayout {
    static let rowH: CGFloat = 22
    static let headerH: CGFloat = 30
    static let stub: CGFloat = 30
    static let labelH: CGFloat = 18
    static let pad: CGFloat = 10

    let left: [PortInfo]
    let right: [PortInfo]
    let rangeLabels: [String: String]
    let leftW: CGFloat
    let rightW: CGFloat
    let boxW: CGFloat
    let boxH: CGFloat

    init(inst: DUTInstance, env: [String: Int]) {
        left = inst.inputs
        right = inst.outputs + inst.inouts
        var labels: [String: String] = [:]
        for p in inst.ports { labels[p.name] = inst.rangeLabel(p, env: env) }
        rangeLabels = labels
        let cw = Metrics.monoCharW
        func textW(_ p: PortInfo) -> CGFloat {
            let r = labels[p.name] ?? ""
            // A range that depends on parameters gets room for up to "[999:0]" whatever its value now,
            // so editing a parameter doesn't resize the box (which would move its pins and the wires).
            let dependsOnParams = p.ranges.contains { Int($0.msb.trimmingCharacters(in: .whitespaces)) == nil
                || Int($0.lsb.trimmingCharacters(in: .whitespaces)) == nil }
            // While a value is half typed (e.g. 8'), the label falls back to the declared text; don't size for that either.
            let chars = !dependsOnParams ? r.count : (inst.resolve(p, env: env) == nil ? 7 : max(r.count, 7))
            return CGFloat(p.name.count) * cw + (chars == 0 ? 0 : CGFloat(chars + 1) * cw * 0.85)
        }
        let lw = left.map(textW).max() ?? 0
        let rw = right.map(textW).max() ?? 0
        let titleW = CGFloat(inst.moduleName.count) * 7.6 + 50
        boxW = max(150, max(titleW, Self.pad * 2 + lw + rw + 30)).rounded(.up)
        let rows = max(left.count, right.count, 1)
        boxH = Self.headerH + CGFloat(rows) * Self.rowH + 8
        leftW = Self.stub + 12
        rightW = Self.stub + (inst.logged.isEmpty ? 12 : 38)
    }

    var totalW: CGFloat { leftW + boxW + rightW }
    var totalH: CGFloat { Self.labelH + boxH }
    func rowY(_ i: Int) -> CGFloat { Self.rowY(i) }
    static func rowY(_ i: Int) -> CGFloat { labelH + headerH + CGFloat(i) * rowH + rowH / 2 + 4 }
}

struct BlockView: View {
    let doc: TestDocument
    let inst: DUTInstance
    let zoom: Double
    let badPins: Set<String>
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var instSelected: Bool { doc.selection?.instanceID == inst.id }
    private var selectedPin: String? {
        if case .pin(let id, let p)? = doc.selection, id == inst.id { return p }
        return nil
    }

    var body: some View {
        let env = inst.paramValues()
        let drivers = Dictionary(inst.inputs.compactMap { p -> (String, PinRef)? in
            doc.state.wire(to: PinRef(instance: inst.id, pin: p.name)).map { (p.name, $0.from) }
        }, uniquingKeysWith: { a, _ in a })
        let L = BlockLayout(inst: inst, env: env)
        ZStack(alignment: .topLeading) {
            stubs(L, env: env, drivers: drivers)
            Text(inst.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(instSelected ? theme.fg : theme.dimFG)
                .lineLimit(1)
                .frame(width: L.boxW, alignment: .leading)
                .offset(x: L.leftW + 2, y: 0)
            box(L)
                .offset(x: L.leftW, y: BlockLayout.labelH)
            ForEach(Array(L.left.enumerated()), id: \.element.name) { i, p in
                inputRow(p, row: i, L, driver: drivers[p.name])
            }
            ForEach(Array(L.right.enumerated()), id: \.element.name) { i, p in
                outputRow(p, row: i, L)
            }
            // Connector dots, drawn last so they sit on top
            ForEach(Array(L.left.enumerated()), id: \.element.name) { i, p in
                if p.unsupported == nil {
                    ConnectorDot(doc: doc, ref: PinRef(instance: inst.id, pin: p.name), isOutput: false,
                                 color: stubColor(p, driver: drivers[p.name]), zoom: zoom, connected: drivers[p.name] != nil)
                        .offset(x: L.leftW - BlockLayout.stub - 9, y: L.rowY(i) - 9)
                }
            }
            ForEach(Array(L.right.enumerated()), id: \.element.name) { i, p in
                if p.unsupported == nil && p.dir == .output {
                    let ref = PinRef(instance: inst.id, pin: p.name)
                    ConnectorDot(doc: doc, ref: ref, isOutput: true, color: theme.dirColor(.output), zoom: zoom,
                                 connected: !doc.state.wires(from: ref).isEmpty)
                        .offset(x: L.leftW + L.boxW + BlockLayout.stub - 9, y: L.rowY(i) - 9)
                }
            }
        }
        .frame(width: L.totalW, height: L.totalH, alignment: .topLeading)
        .offset(x: inst.x - L.leftW, y: inst.y - BlockLayout.labelH)
        .modifier(MoveOnDrag(doc: doc, inst: inst, zoom: zoom, minX: Double(L.leftW), minY: Double(BlockLayout.labelH + 4)))
    }

    private func stubColor(_ p: PortInfo, driver: PinRef?) -> Color {
        if badPins.contains("\(inst.id.uuidString).\(p.name)") { return theme.error }
        if let d = driver {
            if let src = doc.state.instance(d.instance), src.isSource { return theme.stimColor(src.stimulus("out").kind) }
            return theme.dirColor(.output)
        }
        return theme.pin
    }

    // MARK: Pieces

    private func box(_ L: BlockLayout) -> some View {
        let unsupported = inst.ports.contains { $0.unsupported != nil }
        let missing = !FileManager.default.fileExists(atPath: inst.filePath)
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.dirColor(.output))
                Text(inst.moduleName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if missing {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(theme.error)
                        .help("Source file not found: \(inst.filePath)")
                } else if unsupported {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(theme.warning)
                        .help("Some ports cannot be driven and are left unconnected")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: BlockLayout.headerH)
            .background(theme.blockHeader)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.blockBorder.opacity(0.6)).frame(height: 1) }
            Spacer(minLength: 0)
        }
        .frame(width: L.boxW, height: L.boxH)
        .background(theme.blockBG)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(instSelected ? theme.focusBorder : theme.blockBorder, lineWidth: instSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { doc.selection = .instance(inst.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { AppModel.shared.descend(into: inst, in: doc) })
        .help("\(inst.moduleName) — double-click to descend and edit \(URL(fileURLWithPath: inst.filePath).lastPathComponent)")
        .contextMenu { blockMenu }
    }

    @ViewBuilder private var blockMenu: some View {
        Button("Descend into \(inst.moduleName) (Edit Source)") { AppModel.shared.descend(into: inst, in: doc) }
        Divider()
        let unwired = inst.inputs.filter { $0.unsupported == nil && doc.state.wire(to: PinRef(instance: inst.id, pin: $0.name)) == nil }
        Button("Add Sources for Unwired Inputs (\(unwired.count))") { doc.addSourcesForUnwiredInputs(of: inst.id) }
            .disabled(unwired.isEmpty)
        Divider()
        Button("Duplicate") { doc.duplicateInstance(inst.id) }
        Button("Remove from Test") { doc.removeInstance(inst.id) }
        if doc.state.wires.contains(where: { $0.from.instance == inst.id || $0.to.instance == inst.id }) {
            Button("Remove All Its Wires") {
                doc.edit { $0.wires.removeAll { $0.from.instance == inst.id || $0.to.instance == inst.id } }
            }
        }
        Divider()
        Button("Reveal Source in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: inst.filePath)])
        }
    }

    /// Pin stubs, drawn in one pass.
    private func stubs(_ L: BlockLayout, env: [String: Int], drivers: [String: PinRef]) -> some View {
        let pinColor = theme.pin
        // Bus slash sits near the left end of each stub, with its width just right of it, clear of the box.
        let rows: [(y: CGFloat, x0: CGFloat, x1: CGFloat, bus: Int?, color: Color)] =
            L.left.enumerated().map { i, p in
                let w = inst.resolve(p, env: env)?.width
                return (L.rowY(i), L.leftW - BlockLayout.stub, L.leftW, (w ?? 2) > 1 ? w : nil, stubColor(p, driver: drivers[p.name]))
            } + L.right.enumerated().map { i, p in
                let w = inst.resolve(p, env: env)?.width
                return (L.rowY(i), L.leftW + L.boxW, L.leftW + L.boxW + BlockLayout.stub, (w ?? 2) > 1 ? w : nil,
                        p.dir == .bidir ? theme.dirColor(.bidir) : pinColor)
            }
        return Canvas { ctx, _ in
            for r in rows {
                var line = Path()
                line.move(to: CGPoint(x: r.x0, y: r.y))
                line.addLine(to: CGPoint(x: r.x1, y: r.y))
                ctx.stroke(line, with: .color(r.color.opacity(0.9)), lineWidth: r.bus != nil ? 3 : 1.5)
                if let w = r.bus {
                    let mx = r.x0 + 10
                    var slash = Path()
                    slash.move(to: CGPoint(x: mx - 3.5, y: r.y + 5))
                    slash.addLine(to: CGPoint(x: mx + 3.5, y: r.y - 5))
                    ctx.stroke(slash, with: .color(r.color), lineWidth: 1.2)
                    ctx.draw(Text("\(w)").font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundColor(r.color),
                             at: CGPoint(x: mx + 4, y: r.y - 7), anchor: .leading)
                }
            }
        }
        .frame(width: L.totalW, height: L.totalH)
        .allowsHitTesting(false)
    }

    private func pinLabel(_ p: PortInfo, _ L: BlockLayout) -> some View {
        HStack(spacing: 4) {
            Text(p.name).foregroundStyle(p.unsupported != nil ? theme.dimFG : theme.fg)
                .strikethrough(p.unsupported != nil)
            if let r = L.rangeLabels[p.name], !r.isEmpty {
                Text(r).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.dimFG)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }

    private func inputRow(_ p: PortInfo, row: Int, _ L: BlockLayout, driver: PinRef?) -> some View {
        let sel = selectedPin == p.name
        let rowW = L.leftW + L.boxW / 2
        return ZStack(alignment: .topLeading) {
            if sel {
                Rectangle().fill(theme.focusBorder.opacity(0.16))
                    .frame(width: L.boxW - 2, height: BlockLayout.rowH)
                    .offset(x: L.leftW + 1)
            }
            pinLabel(p, L)
                .frame(height: BlockLayout.rowH)
                .offset(x: L.leftW + BlockLayout.pad)
        }
        .frame(width: rowW, height: BlockLayout.rowH, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { doc.selection = .pin(inst.id, p.name) }
        .contextMenu { inputMenu(p, driver: driver) }
        .help(pinHelp(p, driver: driver))
        .offset(y: L.rowY(row) - BlockLayout.rowH / 2)
    }

    private func outputRow(_ p: PortInfo, row: Int, _ L: BlockLayout) -> some View {
        let sel = selectedPin == p.name
        let logged = inst.logged.contains(p.name)
        let x0 = L.leftW + L.boxW / 2
        let rowW = L.totalW - x0
        return ZStack(alignment: .topTrailing) {
            if sel {
                Rectangle().fill(theme.focusBorder.opacity(0.16))
                    .frame(width: L.boxW - 2, height: BlockLayout.rowH)
                    .offset(x: -(L.rightW + 1))
            }
            pinLabel(p, L)
                .frame(height: BlockLayout.rowH)
                .offset(x: -(L.rightW + BlockLayout.pad))
            if logged {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .frame(width: 20, height: 16)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.pin.opacity(0.25)))
                    .offset(x: -2, y: (BlockLayout.rowH - 16) / 2)
                    .help("Value changes are printed in the Output panel")
            }
        }
        .frame(width: rowW, height: BlockLayout.rowH, alignment: .topTrailing)
        .contentShape(Rectangle())
        .onTapGesture { doc.selection = .pin(inst.id, p.name) }
        .contextMenu { outputMenu(p) }
        .help(pinHelp(p, driver: nil))
        .offset(x: x0, y: L.rowY(row) - BlockLayout.rowH / 2)
    }

    private func pinHelp(_ p: PortInfo, driver: PinRef?) -> String {
        var s = "\(p.name) — \(p.dir.rawValue)"
        if let d = driver { s += "\nWired from \(doc.state.describe(d))" }
        else if p.dir == .input && p.unsupported == nil { s += "\nNot wired: drag from its dot to a source or a DUT output" }
        if let u = p.unsupported { s += "\nNot connected: \(u)" }
        return s
    }

    @ViewBuilder private func inputMenu(_ p: PortInfo, driver: PinRef?) -> some View {
        let ref = PinRef(instance: inst.id, pin: p.name)
        Menu("Wire From") {
            ForEach(doc.state.driverPins, id: \.self) { d in
                Button(doc.state.describe(d)) { doc.connect(from: d, to: ref) }
            }
        }
        .disabled(doc.state.driverPins.isEmpty)
        Menu("New Source") {
            ForEach(SourcePreset.allCases) { preset in
                Button(preset.title) {
                    if let id = doc.addSource(preset, wiredTo: ref) { doc.selection = .instance(id) }
                }
            }
        }
        if driver != nil {
            Button("Disconnect Wire") { doc.disconnect(input: ref) }
        }
    }

    @ViewBuilder private func outputMenu(_ p: PortInfo) -> some View {
        let logged = inst.logged.contains(p.name)
        let ref = PinRef(instance: inst.id, pin: p.name)
        if p.dir == .output {
            Menu("Wire To") {
                ForEach(doc.state.inputPins, id: \.self) { t in
                    Button(doc.state.describe(t)) { doc.connect(from: ref, to: t) }
                }
            }
            .disabled(doc.state.inputPins.isEmpty)
            if !doc.state.wires(from: ref).isEmpty {
                Button("Remove Its Wires") { doc.edit { $0.wires.removeAll { $0.from == ref } } }
            }
            Divider()
        }
        Button(logged ? "Stop Printing Changes" : "Print Changes in Output") {
            doc.edit { st in
                guard let i = st.instances.firstIndex(where: { $0.id == inst.id }) else { return }
                if logged { st.instances[i].logged.removeAll { $0 == p.name } } else { st.instances[i].logged.append(p.name) }
            }
        }
    }
}

// MARK: - Source block

struct SourceLayout {
    static let headerH: CGFloat = 26
    static let rowH: CGFloat = 26
    static let stub: CGFloat = 30
    static var pinY: CGFloat { headerH + rowH / 2 + 1 }

    let boxW: CGFloat
    var boxH: CGFloat { Self.headerH + Self.rowH + 2 }

    init(inst: DUTInstance) {
        let chip = StimChip.width(inst.stimulus("out"))
        boxW = max(120, max(CGFloat(inst.name.count) * Metrics.monoCharW + 52, chip + 50)).rounded(.up)
    }
}

struct SourceBlockView: View {
    let doc: TestDocument
    let inst: DUTInstance
    let zoom: Double
    let bad: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let L = SourceLayout(inst: inst)
        let stim = inst.stimulus("out")
        let color = bad ? theme.error : theme.stimColor(stim.kind)
        let selected = doc.selection?.instanceID == inst.id
        let w = inst.sourceWidth
        let ref = PinRef(instance: inst.id, pin: "out")
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                var line = Path()
                line.move(to: CGPoint(x: L.boxW, y: SourceLayout.pinY))
                line.addLine(to: CGPoint(x: L.boxW + SourceLayout.stub, y: SourceLayout.pinY))
                ctx.stroke(line, with: .color(color), lineWidth: w > 1 ? 3 : 1.5)
                if w > 1 {
                    let mx = L.boxW + 10
                    var slash = Path()
                    slash.move(to: CGPoint(x: mx - 3.5, y: SourceLayout.pinY + 5))
                    slash.addLine(to: CGPoint(x: mx + 3.5, y: SourceLayout.pinY - 5))
                    ctx.stroke(slash, with: .color(color), lineWidth: 1.2)
                    ctx.draw(Text("\(w)").font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundColor(color),
                             at: CGPoint(x: mx + 4, y: SourceLayout.pinY - 7), anchor: .leading)
                }
            }
            .frame(width: L.boxW + SourceLayout.stub + 12, height: L.boxH)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    StimIcon(kind: stim.kind, size: 10, color: color).frame(width: 14)
                    Text(inst.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: SourceLayout.headerH)
                .background(color.opacity(0.16))
                HStack {
                    StimChip(stim: stim, selected: selected, invalid: bad)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: SourceLayout.rowH)
            }
            .frame(width: L.boxW, height: L.boxH)
            .background(theme.blockBG)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? theme.focusBorder : color.opacity(0.7), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture { doc.selection = .instance(inst.id) }
            .contextMenu {
                Menu("Wire To") {
                    ForEach(doc.state.inputPins, id: \.self) { t in
                        Button(doc.state.describe(t)) { doc.connect(from: ref, to: t) }
                    }
                }
                .disabled(doc.state.inputPins.isEmpty)
                Divider()
                Button("Duplicate") { doc.duplicateInstance(inst.id) }
                Button("Delete Source") { doc.removeInstance(inst.id) }
            }
            .help("Source \(inst.name): \(stim.kind.title), \(w) bit\(w == 1 ? "" : "s")")

            ConnectorDot(doc: doc, ref: ref, isOutput: true, color: color, zoom: zoom,
                         connected: !doc.state.wires(from: ref).isEmpty)
                .offset(x: L.boxW + SourceLayout.stub - 9, y: SourceLayout.pinY - 9)
        }
        .frame(width: L.boxW + SourceLayout.stub + 12, height: L.boxH, alignment: .topLeading)
        .offset(x: inst.x, y: inst.y)
        .modifier(MoveOnDrag(doc: doc, inst: inst, zoom: zoom, minX: 10, minY: 10))
    }
}
