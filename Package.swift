// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    .target(name: "LoveployCore"),
    .testTarget(name: "LoveployCoreTests", dependencies: ["LoveployCore"]),
]
var products: [Product] = [
    .library(name: "LoveployCore", targets: ["LoveployCore"]),
]

// The menu bar app itself needs AppKit/SwiftUI, so it only exists on macOS.
// The core (API client, state, logic) also builds on Linux for CI and tests.
#if os(macOS)
targets.append(.executableTarget(name: "Loveploy", dependencies: ["LoveployCore"]))
products.append(.executable(name: "Loveploy", targets: ["Loveploy"]))
#endif

let package = Package(
    name: "Loveploy",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
