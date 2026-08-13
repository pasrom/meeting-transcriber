// swift-tools-version: 6.2
import PackageDescription

// The same gate the app package runs under. `treatAllWarnings(as:)` is what
// pins the manifest to tools-version 6.2; it does not exist in 6.0.
let strictSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=300",
        "-Xfrontend", "-warn-long-expression-type-checking=300",
    ]),
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
