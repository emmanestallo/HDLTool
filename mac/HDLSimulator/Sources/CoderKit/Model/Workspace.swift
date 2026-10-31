import AppKit
import Foundation
import Observation

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct IndexedFile: Sendable {
    var date: Date
    var language: HDLLanguage
    var symbols: [HDLSymbol]
}

struct HierNode: Identifiable, Hashable {
    var id: String
    var instance: String?
    var module: String
    var file: String?
    var line: Int
    var children: [HierNode]
    var missing: Bool
    var recursive = false
}

/// The open folder: file tree, file list and a symbol index of all HDL files.
@MainActor
@Observable
final class Workspace {
    var root: URL?
    var expanded: Set<String> = []
    var listingVersion = 0
    var files: [URL] = []                     // all files (for Go to File)
    var index: [String: IndexedFile] = [:]    // HDL files → symbols
    var indexing = false
    /// Files opened outside the folder; they are indexed too.
    var extraFiles: [String] = []

    @ObservationIgnored private var listingCache: [String: [FileItem]] = [:]
    @ObservationIgnored private var listingDates: [String: Date] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var lastFullScan = Date.distantPast
    @ObservationIgnored private(set) var moduleTable: [String: [(path: String, symbol: HDLSymbol)]] = [:]

    nonisolated static let hiddenNames: Set<String> = [".git", ".DS_Store", ".build", ".swiftpm", ".svn", ".hg"]
    nonisolated static let skipIndexDirs: Set<String> = ["node_modules", "sim_out", ".build", "build", "DerivedData", "obj_dir", "work"]

    var name: String { root?.lastPathComponent ?? "No Folder Opened" }

    // MARK: Tree

    func setRoot(_ url: URL?) {
        root = url?.standardizedFileURL
        listingCache = [:]
        listingDates = [:]
        expanded = []
        files = []
        index = index.filter { extraFiles.contains($0.key) }
        rebuildModuleTable()
        listingVersion += 1
        lastFullScan = .distantPast
        scan()
    }

    func children(of url: URL) -> [FileItem] {
        let key = url.path
        if let c = listingCache[key] { return c }
        let items = Self.list(url)
        listingCache[key] = items
        listingDates[key] = Self.modDate(url)
        return items
    }

    nonisolated static func list(_ url: URL) -> [FileItem] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        var out: [FileItem] = []
        for n in names where !hiddenNames.contains(n) && !n.hasPrefix("._") {
            let u = url.appendingPathComponent(n)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: u.path, isDirectory: &isDir)
            out.append(FileItem(url: u, isDir: isDir.boolValue))
        }
        return out.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    nonisolated static func modDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    func refreshListing() {
        listingCache = [:]
        listingDates = [:]
        listingVersion += 1
        scan(force: true)
    }

    /// Called periodically: picks up directory and file changes.
    func poll() {
        var changed = false
        for (path, date) in listingDates {
            let d = Self.modDate(URL(fileURLWithPath: path))
            if d != date {
                listingCache[path] = nil
                listingDates[path] = nil
                changed = true
            }
        }
        if changed { listingVersion += 1 }
        let full = changed || Date().timeIntervalSince(lastFullScan) > 15
        scan(force: full)
    }

    func toggle(_ url: URL) {
        if expanded.contains(url.path) { expanded.remove(url.path) } else { expanded.insert(url.path) }
    }

    func reveal(_ url: URL) {
        guard let root else { return }
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(root.path) && dir.path != root.path {
            expanded.insert(dir.path)
            dir = dir.deletingLastPathComponent()
        }
    }

    func relativePath(_ url: URL) -> String {
        if let root, url.standardizedFileURL.path == root.path { return "" }
        guard let root, url.path.hasPrefix(root.path + "/") else { return (url.path as NSString).abbreviatingWithTildeInPath }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    // MARK: Index

    func scan(force: Bool = false) {
        guard scanTask == nil else { return }
        let root = self.root
        let previous = index
        let extra = extraFiles
        let needList = force || files.isEmpty
        let knownFiles = files
        indexing = true
        if needList { lastFullScan = Date() }
        scanTask = Task.detached(priority: .utility) {
            let all: [URL] = needList ? (root.map { Self.enumerate($0) } ?? []) : knownFiles
            var hdl = all.filter { HDLLanguage.hdlExtensions.contains($0.pathExtension.lowercased()) }.map(\.path)
            for e in extra where !hdl.contains(e) { hdl.append(e) }
            var next: [String: IndexedFile] = [:]
            for path in hdl {
                let url = URL(fileURLWithPath: path)
                guard let date = Self.modDate(url) else { continue }
                if let p = previous[path], p.date == date { next[path] = p; continue }
                guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { continue }
                let text = String(decoding: data, as: UTF8.self)
                let lang = HDLLanguage.detect(url)
                next[path] = IndexedFile(date: date, language: lang, symbols: SymbolScanner.scan(text, language: lang))
            }
            let result = next
            await MainActor.run {
                var next = result
                if needList { self.files = all }
                // Keep live entries from open documents (date = distantFuture).
                for (k, v) in self.index where v.date == .distantFuture { next[k] = v }
                let changed = next.count != self.index.count || next.contains { self.index[$0.key]?.date != $0.value.date }
                if changed {
                    self.index = next
                    self.rebuildModuleTable()
                }
                self.indexing = false
                self.scanTask = nil
            }
        }
    }

    nonisolated static func enumerate(_ root: URL) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let u as URL in e {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if skipIndexDirs.contains(u.lastPathComponent) { e.skipDescendants() }
                continue
            }
            out.append(u.standardizedFileURL)
            if out.count >= 8000 { break }
        }
        return out
    }

    /// Live symbols from an open document override the file on disk.
    func updateLive(path: String, language: HDLLanguage, symbols: [HDLSymbol]) {
        index[path] = IndexedFile(date: .distantFuture, language: language, symbols: symbols)
        rebuildModuleTable()
    }

    /// Back to the on-disk version (the document was closed).
    func dropLive(path: String) {
        if index[path]?.date == .distantFuture {
            index[path] = nil
            scan()
        }
    }

    func rebuildModuleTable() {
        var t: [String: [(path: String, symbol: HDLSymbol)]] = [:]
        for (path, f) in index {
            for s in f.symbols where [.module, .interface, .program, .entity, .package, .klass].contains(s.kind) {
                t[s.name.lowercased(), default: []].append((path, s))
            }
        }
        moduleTable = t
    }

    func definitions(of name: String) -> [(path: String, symbol: HDLSymbol)] {
        moduleTable[name.lowercased()] ?? []
    }

    var allModules: [(path: String, symbol: HDLSymbol)] {
        moduleTable.values.flatMap { $0 }
            .filter { $0.symbol.kind != .package && $0.symbol.kind != .klass }
            .sorted { $0.symbol.name.localizedStandardCompare($1.symbol.name) == .orderedAscending }
    }

    /// Instances inside a module (Verilog) or the architectures of an entity (VHDL).
    func instances(of module: String) -> [HDLSymbol] {
        var out: [HDLSymbol] = []
        for (_, f) in index {
            for s in f.symbols {
                if (s.kind == .module || s.kind == .interface || s.kind == .program) && s.name == module {
                    out += s.children.filter { $0.kind == .instance }
                } else if s.kind == .architecture && s.target?.lowercased() == module.lowercased() {
                    out += s.children.filter { $0.kind == .instance }
                }
            }
        }
        return out
    }

    func instanceFile(of module: String) -> String? {
        for (path, f) in index {
            for s in f.symbols {
                if (s.kind == .module && s.name == module) || (s.kind == .architecture && s.target?.lowercased() == module.lowercased()) {
                    return path
                }
            }
        }
        return nil
    }

    /// Design hierarchy: top modules (not instantiated anywhere) and their instances.
    func hierarchy() -> [HierNode] {
        let defs = allModules.filter { $0.symbol.kind == .module || $0.symbol.kind == .entity || $0.symbol.kind == .program }
        var instantiated = Set<String>()
        for (_, f) in index {
            for s in f.symbols {
                for c in s.children where c.kind == .instance { if let t = c.target { instantiated.insert(t.lowercased()) } }
            }
        }
        var seenTop = Set<String>()
        var tops: [HierNode] = []
        for d in defs where !instantiated.contains(d.symbol.name.lowercased()) && !seenTop.contains(d.symbol.name.lowercased()) {
            seenTop.insert(d.symbol.name.lowercased())
            tops.append(node(module: d.symbol.name, instance: nil, file: d.path, line: d.symbol.line, idPrefix: "", stack: []))
        }
        return tops.sorted { a, b in
            // testbenches (no ports) first
            if a.children.count != b.children.count { return a.children.count > b.children.count }
            return a.module < b.module
        }
    }

    private func node(module: String, instance: String?, file: String?, line: Int, idPrefix: String, stack: [String]) -> HierNode {
        let id = idPrefix + "/" + (instance ?? module)
        let def = definitions(of: module).first
        var n = HierNode(id: id, instance: instance, module: module, file: instance == nil ? (def?.path ?? file) : file,
                         line: line, children: [], missing: def == nil)
        if stack.contains(module.lowercased()) || stack.count > 40 {
            n.recursive = true
            return n
        }
        let instFile = instanceFile(of: module)
        for inst in instances(of: module) {
            guard let t = inst.target else { continue }
            n.children.append(node(module: t, instance: inst.name, file: instFile, line: inst.line, idPrefix: id, stack: stack + [module.lowercased()]))
        }
        return n
    }
}

// MARK: - Find in files

struct SearchOptions: Equatable {
    var query = ""
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    var include = ""

    func makeRegex() -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b" + pattern + "\\b" }
        return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }
}

struct SearchMatch: Identifiable, Hashable {
    let id = UUID()
    let line: Int            // 0-based
    let preview: String
    let range: NSRange       // within preview
    let offset: Int          // UTF-16 offset in file
    let length: Int
}

struct SearchFileResult: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var matches: [SearchMatch]
}

enum SearchEngine {
    static let textExtensions: Set<String> = [
        "v", "vh", "sv", "svh", "vhd", "vhdl", "vlog", "txt", "md", "tcl", "xdc", "sdc", "ucf", "pcf", "lpf", "qsf",
        "f", "do", "py", "mem", "hex", "coe", "mif", "json", "yaml", "yml", "sh", "mk", "cfg", "ini", "toml", "c", "h",
        "cpp", "hpp", "cc", "lst", "ys", "sby", "core", "xml", "csv",
    ]

    static func isText(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return textExtensions.contains(e) || e.isEmpty && ["Makefile", "makefile", "README", "LICENSE"].contains(url.lastPathComponent)
    }

    static func search(_ opts: SearchOptions, files: [URL], buffers: [String: String]) -> [SearchFileResult] {
        guard let re = opts.makeRegex() else { return [] }
        let globs = opts.include.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: [SearchFileResult] = []
        var total = 0
        var paths = files.filter(isText).map(\.path)
        for p in buffers.keys where !paths.contains(p) && !p.hasPrefix("untitled:") { paths.append(p) }
        for path in paths {
            if !globs.isEmpty && !globs.contains(where: { matchGlob($0, path) }) { continue }
            let text: String
            if let b = buffers[path] { text = b } else {
                guard let data = FileManager.default.contents(atPath: path), data.count < 4_000_000,
                      !data.prefix(4096).contains(0) else { continue }
                text = String(decoding: data, as: UTF8.self)
            }
            let ns = text as NSString
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var result = SearchFileResult(path: path, matches: [])
            var lineStart = 0
            var lineNo = 0
            var scanned = 0
            for m in matches.prefix(1000) {
                // advance line counter
                while scanned < m.range.location {
                    if ns.character(at: scanned) == 10 { lineNo += 1; lineStart = scanned + 1 }
                    scanned += 1
                }
                let lineRange = ns.lineRange(for: NSRange(location: m.range.location, length: 0))
                var lineText = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
                var start = m.range.location - lineStart
                // trim long leading whitespace for the preview
                let lead = lineText.prefix { $0 == " " || $0 == "\t" }.utf16.count
                if lead > 0 {
                    lineText = String(lineText.drop { $0 == " " || $0 == "\t" })
                    start -= lead
                }
                let len = min(m.range.length, max(0, lineText.utf16.count - start))
                result.matches.append(SearchMatch(line: lineNo, preview: lineText, range: NSRange(location: max(0, start), length: len),
                                                  offset: m.range.location, length: m.range.length))
            }
            total += result.matches.count
            out.append(result)
            if total > 5000 { break }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func matchGlob(_ glob: String, _ path: String) -> Bool {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: glob)
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        if glob.contains("/") {
            return path.range(of: pattern.replacingOccurrences(of: "^", with: ""), options: .regularExpression) != nil
        }
        return (path as NSString).lastPathComponent.range(of: pattern, options: .regularExpression) != nil
    }
}
