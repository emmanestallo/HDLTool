import Foundation
import Observation

/// The two tabs of the window.
public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case coder, tester

    public var id: String { rawValue }
    public var title: String { self == .coder ? "Coder" : "Tester" }
    public var icon: String { self == .coder ? "chevron.left.forwardslash.chevron.right" : "testtube.2" }
    public var shortcut: String { self == .coder ? "⌘1" : "⌘2" }
}

/// One level of the design hierarchy that Ascend can go back to.
public struct NavFrame: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        /// A test in the Tester, with the DUT that was descended into.
        case test(id: UUID, instance: UUID?)
        /// A place in a file in the Coder (UTF-16 offset).
        case file(path: String, offset: Int)
    }

    public var place: Place
    /// Shown in the Ascend button's tooltip, e.g. the test or module name.
    public var label: String
    /// The file that was opened by descending; Ascend from that file returns here.
    public var child: String

    public init(place: Place, label: String, child: String) {
        self.place = place
        self.label = label
        self.child = child
    }
}

/// State shared by the Coder and the Tester: which tab is showing and the descend/ascend stack.
/// Each module registers its handlers at start so neither has to know about the other.
@MainActor
@Observable
public final class Shell {
    public static let shared = Shell()

    public var tab: AppTab = .coder
    public private(set) var stack: [NavFrame] = []

    /// Coder: open a file, at a 1-based line or at a module's definition.
    @ObservationIgnored public var openInCoder: ((_ path: String, _ line: Int?, _ module: String?) -> Void)?
    /// Coder: put the caret at a UTF-16 offset in a file.
    @ObservationIgnored public var revealInCoder: ((_ path: String, _ offset: Int) -> Void)?
    /// Tester: show a test (and select a DUT). False if the test is gone.
    @ObservationIgnored public var showTest: ((_ test: UUID, _ instance: UUID?) -> Bool)?
    /// Tester: the open test that has `module` from `path` as a DUT, if any.
    @ObservationIgnored public var testbench: ((_ path: String, _ module: String?) -> NavFrame?)?
    /// Tester: open (or create) a test with `module` from `path` as its DUT.
    @ObservationIgnored public var generateTestbench: ((_ path: String, _ module: String) -> Void)?
    /// Tester: open files (.hdltest tests, or Verilog files for the DUT list).
    @ObservationIgnored public var openInTester: ((_ urls: [URL]) -> Void)?
    /// Called after the tab changes (the host moves keyboard focus).
    @ObservationIgnored public var tabChanged: ((AppTab) -> Void)?

    private init() {}

    public func show(_ t: AppTab) {
        guard tab != t else { return }
        tab = t
        tabChanged?(t)
    }

    // MARK: Hierarchy

    /// Remembers where we came from, then opens `path` in the Coder.
    public func descend(from frame: NavFrame, to path: String, line: Int? = nil, module: String? = nil) {
        stack.removeAll { $0 == frame }
        stack.append(frame)
        if stack.count > 64 { stack.removeFirst(stack.count - 64) }
        show(.coder)
        openInCoder?(path, line, module)
    }

    /// The level above the file at `path`: the frame it was descended from, else the test that uses its module.
    public func parent(of path: String, module: String?) -> NavFrame? {
        if let f = stack.last(where: { $0.child == path }) { return f }
        return testbench?(path, module)
    }

    /// Goes to the level above `path`. False if there is none.
    @discardableResult
    public func ascend(from path: String, module: String?) -> Bool {
        guard let f = parent(of: path, module: module) else { return false }
        if let i = stack.lastIndex(of: f) { stack.removeSubrange(i...) }
        return go(to: f)
    }

    @discardableResult
    public func go(to f: NavFrame) -> Bool {
        switch f.place {
        case .test(let id, let inst):
            guard showTest?(id, inst) == true else { return false }
            show(.tester)
        case .file(let path, let offset):
            show(.coder)
            revealInCoder?(path, offset)
        }
        return true
    }
}
