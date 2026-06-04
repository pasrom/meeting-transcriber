// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioTapLib",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioTapLib", targets: ["AudioTapLib"]),
    ],
    targets: [
        // Objective-C shim that bridges NSExceptions (e.g. from
        // installTapOnBus) into Swift-catchable NSErrors. See header.
        .target(
            name: "CExceptionCatcher",
            path: "Sources/CExceptionCatcher"
        ),
        .target(
            name: "AudioTapLib",
            dependencies: ["CExceptionCatcher"],
            path: "Sources",
            exclude: ["CExceptionCatcher"]
        ),
        .testTarget(
            name: "AudioTapLibTests",
            dependencies: ["AudioTapLib", "CExceptionCatcher"],
            path: "Tests"
        ),
    ]
)
