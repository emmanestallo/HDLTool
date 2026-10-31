import AppKit
import Foundation
import Observation

struct DisplayedSignal: Identifiable, Equatable {
    let id: UUID
    var variable: VCDVar
    var radix: Radix
    var colorIndex: Int?
    var display: DisplayMode = .digital
    var interpolation: Interpolation = .step
    var heightMultiplier: Int = 1

    var rowHeight: CGFloat { UI.rowHeight * CGFloat(heightMultiplier) }
    var isAnalog: Bool { display.isAnalog }

    /// Analog modes this signal supports.
    var analogModes: [DisplayMode] {
        let t = variable.trace
        if t.isReal { return [.analogAuto] }
        if t.isBit || t.isString { return [] }
        return [.analogUnsigned, .analogSigned, .analogAuto]
    }

    init(variable: VCDVar, radix: Radix? = nil, colorIndex: Int? = nil) {
        self.id = UUID()
        self.variable = variable
        self.colorIndex = colorIndex
        if let radix {
            self.radix = radix
        } else {
            switch variable.kind {
            case "integer", "int", "longint", "shortint": self.radix = .signed
            case "parameter": self.radix = .unsigned
            default: self.radix = .hex
            }
        }
    }

    static func == (a: DisplayedSignal, b: DisplayedSignal) -> Bool {
        a.id == b.id && a.radix == b.radix && a.colorIndex == b.colorIndex && a.variable === b.variable
            && a.display == b.display && a.interpolation == b.interpolation && a.heightMultiplier == b.heightMultiplier
    }
}

struct ZoomBox: Equatable {
    var x0: CGFloat
    var x1: CGFloat
}

@MainActor
@Observable
final class WaveDocument: Identifiable {
    let id = UUID()
    let url: URL

    var file: VCDFile?
    var isLoading = false
    var progress: Double = 0
    var errorMessage: String?

    var displayed: [DisplayedSignal] = []
    var selection: Set<UUID> = []

    var startTime: Double = 0
    var timePerPixel: Double = 1
    private(set) var waveWidth: CGFloat = 0

    var cursorTime: Double?
    var markerTime: Double?
    var hoverTime: Double?
    var zoomBox: ZoomBox?

    var selectedScopeID: Int?
    var expandedScopes: Set<Int> = []

    @ObservationIgnored var isHoveringWaves = false
    @ObservationIgnored var hoverX: CGFloat?
    @ObservationIgnored var modDate: Date?
    @ObservationIgnored private var needsFit = true
    @ObservationIgnored private var selectionAnchor: UUID?

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    var name: String { url.lastPathComponent }
    var endTime: Double { Double(file?.endTime ?? 0) }
    var beginTime: Double { Double(file?.startTime ?? 0) }
    var span: Double { max(endTime - beginTime, 1) }

    // MARK: Loading

    func load() {
        isLoading = true
        progress = 0
        let url = self.url
        let docID = id
        let report: @Sendable (Double) -> Void = { p in
            Task { @MainActor in AppModel.shared.docs.first { $0.id == docID }?.progress = p }
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try VCDParser.parse(url: url, progress: report) }
            }.value
            switch result {
            case .success(let file): finish(file)
            case .failure(let error): fail(error)
            }
        }
    }

    func reload() {
        guard !isLoading else { return }
        load()
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func fail(_ error: Error) {
        isLoading = false
        modDate = Self.modificationDate(of: url)
        if file == nil { errorMessage = error.localizedDescription }
    }

    private func finish(_ newFile: VCDFile) {
        let isReload = file != nil
        let previous = displayed
        file = newFile
        isLoading = false
        errorMessage = nil
        modDate = Self.modificationDate(of: url)

        var byPath: [String: VCDVar] = [:]
        for v in newFile.allVars where byPath[v.fullPath] == nil { byPath[v.fullPath] = v }

        if isReload {
            displayed = previous.compactMap { d in
                guard let v = byPath[d.variable.fullPath] else { return nil }
                var copy = d
                copy.variable = v
                return copy
            }
            let ids = Set(displayed.map(\.id))
            selection = selection.filter { ids.contains($0) }
        } else if let restored = restoreLayout(byPath), !restored.isEmpty {
            displayed = restored
        } else {
            // Show the top-level testbench signals by default.
            if let scope = firstScopeWithVars(newFile.root) {
                displayed = scope.vars.prefix(48).map { DisplayedSignal(variable: $0) }
            }
        }

        if selectedScopeID == nil || newFile.scope(withID: selectedScopeID!) == nil {
            selectedScopeID = firstScopeWithVars(newFile.root)?.id ?? newFile.root.children.first?.id
        }
        if expandedScopes.isEmpty {
            for s in newFile.root.children { expandedScopes.insert(s.id) }
        }

        if needsFit || !isReload { zoomFit() } else { clampView() }
        if !isReload { saveLayout() }
    }

    private func firstScopeWithVars(_ root: VCDScope) -> VCDScope? {
        var queue = [root]
        while !queue.isEmpty {
            let s = queue.removeFirst()
            if !s.vars.isEmpty && s !== root { return s }
            queue.append(contentsOf: s.children)
        }
        return root.vars.isEmpty ? nil : root
    }

    // MARK: Viewport

    func setWaveWidth(_ w: CGFloat) {
        guard abs(w - waveWidth) > 0.5 else { return }
        waveWidth = w
        if needsFit && file != nil { zoomFit() } else { clampView() }
    }

    func timeAt(x: CGFloat) -> Double { startTime + Double(x) * timePerPixel }
    func xAt(time: Double) -> CGFloat { CGFloat((time - startTime) / timePerPixel) }
    var visibleDuration: Double { Double(waveWidth) * timePerPixel }

    func zoomFit() {
        guard file != nil, waveWidth > 20 else { needsFit = true; return }
        needsFit = false
        timePerPixel = span / Double(waveWidth - 12)
        startTime = beginTime
        clampView()
    }

    func zoom(by factor: Double, anchorX: CGFloat? = nil) {
        guard file != nil, waveWidth > 0 else { return }
        var ax = anchorX ?? waveWidth / 2
        if anchorX == nil, let c = cursorTime {
            let cx = xAt(time: c)
            if cx >= 0 && cx <= waveWidth { ax = cx }
        }
        let t = timeAt(x: ax)
        timePerPixel = clampTPP(timePerPixel * factor)
        startTime = t - Double(ax) * timePerPixel
        clampView()
    }

    func zoom(fromX a: CGFloat, toX b: CGFloat) {
        let lo = min(a, b), hi = max(a, b)
        guard hi - lo > 2 else { return }
        let t0 = timeAt(x: lo), t1 = timeAt(x: hi)
        timePerPixel = clampTPP((t1 - t0) / Double(max(waveWidth, 1)))
        startTime = t0
        clampView()
    }

    func pan(byPixels dx: CGFloat) {
        startTime += Double(dx) * timePerPixel
        clampView()
    }

    private func clampTPP(_ v: Double) -> Double {
        let maxTPP = span * 4 / Double(max(waveWidth, 1))
        return min(max(v, 1e-4), max(maxTPP, 1e-4))
    }

    private func clampView() {
        timePerPixel = clampTPP(timePerPixel)
        let vis = visibleDuration
        let lo = beginTime - vis * 0.05
        let hi = max(lo, endTime - vis * 0.9)
        startTime = min(max(startTime, lo), hi)
    }

    func ensureVisible(_ t: Double) {
        let x = xAt(time: t)
        if x < 0 || x > waveWidth {
            startTime = t - visibleDuration / 2
            clampView()
        }
    }

    // MARK: Cursor

    /// Index of the row at a y offset in the signal list (rows can have different heights).
    func rowIndex(atY y: CGFloat) -> Int? {
        var top: CGFloat = 0
        for (i, d) in displayed.enumerated() {
            top += d.rowHeight
            if y < top { return i }
        }
        return nil
    }

    var contentHeight: CGFloat { displayed.reduce(0) { $0 + $1.rowHeight } }

    func click(at p: CGPoint, setMarker: Bool) {
        let row = rowIndex(atY: p.y) ?? -1
        var t = timeAt(x: p.x)
        if displayed.indices.contains(row) {
            let trace = displayed[row].variable.trace
            if let snapped = nearestTransition(trace, to: t, withinPixels: 6) { t = snapped }
            if !setMarker {
                select(displayed[row].id, modifiers: NSEvent.modifierFlags.intersection([.command]))
            }
        }
        t = max(beginTime, min(t, endTime))
        if setMarker { markerTime = t } else { cursorTime = t }
    }

    private func nearestTransition(_ tr: Trace, to t: Double, withinPixels px: CGFloat) -> Double? {
        guard !tr.times.isEmpty else { return nil }
        let i = tr.firstIndex(atOrAfter: t)
        var best: Double?
        var bestDist = Double(px) * timePerPixel
        for j in [i - 1, i] where tr.times.indices.contains(j) {
            let d = abs(Double(tr.times[j]) - t)
            if d <= bestDist { bestDist = d; best = Double(tr.times[j]) }
        }
        return best
    }

    func jumpTransition(forward: Bool) {
        guard let file else { return }
        let sigs = displayed.filter { selection.contains($0.id) }
        let traces = (sigs.isEmpty ? displayed : sigs).map(\.variable.trace)
        guard !traces.isEmpty else { return }
        let c = cursorTime ?? (forward ? Double(file.startTime) - 1 : Double(file.endTime) + 1)
        var target: Double?
        for tr in traces {
            if forward {
                let i = tr.firstIndex(atOrAfter: c.rounded(.down) + 1)
                if i < tr.times.count { target = min(target ?? .infinity, Double(tr.times[i])) }
            } else {
                let i = tr.firstIndex(atOrAfter: c.rounded(.up)) - 1
                if i >= 0 { target = max(target ?? -.infinity, Double(tr.times[i])) }
            }
        }
        if let target {
            cursorTime = target
            ensureVisible(target)
        }
    }

    // MARK: Signals

    func isDisplayed(_ v: VCDVar) -> Bool { displayed.contains { $0.variable === v } }

    func add(_ vars: [VCDVar], before target: UUID? = nil) {
        let new = vars.map { DisplayedSignal(variable: $0) }
        guard !new.isEmpty else { return }
        if let target, let i = displayed.firstIndex(where: { $0.id == target }) {
            displayed.insert(contentsOf: new, at: i)
        } else {
            displayed.append(contentsOf: new)
        }
        selection = Set(new.map(\.id))
        saveLayout()
    }

    func removeSelected() {
        guard !selection.isEmpty else { return }
        displayed.removeAll { selection.contains($0.id) }
        selection = []
        saveLayout()
    }

    func remove(_ ids: Set<UUID>) {
        displayed.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        saveLayout()
    }

    func removeAll() {
        displayed = []
        selection = []
        saveLayout()
    }

    /// Ids to act on from a context menu: the selection if `id` is in it, else just `id`.
    func targets(for id: UUID) -> Set<UUID> {
        selection.contains(id) ? selection : [id]
    }

    func setRadix(_ ids: Set<UUID>, _ r: Radix) {
        for i in displayed.indices where ids.contains(displayed[i].id) { displayed[i].radix = r }
        saveLayout()
    }

    func setDisplay(_ ids: Set<UUID>, _ mode: DisplayMode) {
        for i in displayed.indices where ids.contains(displayed[i].id) {
            guard mode == .digital || displayed[i].analogModes.contains(mode) else { continue }
            displayed[i].display = mode
            if mode.isAnalog && displayed[i].heightMultiplier == 1 { displayed[i].heightMultiplier = 4 }
            if !mode.isAnalog && displayed[i].heightMultiplier == 4 { displayed[i].heightMultiplier = 1 }
        }
        saveLayout()
    }

    func setInterpolation(_ ids: Set<UUID>, _ v: Interpolation) {
        for i in displayed.indices where ids.contains(displayed[i].id) { displayed[i].interpolation = v }
        saveLayout()
    }

    func setHeight(_ ids: Set<UUID>, _ m: Int) {
        for i in displayed.indices where ids.contains(displayed[i].id) { displayed[i].heightMultiplier = max(1, min(m, 12)) }
        saveLayout()
    }

    func setColor(_ ids: Set<UUID>, _ c: Int?) {
        for i in displayed.indices where ids.contains(displayed[i].id) { displayed[i].colorIndex = c }
        saveLayout()
    }

    func moveSelection(by delta: Int) {
        guard !selection.isEmpty else { return }
        var arr = displayed
        let idxs = arr.indices.filter { selection.contains(arr[$0].id) }
        if delta < 0 {
            guard let first = idxs.first, first > 0 else { return }
            for i in idxs { arr.swapAt(i, i - 1) }
        } else {
            guard let last = idxs.last, last < arr.count - 1 else { return }
            for i in idxs.reversed() { arr.swapAt(i, i + 1) }
        }
        displayed = arr
        saveLayout()
    }

    func move(_ ids: Set<UUID>, before target: UUID?) {
        guard !ids.isEmpty, target.map({ !ids.contains($0) }) ?? true else { return }
        let moving = displayed.filter { ids.contains($0.id) }
        var rest = displayed.filter { !ids.contains($0.id) }
        let at = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.count
        rest.insert(contentsOf: moving, at: at)
        displayed = rest
        saveLayout()
    }

    func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor,
                  let a = displayed.firstIndex(where: { $0.id == anchor }),
                  let b = displayed.firstIndex(where: { $0.id == id }) {
            selection = Set(displayed[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    func moveSelectionCursor(by delta: Int, extend: Bool) {
        guard !displayed.isEmpty else { return }
        let current = displayed.lastIndex { selection.contains($0.id) }
        let next = current.map { min(max($0 + delta, 0), displayed.count - 1) } ?? 0
        let id = displayed[next].id
        if extend { selection.insert(id) } else { selection = [id]; selectionAnchor = id }
    }

    func selectAll() { selection = Set(displayed.map(\.id)) }

    // MARK: Drag & drop of signal rows

    func handleTextDrop(_ text: String, before target: UUID?) {
        if text.hasPrefix("row:") {
            let ids = Set(text.dropFirst(4).split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            move(ids, before: target)
        } else if text.hasPrefix("sig:"), let file {
            let vars = text.dropFirst(4).split(separator: ",").compactMap { Int($0) }
                .filter { file.allVars.indices.contains($0) }.map { file.allVars[$0] }
            add(vars, before: target)
        } else {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.fileExists(atPath: path) {
                AppModel.shared.open([URL(fileURLWithPath: path)])
            }
        }
    }

    func dragPayload(for id: UUID) -> String {
        let ids = selection.contains(id) ? displayed.filter { selection.contains($0.id) }.map(\.id) : [id]
        return "row:" + ids.map(\.uuidString).joined(separator: ",")
    }

    // MARK: Layout persistence

    private var layoutKey: String { "layout:" + url.path }

    func saveLayout() {
        let entries: [[String: Any]] = displayed.map {
            ["path": $0.variable.fullPath, "radix": $0.radix.rawValue, "color": $0.colorIndex ?? -1,
             "display": $0.display.rawValue, "interp": $0.interpolation.rawValue, "height": $0.heightMultiplier]
        }
        UserDefaults.standard.set(entries, forKey: layoutKey)
    }

    private func restoreLayout(_ byPath: [String: VCDVar]) -> [DisplayedSignal]? {
        guard let entries = UserDefaults.standard.array(forKey: layoutKey) as? [[String: Any]] else { return nil }
        return entries.compactMap { e in
            guard let p = e["path"] as? String, let v = byPath[p] else { return nil }
            func int(_ key: String) -> Int? { (e[key] as? Int) ?? (e[key] as? String).flatMap { Int($0) } }
            let c = int("color") ?? -1
            var d = DisplayedSignal(variable: v,
                                    radix: (e["radix"] as? String).flatMap(Radix.init(rawValue:)),
                                    colorIndex: c >= 0 ? c : nil)
            if let m = (e["display"] as? String).flatMap(DisplayMode.init(rawValue:)),
               m == .digital || d.analogModes.contains(m) {
                d.display = m
            }
            if let i = (e["interp"] as? String).flatMap(Interpolation.init(rawValue:)) { d.interpolation = i }
            if let h = int("height") { d.heightMultiplier = max(1, min(h, 12)) }
            return d
        }
    }
}
