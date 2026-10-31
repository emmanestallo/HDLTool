import AppKit
import Foundation
import Observation

enum Severity: Int, Codable, Comparable {
    case error, warning, info
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var icon: String {
        switch self {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

struct Diagnostic: Identifiable, Hashable, Codable {
    var id = UUID()
    var file: String        // path, or "untitled:<uuid>"
    var line: Int           // 1-based
    var column: Int?        // 1-based
    var severity: Severity
    var message: String
    var source: String
}

/// Finds the simulators and linters.
@MainActor
@Observable
final class Tools {
    var iverilog: String?
    var vvp: String?
    var iverilogVersion: String?
    var verilator: String?
    var ghdl: String?
    var checked = false

    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", NSHomeDirectory() + "/.local/bin"]

    private func find(_ exe: String, custom: String?) -> String? {
        var candidates: [String] = []
        if let c = custom?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            candidates.append(c.hasSuffix(exe) ? c : (c as NSString).appendingPathComponent(exe))
        }
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        candidates += (Self.searchDirs + path).map { ($0 as NSString).appendingPathComponent(exe) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func detect() {
        let custom = UserDefaults.standard.string(forKey: "iverilogPath")
        iverilog = find("iverilog", custom: custom)
        if let iv = iverilog {
            let v = ((iv as NSString).deletingLastPathComponent as NSString).appendingPathComponent("vvp")
            vvp = FileManager.default.isExecutableFile(atPath: v) ? v : find("vvp", custom: nil)
        } else {
            vvp = nil
        }
        verilator = find("verilator", custom: UserDefaults.standard.string(forKey: "verilatorPath"))
        ghdl = find("ghdl", custom: UserDefaults.standard.string(forKey: "ghdlPath"))
        iverilogVersion = nil
        checked = true
        guard let iv = iverilog else { return }
        Task.detached {
            let out = (try? ProcessRunner.capture(iv, ["-V"], timeout: 5)) ?? ""
            let first = out.split(separator: "\n").first.map(String.init) ?? ""
            let ver = first.components(separatedBy: "version ").dropFirst().first?.split(separator: " ").first.map(String.init)
            await MainActor.run { self.iverilogVersion = ver ?? "?" }
        }
    }
}

/// Runs a command and collects its output (off the main thread).
enum ProcessRunner {
    struct Failure: Error {}

    static func capture(_ exe: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = 30) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (exe as NSString).deletingLastPathComponent + ":/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum Linter {
    enum Kind: String, CaseIterable, Identifiable {
        case auto, iverilog, verilator, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Automatic"
            case .iverilog: return "Icarus Verilog"
            case .verilator: return "Verilator"
            case .off: return "Off"
            }
        }
    }

    struct Job: Sendable {
        var key: String              // diagnostics key of the document
        var fileName: String
        var text: String
        var originalPath: String?
        var language: HDLLanguage
        var deps: [String]           // other files that define instantiated modules
        var includeDirs: [String]
        var iverilog: String?
        var verilator: String?
        var ghdl: String?
        var kind: Kind
        var standard: String         // -g2012 etc.
    }

    struct Result: Sendable {
        var key: String
        var diagnostics: [Diagnostic]
        var tool: String
    }

    static var tempRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HDLCoder").appendingPathComponent("lint")
    }

    /// Lints the buffer contents by writing them to a temporary copy.
    static func run(_ job: Job) -> Result? {
        let fm = FileManager.default
        let dir = tempRoot.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let tmp = dir.appendingPathComponent(job.fileName)
        guard (try? job.text.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return nil }
        var map: [String: String] = [:]
        map[tmp.path] = job.key
        map[tmp.resolvingSymlinksInPath().path] = job.key
        map[tmp.standardizedFileURL.path] = job.key
        if let o = job.originalPath { map[o] = job.key }

        if job.language == .vhdl {
            guard let ghdl = job.ghdl, job.kind != .off else { return nil }
            let out = (try? ProcessRunner.capture(ghdl, ["-s", "--std=08", "-fsynopsys", tmp.path], cwd: dir, timeout: 20)) ?? ""
            return Result(key: job.key, diagnostics: parseGHDL(out, map: map), tool: "ghdl")
        }

        var kind = job.kind
        if kind == .auto { kind = job.iverilog != nil ? .iverilog : (job.verilator != nil ? .verilator : .off) }
        switch kind {
        case .verilator:
            guard let v = job.verilator else { return nil }
            var args = ["--lint-only", "-Wall", "-Wno-DECLFILENAME", "-Wno-MULTITOP", "-Wno-EOFNEWLINE", "--timing"]
            if job.language == .systemVerilog || job.fileName.hasSuffix(".sv") { args.append("-sv") }
            for d in job.includeDirs { args.append("-I" + d) }
            args.append(tmp.path)
            args += job.deps
            let out = (try? ProcessRunner.capture(v, args, cwd: dir, timeout: 30)) ?? ""
            return Result(key: job.key, diagnostics: parseVerilator(out, map: map), tool: "verilator")
        case .iverilog:
            guard let iv = job.iverilog else { return nil }
            var args = [job.standard, "-Wall", "-Wno-timescale", "-Wno-implicit-dimensions", "-t", "null"]
            for d in job.includeDirs { args += ["-I", d] }
            args.append(tmp.path)
            args += job.deps
            let out = (try? ProcessRunner.capture(iv, args, cwd: dir, timeout: 30)) ?? ""
            return Result(key: job.key, diagnostics: parseIverilog(out, map: map), tool: "iverilog")
        default:
            return nil
        }
    }

    private static func mapPath(_ p: String, _ map: [String: String]) -> String {
        if let m = map[p] { return m }
        let std = URL(fileURLWithPath: p).standardizedFileURL.path
        if let m = map[std] { return m }
        if let m = map[URL(fileURLWithPath: p).resolvingSymlinksInPath().path] { return m }
        return std
    }

    static let iverilogLine = try! NSRegularExpression(pattern: #"^(.+?):(\d+):\s*(.*)$"#)

    static func parseIverilog(_ out: String, map: [String: String]) -> [Diagnostic] {
        var diags: [Diagnostic] = []
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            guard let m = iverilogLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let path = ns.substring(with: m.range(at: 1))
            guard path.contains("/") || path.contains("."), !path.hasPrefix(" ") else { continue }
            let ln = Int(ns.substring(with: m.range(at: 2))) ?? 1
            var msg = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            var sev: Severity = .error
            let lower = msg.lowercased()
            if lower.hasPrefix("error:") { msg = String(msg.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if lower.hasPrefix("warning:") { sev = .warning; msg = String(msg.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if lower.hasPrefix("sorry:") { sev = .warning; msg = "Not supported by Icarus: " + String(msg.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if lower.hasPrefix("syntax error") { msg = "Syntax error" }
            else if lower.hasPrefix(":") || lower.isEmpty {
                sev = .info
                msg = String(msg.drop { $0 == ":" || $0 == " " })
                if msg.isEmpty { continue }
            } else if lower.contains("warning") { sev = .warning }
            let file = mapPath(path, map)
            // iverilog often prints "syntax error" followed by a more specific error on the same line.
            if let last = diags.last, last.file == file, last.line == ln, last.message == "Syntax error", sev == .error {
                diags[diags.count - 1].message = "Syntax error: " + msg
                continue
            }
            let d = Diagnostic(file: file, line: ln, column: nil, severity: sev, message: msg, source: "iverilog")
            if !diags.contains(where: { $0.file == d.file && $0.line == d.line && $0.message == d.message }) { diags.append(d) }
        }
        return diags
    }

    static let verilatorLine = try! NSRegularExpression(pattern: #"^%(Error|Warning)(-[A-Z0-9_]+)?: (.+?):(\d+):(?:(\d+):)? (.*)$"#)

    static func parseVerilator(_ out: String, map: [String: String]) -> [Diagnostic] {
        var diags: [Diagnostic] = []
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            guard let m = verilatorLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let sev: Severity = ns.substring(with: m.range(at: 1)) == "Error" ? .error : .warning
            let code = m.range(at: 2).location != NSNotFound ? String(ns.substring(with: m.range(at: 2)).dropFirst()) : ""
            let file = mapPath(ns.substring(with: m.range(at: 3)), map)
            let ln = Int(ns.substring(with: m.range(at: 4))) ?? 1
            let col = m.range(at: 5).location != NSNotFound ? Int(ns.substring(with: m.range(at: 5))) : nil
            let msg = ns.substring(with: m.range(at: 6)) + (code.isEmpty ? "" : "  [\(code)]")
            diags.append(Diagnostic(file: file, line: ln, column: col, severity: sev, message: msg, source: "verilator"))
        }
        return diags
    }

    static let ghdlLine = try! NSRegularExpression(pattern: #"^(.+?):(\d+):(\d+):\s*(?:(error|warning|note):)?\s*(.*)$"#)

    static func parseGHDL(_ out: String, map: [String: String]) -> [Diagnostic] {
        var diags: [Diagnostic] = []
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            guard let m = ghdlLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let file = mapPath(ns.substring(with: m.range(at: 1)), map)
            let kind = m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)) : "error"
            let sev: Severity = kind == "warning" ? .warning : (kind == "note" ? .info : .error)
            diags.append(Diagnostic(file: file, line: Int(ns.substring(with: m.range(at: 2))) ?? 1,
                                    column: Int(ns.substring(with: m.range(at: 3))), severity: sev,
                                    message: ns.substring(with: m.range(at: 5)), source: "ghdl"))
        }
        return diags
    }
}

// MARK: - Output log

struct LogLine: Identifiable {
    enum Kind { case info, command, stdout, error, warning, success }
    let id = UUID()
    let kind: Kind
    let text: String
    var link: (path: String, line: Int)? = nil
}

/// Collects a process's output into whole lines.
final class LineCollector: @unchecked Sendable {
    private var carry = ""
    private let lock = NSLock()

    func feed(_ s: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        carry += s
        var lines = carry.components(separatedBy: "\n")
        carry = lines.removeLast()
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        defer { carry = "" }
        return carry.isEmpty ? [] : [carry]
    }
}

enum RunStatus: Equatable {
    case idle, compiling, simulating, passed, failed(String), stopped
    var isRunning: Bool { self == .compiling || self == .simulating }
}

/// Compiles and simulates with Icarus Verilog (or GHDL for VHDL).
@MainActor
enum Simulator {
    static func shellQuote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a tool, streaming its output into the app's output log.
    static func exec(_ exe: String, _ args: [String], cwd: URL, model: AppModel) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (exe as NSString).deletingLastPathComponent + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice

            let collector = LineCollector()
            let group = DispatchGroup()
            group.enter()
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    let rest = collector.flush()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { for l in rest { model.appendOutput(.stdout, l, cwd: cwd) } }
                        group.leave()
                    }
                    return
                }
                let lines = collector.feed(String(decoding: data, as: UTF8.self))
                guard !lines.isEmpty else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { for l in lines { model.appendOutput(.stdout, l, cwd: cwd) } }
                }
            }
            p.terminationHandler = { _ in group.leave() }
            group.notify(queue: .main) {
                MainActor.assumeIsolated { model.process = nil }
                cont.resume(returning: p.terminationStatus)
            }
            do {
                try p.run()
                model.process = p
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                model.appendOutput(.error, "Could not start \(exe): \(error.localizedDescription)")
                cont.resume(returning: -1)
            }
        }
    }

    static func stop(_ model: AppModel) {
        guard model.runStatus.isRunning else { return }
        model.runStatus = .stopped
        model.process?.terminate()
        model.appendOutput(.warning, "Stopped.")
    }

    static var viewerURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.emman.hdlviewer") }
    static var testerURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.emman.hdltester") }

    static func openInViewer(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let app = viewerURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func openInTester(_ urls: [URL]) -> Bool {
        guard let app = testerURL else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: cfg)
        return true
    }

    /// The `$dumpfile("...")` names used in the sources.
    static func dumpFiles(in texts: [String]) -> [String] {
        let re = try! NSRegularExpression(pattern: #"\$dumpfile\s*\(\s*"([^"]+)""#)
        var out: [String] = []
        for t in texts {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                out.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return out
    }

    /// The `include "x"` file names used in a source.
    static func includes(in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"`include\s+"([^"]+)""#)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func run(doc: EditorDocument, model: AppModel) async {
        guard !model.runStatus.isRunning else { return }
        guard let url = doc.url else {
            model.appendOutput(.error, "Save the file before running it.")
            return
        }
        let started = Date()
        model.output = []
        model.lastVCD = nil
        model.runStatus = .compiling
        model.panelTab = .output
        model.showPanel = true
        let tools = model.tools
        if !tools.checked { tools.detect() }

        let symbols = doc.symbols
        let cwd = url.deletingLastPathComponent()
        let outDir = cwd.appendingPathComponent("sim_out")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        if doc.language == .vhdl {
            await runGHDL(doc: doc, url: url, cwd: cwd, outDir: outDir, model: model, started: started)
            return
        }
        guard let iverilog = tools.iverilog, let vvp = tools.vvp else {
            model.appendOutput(.error, "Icarus Verilog was not found. Install it with:  brew install icarus-verilog")
            model.appendOutput(.info, "Or set its location in Settings (⌘,).")
            model.runStatus = .failed("Icarus Verilog not found")
            return
        }
        // Top module: one that no other module in this file instantiates; prefer one without ports.
        let modules = symbols.filter { $0.kind == .module || $0.kind == .program }
        guard !modules.isEmpty else {
            model.appendOutput(.error, "No module found in \(url.lastPathComponent).")
            model.runStatus = .failed("No module")
            return
        }
        let instantiated = Set(modules.flatMap { $0.children.filter { $0.kind == .instance }.compactMap(\.target) })
        let roots = modules.filter { !instantiated.contains($0.name) }
        let top = roots.first(where: { $0.ports.isEmpty }) ?? roots.first ?? modules[0]
        if !top.ports.isEmpty {
            model.appendOutput(.warning, "“\(top.name)” has ports, so it is not a testbench. Running it anyway — its inputs will float. Use “Generate Testbench” (⇧⌘G) to make one.")
        }
        let deps = model.dependencyFiles(for: doc)
        let vvpURL = outDir.appendingPathComponent(top.name + ".vvp")
        var args = [model.languageStandard, "-o", vvpURL.path, "-s", top.name]
        for d in model.includeDirs(for: doc) { args += ["-I", d] }
        args.append(url.path)
        args += deps
        model.appendOutput(.command, "$ iverilog " + args.map(shellQuote).joined(separator: " "))
        let compile = await exec(iverilog, args, cwd: cwd, model: model)
        guard model.runStatus != .stopped else { return }
        guard compile == 0 else {
            model.appendOutput(.error, "Compile failed (iverilog exited with \(compile)).")
            model.runStatus = .failed("Compile failed")
            return
        }
        model.runStatus = .simulating
        model.appendOutput(.command, "$ vvp -n \(shellQuote("sim_out/" + vvpURL.lastPathComponent))")
        let sim = await exec(vvp, ["-n", vvpURL.path], cwd: cwd, model: model)
        guard model.runStatus != .stopped else { return }
        model.lastRunSeconds = Date().timeIntervalSince(started)
        guard sim == 0 else {
            model.appendOutput(.error, "Simulation failed (vvp exited with \(sim)).")
            model.runStatus = .failed("Simulation failed")
            return
        }
        finish(texts: [doc.text] + deps.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }, cwd: cwd, started: started, model: model)
    }

    private static func finish(texts: [String], cwd: URL, started: Date, model: AppModel) {
        let fm = FileManager.default
        var vcd: URL? = nil
        for name in dumpFiles(in: texts) {
            let u = name.hasPrefix("/") ? URL(fileURLWithPath: name) : cwd.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { vcd = u; break }
        }
        if vcd == nil {
            for dir in [cwd, cwd.appendingPathComponent("sim_out")] {
                let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                let fresh = items.filter { $0.pathExtension.lowercased() == "vcd" || $0.pathExtension.lowercased() == "fst" }
                    .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= started.addingTimeInterval(-1) }
                if let f = fresh.first { vcd = f; break }
            }
        }
        if let vcd {
            model.lastVCD = vcd
            model.appendOutput(.success, "✓ Waveform written to \(vcd.path)")
            if model.openWaveformsInViewer { openInViewer(vcd) }
        } else {
            model.appendOutput(.info, "No waveform was written. Add $dumpfile/$dumpvars to the testbench (snippet “dump”) to get one.")
        }
        model.appendOutput(.success, String(format: "Simulation finished in %.2f s", model.lastRunSeconds ?? 0))
        model.runStatus = .passed
    }

    private static func runGHDL(doc: EditorDocument, url: URL, cwd: URL, outDir: URL, model: AppModel, started: Date) async {
        guard let ghdl = model.tools.ghdl else {
            model.appendOutput(.error, "GHDL was not found. Install it to simulate VHDL (for example: brew install ghdl).")
            model.runStatus = .failed("GHDL not found")
            return
        }
        let entities = doc.symbols.filter { $0.kind == .entity }
        guard let top = entities.first(where: { $0.ports.isEmpty }) ?? entities.first else {
            model.appendOutput(.error, "No entity found in \(url.lastPathComponent).")
            model.runStatus = .failed("No entity")
            return
        }
        let deps = model.dependencyFiles(for: doc)
        let work = ["--std=08", "-fsynopsys", "--workdir=\(outDir.path)"]
        let analyze = work + deps + [url.path]
        model.appendOutput(.command, "$ ghdl -a " + analyze.map(shellQuote).joined(separator: " "))
        var st = await exec(ghdl, ["-a"] + analyze, cwd: cwd, model: model)
        guard st == 0, model.runStatus != .stopped else {
            if model.runStatus != .stopped { model.runStatus = .failed("Analysis failed") }
            return
        }
        model.appendOutput(.command, "$ ghdl -e \(top.name)")
        st = await exec(ghdl, ["-e"] + work + ["-o", outDir.appendingPathComponent(top.name.lowercased()).path, top.name], cwd: cwd, model: model)
        guard st == 0, model.runStatus != .stopped else {
            if model.runStatus != .stopped { model.runStatus = .failed("Elaboration failed") }
            return
        }
        model.runStatus = .simulating
        let vcd = outDir.appendingPathComponent(top.name.lowercased() + ".vcd")
        model.appendOutput(.command, "$ ghdl -r \(top.name) --vcd=sim_out/\(vcd.lastPathComponent)")
        st = await exec(ghdl, ["-r"] + work + [top.name, "--vcd=\(vcd.path)", "--stop-time=1ms"], cwd: cwd, model: model)
        guard model.runStatus != .stopped else { return }
        model.lastRunSeconds = Date().timeIntervalSince(started)
        if st != 0 {
            model.appendOutput(.error, "Simulation failed (ghdl exited with \(st)).")
            model.runStatus = .failed("Simulation failed")
            return
        }
        finish(texts: [], cwd: outDir, started: started, model: model)
    }
}
