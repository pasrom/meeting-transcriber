// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioTapLib",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioTapLib", targets: ["AudioTapLib"]),
    ],
    targets: [
        .target(
            name: "AudioTapLib",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
