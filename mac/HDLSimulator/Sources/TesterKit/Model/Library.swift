import Foundation
import Observation

struct SourceFile: Identifiable, Equatable {
    var url: URL
    var modules: [ModuleInfo]
    var errors: [String]
    var modDate: Date?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// The Verilog files the user has opened; their modules are the available DUTs.
@MainActor
@Observable
final class Library {
    var files: [SourceFile] = []
    var collapsedFiles: Set<String> = []
    var expandedModules: Set<String> = []

    static let extensions: Set<String> = ["v", "sv", "vh", "svh", "verilog", "vlg"]

    var modules: [ModuleInfo] { files.flatMap(\.modules) }

    func module(id: String) -> ModuleInfo? { modules.first { $0.id == id } }

    func module(named name: String, preferFile: String?) -> ModuleInfo? {
        let all = modules.filter { $0.name == name }
        return all.first { preferFile != nil && Self.samePath($0.file.path, preferFile!) } ?? all.first
    }

    /// True when two paths name the same file (follows symlinks such as /tmp → /private/tmp).
    /// `path` written relative to the folder `dir` (with `..` where needed).
    nonisolated static func relativePath(_ path: String, from dir: String) -> String {
        let a = URL(fileURLWithPath: dir).standardizedFileURL.pathComponents
        let b = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var i = 0
        while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: a.count - i) + b[i...]).joined(separator: "/")
    }

    nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        a == b || URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    static func isVerilog(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Adds files (or every Verilog file in a folder). Returns the files that were added or reloaded.
    @discardableResult
    func add(_ urls: [URL]) -> [SourceFile] {
        var added: [SourceFile] = []
        for raw in urls {
            let url = raw.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                added += add(Self.verilogFiles(in: url))
                continue
            }
            guard Self.isVerilog(url) else { continue }
            let f = Self.load(url)
            if let i = files.firstIndex(where: { $0.url.path == url.path }) {
                files[i] = f
            } else {
                files.append(f)
            }
            added.append(f)
        }
        return added
    }

    static func verilogFiles(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            if isVerilog(u) { out.append(u) }
            if out.count > 500 { break }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func load(_ url: URL) -> SourceFile {
        let r = VerilogParser.parse(file: url)
        var errors = r.errors
        if r.modules.isEmpty && errors.isEmpty { errors.append("No modules found") }
        return SourceFile(url: url, modules: r.modules, errors: errors, modDate: modificationDate(url))
    }

    func remove(_ file: SourceFile) {
        files.removeAll { $0.id == file.id }
    }

    func reload(_ file: SourceFile) {
        if let i = files.firstIndex(where: { $0.id == file.id }) {
            files[i] = Self.load(file.url)
        }
    }

    /// Re-reads files that changed on disk; returns them. `settled`: the writes are known to be
    /// finished (a save in the Coder tab), so don't wait for very recent files.
    func checkForChanges(settled: Bool = false) -> [SourceFile] {
        var changed: [SourceFile] = []
        for (i, f) in files.enumerated() {
            let d = Self.modificationDate(f.url)
            if d != f.modDate {
                if !settled, let d, Date().timeIntervalSince(d) < 0.3 { continue } // still being written
                files[i] = d == nil ? SourceFile(url: f.url, modules: [], errors: ["File not found"], modDate: nil) : Self.load(f.url)
                changed.append(files[i])
            }
        }
        return changed
    }
}
