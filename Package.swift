// swift-tools-version: 6.0
// This package exists only so `swift test` can exercise the pure-logic code in Shared/.
// The Xcode project compiles the same Shared/ files directly into both app targets.
import PackageDescription

let package = Package(
    name: "UsageCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "UsageCore", targets: ["UsageCore"])],
    targets: [
        .target(name: "UsageCore", path: "Shared"),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ],
    swiftLanguageModes: [.v5]
)
