// swift-tools-version:5.10
import PackageDescription

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
        ),
        .testTarget(
            name: "mt-cli-tests",
            dependencies: ["mt-cli"],
            path: "Tests",
        ),
    ],
)
