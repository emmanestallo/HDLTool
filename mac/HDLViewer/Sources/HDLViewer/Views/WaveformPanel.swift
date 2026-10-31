import AppKit
import SwiftUI

struct WaveformPanel: View {
    let doc: WaveDocument
    let file: VCDFile
    @Environment(\.theme) private var theme
    @AppStorage("nameColumnWidth") private var nameWidth: Double = 220
    @AppStorage("valueColumnWidth") private var valueWidth: Double = 110
    @FocusState private var focused: Bool

    private var leftWidth: CGFloat { nameWidth + valueWidth + 2 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.border).frame(height: 1)
            GeometryReader { geo in
                let contentHeight = max(geo.size.height, doc.contentHeight + UI.rowHeight)
                ZStack(alignment: .topLeading) {
                    GridLayer(doc: doc, file: file)
                        .padding(.leading, leftWidth)
                        .allowsHitTesting(false)

                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            LazyVStack(spacing: 0) {
                                ForEach(doc.displayed) { sig in NameCell(doc: doc, sig: sig, onFocus: { focused = true }) }
                                TailDropZone(doc: doc)
                            }
                            .frame(width: nameWidth, height: contentHeight, alignment: .top)
                            .background(theme.editor)
                            Rectangle().fill(theme.border).frame(width: 1, height: contentHeight)
                            LazyVStack(spacing: 0) {
                                ForEach(doc.displayed) { sig in ValueCell(doc: doc, sig: sig) }
                            }
                            .frame(width: valueWidth, height: contentHeight, alignment: .top)
                            .background(theme.editor)
                            Rectangle().fill(theme.border).frame(width: 1, height: contentHeight)
                            WaveColumn(doc: doc, height: contentHeight, onFocus: { focused = true })
                        }
                    }

                    OverlayLayer(doc: doc)
                        .padding(.leading, leftWidth)
                        .allowsHitTesting(false)

                    if doc.displayed.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 30, weight: .ultraLight))
                            Text("No signals shown")
                                .font(.system(size: 14))
                            Text("Double-click or drag signals from the Explorer")
                                .font(UI.uiFont)
                                .foregroundStyle(theme.dimFG)
                        }
                        .foregroundStyle(theme.fg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .background(theme.editor)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let mods = press.modifiers
            switch press.key {
            case .leftArrow: doc.jumpTransition(forward: false)
            case .rightArrow: doc.jumpTransition(forward: true)
            case .upArrow:
                if mods.contains(.option) { doc.moveSelection(by: -1) } else { doc.moveSelectionCursor(by: -1, extend: mods.contains(.shift)) }
            default:
                if mods.contains(.option) { doc.moveSelection(by: 1) } else { doc.moveSelectionCursor(by: 1, extend: mods.contains(.shift)) }
            }
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            doc.removeSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            if doc.markerTime != nil { doc.markerTime = nil } else { doc.selection = [] }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "afFmM+-=")) { press in
            switch press.characters {
            case "a" where press.modifiers.contains(.command): doc.selectAll()
            case "f", "F": doc.zoomFit()
            case "m", "M": doc.markerTime = doc.cursorTime
            case "+", "=": doc.zoom(by: 0.5)
            case "-": doc.zoom(by: 2)
            default: return .ignored
            }
            return .handled
        }
        .onAppear { focused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("SIGNALS").font(.system(size: 11, weight: .semibold))
                Spacer()
                if !doc.displayed.isEmpty {
                    Menu {
                        Button("Select All") { doc.selectAll() }
                        Button("Remove Selected") { doc.removeSelected() }.disabled(doc.selection.isEmpty)
                        Button("Remove All") { doc.removeAll() }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12))
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(width: nameWidth)
            ResizeDivider(color: theme.border) { dx in nameWidth = min(max(nameWidth + dx, 100), 600) }
            Text("VALUE")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(width: valueWidth, alignment: .leading)
            ResizeDivider(color: theme.border) { dx in valueWidth = min(max(valueWidth + dx, 60), 400) }
            RulerView(doc: doc, file: file)
        }
        .foregroundStyle(theme.dimFG)
        .frame(height: 30)
        .background(theme.rulerBG)
    }
}

// MARK: - Rows

struct NameCell: View {
    let doc: WaveDocument
    let sig: DisplayedSignal
    let onFocus: () -> Void
    @Environment(\.theme) private var theme
    @ViewState private var dropTargeted = false
    @ViewState private var hovering = false

    var body: some View {
        let selected = doc.selection.contains(sig.id)
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1)
                .fill(theme.color(for: sig))
                .frame(width: 3, height: sig.isAnalog ? 30 : 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(sig.variable.name)
                        .font(UI.uiFont)
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if !sig.variable.range.isEmpty {
                        Text(sig.variable.range)
                            .font(UI.monoSmall)
                            .foregroundStyle(theme.dimFG)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                if sig.isAnalog && sig.heightMultiplier > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 9))
                        Text(sig.display.shortTitle + (sig.interpolation == .linear ? " · linear" : ""))
                            .lineLimit(1)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(theme.dimFG)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: sig.rowHeight)
        .background(selected ? theme.listSelection : (hovering ? theme.listHover : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.rowSeparator).frame(height: 1) }
        .overlay(alignment: .top) {
            if dropTargeted { Rectangle().fill(theme.focusBorder).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            doc.select(sig.id, modifiers: NSEvent.modifierFlags)
            onFocus()
        }
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: doc.dragPayload(for: sig.id) as NSString) }
        .onDrop(of: [.text], isTargeted: $dropTargeted) { providers in
            loadText(providers) { doc.handleTextDrop($0, before: sig.id) }
        }
        .contextMenu { SignalMenu(doc: doc, sig: sig) }
        .help(sig.variable.fullPath)
    }
}

/// Empty area below the last row; dropping here appends.
struct TailDropZone: View {
    let doc: WaveDocument
    @Environment(\.theme) private var theme
    @ViewState private var targeted = false

    var body: some View {
        Color.clear
            .frame(height: UI.rowHeight * 3)
            .overlay(alignment: .top) {
                if targeted { Rectangle().fill(theme.focusBorder).frame(height: 2) }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.text], isTargeted: $targeted) { providers in
                loadText(providers) { doc.handleTextDrop($0, before: nil) }
            }
    }
}

func loadText(_ providers: [NSItemProvider], _ handler: @escaping @MainActor (String) -> Void) -> Bool {
    guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
    _ = p.loadObject(ofClass: NSString.self) { obj, _ in
        guard let s = obj as? NSString else { return }
        let str = s as String
        Task { @MainActor in handler(str) }
    }
    return true
}

struct SignalMenu: View {
    let doc: WaveDocument
    let sig: DisplayedSignal
    @Environment(\.theme) private var theme

    var body: some View {
        let ids = doc.targets(for: sig.id)
        let isVector = !sig.variable.trace.isBit && !sig.variable.trace.isReal && !sig.variable.trace.isString
        if !sig.analogModes.isEmpty {
            Picker("Display", selection: Binding(get: { sig.display }, set: { doc.setDisplay(ids, $0) })) {
                Text(DisplayMode.digital.title).tag(DisplayMode.digital)
                ForEach(sig.analogModes) { Text($0.title).tag($0) }
            }
            if sig.isAnalog {
                Picker("Interpolation", selection: Binding(get: { sig.interpolation }, set: { doc.setInterpolation(ids, $0) })) {
                    ForEach(Interpolation.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        Picker("Row Height", selection: Binding(get: { sig.heightMultiplier }, set: { doc.setHeight(ids, $0) })) {
            ForEach([1, 2, 3, 4, 6, 8, 12], id: \.self) { Text("\($0)×").tag($0) }
        }
        if isVector {
            Picker("Radix", selection: Binding(get: { sig.radix }, set: { doc.setRadix(ids, $0) })) {
                ForEach(Radix.allCases) { Text($0.title).tag($0) }
            }
        }
        Picker("Color", selection: Binding(get: { sig.colorIndex ?? -1 }, set: { doc.setColor(ids, $0 < 0 ? nil : $0) })) {
            Text("Default").tag(-1)
            ForEach(Array(theme.palette.enumerated()), id: \.offset) { i, p in Text(p.name).tag(i) }
        }
        Divider()
        Button("Move Up  (⌥↑)") { doc.selection = ids; doc.moveSelection(by: -1) }
        Button("Move Down  (⌥↓)") { doc.selection = ids; doc.moveSelection(by: 1) }
        Divider()
        Button("Copy Name") { copy(sig.variable.fullPath) }
        if let c = doc.cursorTime, let v = sig.variable.trace.value(at: c) {
            Button("Copy Value at Cursor") {
                let t = sig.variable.trace
                if sig.isAnalog, let level = Analog.level(v, trace: t, mode: sig.display) {
                    copy(Analog.format(level, trace: t, mode: sig.display))
                } else {
                    copy(ValueFormatter.format(v, trace: t, radix: sig.radix))
                }
            }
        }
        Divider()
        Button(ids.count > 1 ? "Remove \(ids.count) Signals" : "Remove") { doc.remove(ids) }
    }
}

struct ValueCell: View {
    let doc: WaveDocument
    let sig: DisplayedSignal
    @Environment(\.theme) private var theme

    var body: some View {
        let selected = doc.selection.contains(sig.id)
        let trace = sig.variable.trace
        let raw = doc.cursorTime.flatMap { trace.value(at: $0) }
        let digital = raw.map { ValueFormatter.format($0, trace: trace, radix: sig.radix) } ?? "—"
        let level = sig.isAnalog ? raw.flatMap { Analog.level($0, trace: trace, mode: sig.display) } : nil
        let text = level.map { Analog.format($0, trace: trace, mode: sig.display) } ?? digital
        let color: Color = {
            guard let raw else { return theme.dimFG }
            if ValueFormatter.isHighZ(raw) { return theme.waveZ }
            if ValueFormatter.isUnknown(raw) { return theme.waveX }
            return theme.valueFG
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(UI.mono)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.head)
            if level != nil && sig.heightMultiplier > 1 && !trace.isReal {
                Text(digital)
                    .font(UI.monoSmall)
                    .foregroundStyle(theme.dimFG)
                    .lineLimit(1)
                    .help("Raw code (\(sig.radix.title))")
            }
        }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: sig.rowHeight)
            .background(selected ? theme.listSelection : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.rowSeparator).frame(height: 1) }
            .textSelection(.enabled)
    }
}

// MARK: - Waves

struct WaveColumn: View {
    let doc: WaveDocument
    let height: CGFloat
    let onFocus: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(doc.displayed) { sig in
                WaveRow(doc: doc, sig: sig)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if abs(v.translation.width) > 3 {
                        doc.zoomBox = ZoomBox(x0: v.startLocation.x, x1: v.location.x)
                    }
                }
                .onEnded { v in
                    if let box = doc.zoomBox, abs(box.x1 - box.x0) > 3 {
                        doc.zoom(fromX: box.x0, toX: box.x1)
                    } else {
                        doc.click(at: v.location, setMarker: NSEvent.modifierFlags.contains(.shift))
                    }
                    doc.zoomBox = nil
                    onFocus()
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                doc.isHoveringWaves = true
                doc.hoverX = p.x
                doc.hoverTime = doc.timeAt(x: p.x)
            case .ended:
                doc.isHoveringWaves = false
                doc.hoverX = nil
                doc.hoverTime = nil
            }
        }
    }
}

struct WaveRow: View {
    let doc: WaveDocument
    let sig: DisplayedSignal
    @Environment(\.theme) private var theme

    var body: some View {
        let start = doc.startTime
        let tpp = doc.timePerPixel
        let end = doc.endTime
        let selected = doc.selection.contains(sig.id)
        let style = WaveStyle(color: theme.color(for: sig), x: theme.waveX, z: theme.waveZ, text: theme.waveText,
                              guide: theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10),
                              label: theme.dimFG, labelBG: theme.editor.opacity(0.8))
        let trace = sig.variable.trace
        let radix = sig.radix
        let mode = sig.display
        let interp = sig.interpolation
        Canvas { ctx, size in
            if mode.isAnalog {
                WaveRenderer.drawAnalog(&ctx, size: size, trace: trace, start: start, tpp: tpp,
                                        endTime: end, mode: mode, interpolation: interp, style: style)
            } else {
                WaveRenderer.draw(&ctx, size: size, trace: trace, start: start, tpp: tpp,
                                  endTime: end, radix: radix, style: style)
            }
        }
        .frame(height: sig.rowHeight)
        .background(selected ? theme.waveRowSelected : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.rowSeparator).frame(height: 1) }
    }
}

// MARK: - Ruler, grid, overlay

struct RulerView: View {
    let doc: WaveDocument
    let file: VCDFile
    @Environment(\.theme) private var theme
    @ViewState private var lastDrag: CGFloat = 0
    @ViewState private var dragged = false

    var body: some View {
        let start = doc.startTime, tpp = doc.timePerPixel
        let cursor = doc.cursorTime, marker = doc.markerTime
        let ts = file.timescale
        let fg = theme.rulerFG, border = theme.border, cursorColor = theme.cursor, markerColor = theme.marker
        Canvas { ctx, size in
            let info = TickInfo.compute(start: start, tpp: tpp, width: size.width, timescale: ts)
            let x = { (t: Double) in CGFloat((t - start) / tpp) }
            let endT = start + Double(size.width) * tpp
            if let minor = info.minor {
                var p = Path()
                var t = (start / minor).rounded(.down) * minor
                while t <= endT {
                    let xx = x(t).rounded() + 0.5
                    p.move(to: CGPoint(x: xx, y: size.height - 4))
                    p.addLine(to: CGPoint(x: xx, y: size.height))
                    t += minor
                }
                ctx.stroke(p, with: .color(fg.opacity(0.45)), lineWidth: 1)
            }
            var major = Path()
            var t = (start / info.step).rounded(.down) * info.step
            while t <= endT {
                let xx = x(t).rounded() + 0.5
                major.move(to: CGPoint(x: xx, y: size.height - 10))
                major.addLine(to: CGPoint(x: xx, y: size.height))
                let label = ts.format(t, unit: info.unit, decimals: info.decimals)
                ctx.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(fg),
                         at: CGPoint(x: xx + 4, y: 3), anchor: .topLeading)
                t += info.step
            }
            ctx.stroke(major, with: .color(fg.opacity(0.8)), lineWidth: 1)
            ctx.stroke(Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0)), with: .color(border))

            func flag(_ t: Double, _ color: Color) {
                let xx = x(t)
                guard xx >= -60 && xx <= size.width + 60 else { return }
                let text = ctx.resolve(Text(ts.format(t)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white))
                let sz = text.measure(in: CGSize(width: 300, height: 30))
                var rect = CGRect(x: xx - sz.width / 2 - 5, y: size.height - sz.height - 9, width: sz.width + 10, height: sz.height + 3)
                rect.origin.x = min(max(rect.origin.x, 0), size.width - rect.width)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
                ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                var tri = Path()
                tri.move(to: CGPoint(x: xx - 4, y: rect.maxY))
                tri.addLine(to: CGPoint(x: xx + 4, y: rect.maxY))
                tri.addLine(to: CGPoint(x: xx, y: size.height))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(color))
            }
            if let marker { flag(marker, markerColor) }
            if let cursor { flag(cursor, cursorColor) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { doc.setWaveWidth($0) }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if abs(v.translation.width) > 2 || dragged {
                        dragged = true
                        doc.pan(byPixels: -(v.translation.width - lastDrag))
                        lastDrag = v.translation.width
                    }
                }
                .onEnded { v in
                    if !dragged {
                        let t = max(doc.beginTime, min(doc.timeAt(x: v.location.x), doc.endTime))
                        if NSEvent.modifierFlags.contains(.shift) { doc.markerTime = t } else { doc.cursorTime = t }
                    }
                    dragged = false
                    lastDrag = 0
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                doc.isHoveringWaves = true
                doc.hoverX = p.x
            case .ended:
                doc.isHoveringWaves = false
                doc.hoverX = nil
            }
        }
        .help("Click to place cursor · Shift-click for marker · Drag to pan")
    }
}

struct GridLayer: View {
    let doc: WaveDocument
    let file: VCDFile
    @Environment(\.theme) private var theme

    var body: some View {
        let start = doc.startTime, tpp = doc.timePerPixel, ts = file.timescale
        let grid = theme.grid
        let endX = doc.xAt(time: doc.endTime)
        let shade = theme.isDark ? Color.black.opacity(0.18) : Color.black.opacity(0.03)
        Canvas { ctx, size in
            let info = TickInfo.compute(start: start, tpp: tpp, width: size.width, timescale: ts)
            var p = Path()
            var t = (start / info.step).rounded(.down) * info.step
            let endT = start + Double(size.width) * tpp
            while t <= endT {
                let x = CGFloat((t - start) / tpp).rounded() + 0.5
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                t += info.step
            }
            ctx.stroke(p, with: .color(grid), lineWidth: 1)
            if endX < size.width {
                ctx.fill(Path(CGRect(x: max(endX, 0), y: 0, width: size.width - max(endX, 0), height: size.height)),
                         with: .color(shade))
            }
        }
    }
}

struct OverlayLayer: View {
    let doc: WaveDocument
    @Environment(\.theme) private var theme

    var body: some View {
        let start = doc.startTime, tpp = doc.timePerPixel
        let cursor = doc.cursorTime, marker = doc.markerTime, hover = doc.hoverTime, box = doc.zoomBox
        let c = theme.cursor, m = theme.marker, h = theme.hoverLine, accent = theme.accent
        Canvas { ctx, size in
            func x(_ t: Double) -> CGFloat { CGFloat((t - start) / tpp).rounded() + 0.5 }
            func vline(_ xx: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: xx, y: 0))
                p.addLine(to: CGPoint(x: xx, y: size.height))
                return p
            }
            if let box {
                let r = CGRect(x: min(box.x0, box.x1), y: 0, width: abs(box.x1 - box.x0), height: size.height)
                ctx.fill(Path(r), with: .color(accent.opacity(0.15)))
                ctx.stroke(Path(r.insetBy(dx: 0.5, dy: -1)), with: .color(accent.opacity(0.7)), lineWidth: 1)
            }
            if let hover { ctx.stroke(vline(x(hover)), with: .color(h), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
            if let marker { ctx.stroke(vline(x(marker)), with: .color(m), style: StrokeStyle(lineWidth: 1, dash: [5, 3])) }
            if let cursor { ctx.stroke(vline(x(cursor)), with: .color(c), lineWidth: 1) }
        }
        .clipped()
    }
}
