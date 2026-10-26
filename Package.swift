// swift-tools-version:6.0
import PackageDescription

var targets: [Target] = [
    .target(name: "LoveployCore"),
    .testTarget(name: "LoveployCoreTests", dependencies: ["LoveployCore"]),
]
var products: [Product] = [
    .library(name: "LoveployCore", targets: ["LoveployCore"]),
]
var dependencies: [Package.Dependency] = []

// The menu bar app itself needs AppKit/SwiftUI, so it only exists on macOS.
// The core (clients, state, logic) also builds on Linux for CI and tests.
#if os(macOS)
// SwiftTerm: the terminal panes of session groups (MIT).
dependencies.append(.package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.20.0")))
targets.append(.executableTarget(
    name: "Loveploy",
    dependencies: ["LoveployCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
))
products.append(.executable(name: "Loveploy", targets: ["Loveploy"]))
#endif

let package = Package(
    name: "Loveploy",
    // macOS 15: the account manager (MultiClaude) uses its APIs.
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    // Swift 5 language mode: the account manager is written for it.
    swiftLanguageModes: [.v5]
)
