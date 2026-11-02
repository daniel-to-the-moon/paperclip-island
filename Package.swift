// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaperclipIsland",
    platforms: [.macOS(.v14)],
    products: [.library(name: "IslandCore", targets: ["IslandCore"])],
    dependencies: [],
    targets: [
        .target(name: "IslandCore"),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"])
    ]
)
