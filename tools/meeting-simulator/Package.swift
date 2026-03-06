// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "meeting-simulator",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "meeting-simulator", path: "Sources"),
    ]
)
