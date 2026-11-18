// swift-tools-version: 6.2
import PackageDescription

// The app package's warnings-as-errors gate, with its type-check limit at
// 300 ms: the app raises its own to 1000 ms because of its large `@Observable`
// types (reason in app/MeetingTranscriber/Package.swift), which this package
// does not have. `treatAllWarnings(as:)` is what
// pins the manifest to tools-version 6.2; it does not exist in 6.0.
let strictSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=300",
        "-Xfrontend", "-warn-long-expression-type-checking=300",
    ]),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "mt-cli",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "mt-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources",
            swiftSettings: strictSwiftSettings,
        ),
        .testTarget(
            name: "mt-cli-tests",
            dependencies: ["mt-cli"],
            path: "Tests",
            swiftSettings: strictSwiftSettings,
        ),
    ],
)
