// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingTranscriber",
            path: "Sources",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "MeetingTranscriberTests",
            dependencies: ["MeetingTranscriber", "ViewInspector"],
            path: "Tests"
        ),
    ]
)
