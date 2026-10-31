import AppKit
import Foundation
import Observation

/// Finds Icarus Verilog.
@MainActor
@Observable
final class Tools {
    var iverilog: String?
    var vvp: String?
    var version: String?
    var checked = false

    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    func detect() {
        let custom = UserDefaults.standard.string(forKey: "iverilogPath")?.trimmingCharacters(in: .whitespaces) ?? ""
        var candidates: [String] = []
        if !custom.isEmpty {
            candidates.append(custom.hasSuffix("iverilog") ? custom : (custom as NSString).appendingPathComponent("iverilog"))
        }
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        candidates += (Self.searchDirs + path).map { ($0 as NSString).appendingPathComponent("iverilog") }
        let fm = FileManager.default
        iverilog = candidates.first { fm.isExecutableFile(atPath: $0) }
        if let iv = iverilog {
            let v = ((iv as NSString).deletingLastPathComponent as NSString).appendingPathComponent("vvp")
            vvp = fm.isExecutableFile(atPath: v) ? v : nil
        } else {
            vvp = nil
        }
        version = nil
        checked = true
        guard let iv = iverilog else { return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: iv)
            p.arguments = ["-V"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let first = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
            // "Icarus Verilog version 12.0 (stable) ()"
            let ver = first.components(separatedBy: "version ").dropFirst().first?.split(separator: " ").first.map(String.init)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.version = ver ?? "?" }
            }
        }
    }
}

/// Collects a process's output into whole lines.
private final class LineCollector: @unchecked Sendable {
    private var carry = ""
    let lock = NSLock()

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

@MainActor
enum Runner {
    static func outputDir(for doc: TestDocument) -> URL {
        if let d = doc.state.outputDir, !d.isEmpty { return URL(fileURLWithPath: d) }
        let name = Fmt.identifier(doc.state.name)
        if let f = doc.fileURL {
            return f.deletingLastPathComponent().appendingPathComponent(name + "_sim")
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return docs.appendingPathComponent("HDL Simulator").appendingPathComponent(name)
    }

    /// Writes the testbench only.
    static func export(_ doc: TestDocument, model: AppModel) -> URL? {
        let gen = model.generator(for: doc).generate()
        let dir = outputDir(for: doc)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(gen.topName + ".v")
            try gen.source.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            doc.appendLog(.error, "Could not write the testbench: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    static func run(_ doc: TestDocument, model: AppModel) async -> Bool {
        guard !doc.status.isRunning else { return false }
        let started = Date()
        doc.log = []
        doc.lastVCD = nil
        doc.lastRunSeconds = nil
        doc.status = .compiling
        model.panelTab = .output
        model.showPanel = true

        let tools = model.tools
        if !tools.checked { tools.detect() }
        guard let iverilog = tools.iverilog, let vvp = tools.vvp else {
            doc.appendLog(.error, "Icarus Verilog was not found. Install it with:  brew install icarus-verilog")
            doc.appendLog(.info, "Or set its location in Settings (⌘,).")
            doc.status = .failed("Icarus Verilog not found")
            return false
        }

        let gen = model.generator(for: doc).generate()
        let errors = gen.problems.filter { $0.severity == .error }
        for p in gen.problems {
            doc.appendLog(p.severity == .error ? .error : .warning, (p.severity == .error ? "error: " : "warning: ") + p.message)
        }
        guard errors.isEmpty else {
            doc.appendLog(.error, "Fix the problems above and run again.")
            doc.status = .failed("\(errors.count) problem\(errors.count == 1 ? "" : "s")")
            return false
        }

        let dir = outputDir(for: doc)
        let tbURL = dir.appendingPathComponent(gen.topName + ".v")
        let simURL = dir.appendingPathComponent(gen.topName + ".vvp")
        let vcdURL = dir.appendingPathComponent(gen.vcdName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try gen.source.write(to: tbURL, atomically: true, encoding: .utf8)
        } catch {
            doc.appendLog(.error, "Could not write \(tbURL.path): \(error.localizedDescription)")
            doc.status = .failed("Could not write testbench")
            return false
        }
        doc.appendLog(.info, "Testbench written to \(tbURL.path)")

        var args = ["-g2012", "-o", simURL.path, "-s", gen.topName]
        var dirs: [String] = []
        for f in gen.sourceFiles + model.library.files.map(\.url) {
            let d = f.deletingLastPathComponent().path
            if !dirs.contains(d) { dirs.append(d) }
        }
        for d in dirs { args += ["-I", d] }
        for d in dirs { args += ["-y", d] }
        args += ["-Y", ".v", "-Y", ".sv"]
        args.append(tbURL.path)
        args += gen.sourceFiles.map(\.path)

        doc.appendLog(.command, "$ iverilog " + args.map(shellQuote).joined(separator: " "))
        let compileStatus = await exec(iverilog, args, cwd: dir, doc: doc)
        guard doc.status != .stopped else { return false }
        guard compileStatus == 0 else {
            doc.appendLog(.error, "Compile failed (iverilog exited with \(compileStatus)).")
            doc.status = .failed("Compile failed")
            return false
        }

        try? FileManager.default.removeItem(at: vcdURL)
        doc.status = .simulating
        doc.appendLog(.command, "$ vvp -n \(shellQuote(simURL.lastPathComponent))")
        let simStatus = await exec(vvp, ["-n", simURL.path], cwd: dir, doc: doc)
        guard doc.status != .stopped else { return false }
        doc.lastRunSeconds = Date().timeIntervalSince(started)
        guard simStatus == 0 else {
            doc.appendLog(.error, "Simulation failed (vvp exited with \(simStatus)).")
            doc.status = .failed("Simulation failed")
            return false
        }

        if FileManager.default.fileExists(atPath: vcdURL.path) {
            doc.lastVCD = vcdURL
            doc.appendLog(.success, "✓ Waveform saved to \(vcdURL.path)")
            if doc.state.autoOpenVCD && model.openResultsInViewer { openInViewer(vcdURL) }
        } else {
            doc.appendLog(.warning, "The simulation finished but no waveform file was written.")
        }
        doc.status = .passed
        return true
    }

    static func stop(_ doc: TestDocument) {
        guard doc.status.isRunning else { return }
        doc.status = .stopped
        doc.process?.terminate()
        doc.appendLog(.warning, "Stopped.")
    }

    static func shellQuote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a tool, streaming its output into the test's log.
    static func exec(_ exe: String, _ args: [String], cwd: URL, doc: TestDocument) async -> Int32 {
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
                        MainActor.assumeIsolated { for l in rest { doc.appendLog(.stdout, l) } }
                        group.leave()
                    }
                    return
                }
                let lines = collector.feed(String(decoding: data, as: UTF8.self))
                guard !lines.isEmpty else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { for l in lines { doc.appendLog(.stdout, l) } }
                }
            }
            p.terminationHandler = { _ in group.leave() }
            group.notify(queue: .main) {
                MainActor.assumeIsolated { doc.process = nil }
                cont.resume(returning: p.terminationStatus)
            }
            do {
                try p.run()
                doc.process = p
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                doc.appendLog(.error, "Could not start \(exe): \(error.localizedDescription)")
                cont.resume(returning: -1)
            }
        }
    }

    static var viewerURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.emman.hdlviewer")
    }

    static func openInViewer(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let app = viewerURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
