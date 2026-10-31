// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HDLViewer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "HDLViewer",
            path: "Sources/HDLViewer",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ],
    swiftLanguageModes: [.v5]
)
