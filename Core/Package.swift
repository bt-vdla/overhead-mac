// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OverheadCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "OverheadCore", targets: ["OverheadCore"])],
    targets: [
        .target(name: "OverheadCore"),
        .testTarget(name: "OverheadCoreTests", dependencies: ["OverheadCore"]),
    ]
)
