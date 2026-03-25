// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.5"),
        .package(path: "../../tools/audiotap"),
    ],
    targets: [
        .target(
            name: "MeetingTranscriber",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "AudioTapLib", package: "audiotap"),
            ],
            path: "Sources",
            exclude: ["Info.plist", "App"]
        ),
        .executableTarget(
            name: "MeetingTranscriberApp",
            dependencies: ["MeetingTranscriber"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "MeetingTranscriberTests",
            dependencies: ["MeetingTranscriber", "ViewInspector"],
            path: "Tests",
            exclude: ["Fixtures"]
        ),
    ]
)
