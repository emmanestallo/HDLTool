// swift-tools-version:6.0
import PackageDescription

// HDL Simulator = HDL Coder + HDL Tester in one window.
// Each app lives in its own module so their types (AppModel, MainView, Theme…) don't clash.
// HDLShell holds what they share: the active tab and the descend/ascend stack.
let package = Package(
    name: "HDLSimulator",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "HDLShell", path: "Sources/HDLShell"),
        .target(name: "CoderKit", dependencies: ["HDLShell"], path: "Sources/CoderKit"),
        .target(name: "TesterKit", dependencies: ["HDLShell"], path: "Sources/TesterKit"),
        .executableTarget(
            name: "HDLSimulator",
            dependencies: ["HDLShell", "CoderKit", "TesterKit"],
            path: "Sources/HDLSimulator"
        ),
    ],
    swiftLanguageModes: [.v5]
)
