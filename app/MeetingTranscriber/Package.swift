// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MeetingTranscriber",
            path: "Sources",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "MeetingTranscriberTests",
            dependencies: ["MeetingTranscriber"],
            path: "Tests"
        ),
    ]
)
