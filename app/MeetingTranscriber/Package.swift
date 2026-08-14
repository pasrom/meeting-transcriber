// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.3"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.1"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.4"),
        .package(path: "../../tools/audiotap"),
    ],
    targets: [
        // Prebuilt LocalVQE echo canceller (Apache-2.0, GGML inference).
        // Fetched from a dedicated vendor repository rather than committed, so
        // nothing binary enters this repository's history and the artifact
        // stays reproducible from the upstream commits its build pins.
        // The model weights are NOT in here — this is a static library, which
        // cannot carry resources; see `EchoCancellerModel` for how they arrive.
        .binaryTarget(
            name: "CLocalVQE",
            url: "https://github.com/pasrom/localvqe-xcframework/releases/download/1.0.2/LocalVQE.xcframework.zip",
            checksum: "c0b0f41245611cca194ed279096d4729f87aba1f59cf92972383bff0f8e903c1",
        ),
        .executableTarget(
            name: "MeetingTranscriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "AudioTapLib", package: "audiotap"),
                "CLocalVQE",
            ],
            path: "Sources",
            // Assets.xcassets is compiled by `actool` in scripts/build_release.sh,
            // not by SPM. Excluding silences "unhandled file" warnings without
            // changing the runtime bundle.
            exclude: ["Info.plist", "Assets.xcassets"],
            // Treat any new compiler warning as a build failure so deprecations
            // and concurrency hints are caught at PR time, not on a future
            // dependency bump. Scoped to our targets only — does not propagate
            // to WhisperKit/FluidAudio.
            swiftSettings: [
                .treatAllWarnings(as: .error),
                // Surface accidental compile-time blowups. Type-checking a
                // function body or expression beyond 300 ms is almost always
                // a sign of pathological generic-overload search or deeply
                // nested SwiftUI builders. Apple recommends 100 ms; 300 ms
                // is the historical pre-Swift-6 setting that turned out to
                // be sustainable once strict-concurrency analysis settled.
                .unsafeFlags([
                    "-Xfrontend", "-warn-long-function-bodies=300",
                    "-Xfrontend", "-warn-long-expression-type-checking=300",
                ]),
                .enableUpcomingFeature("ExistentialAny"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "MeetingTranscriberTests",
            dependencies: [
                "MeetingTranscriber",
                "ViewInspector",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests",
            // __Snapshots__ is the SnapshotTesting reference-image directory.
            // Tests load these via filesystem path at runtime, not via the
            // bundle, so SPM doesn't need to package them as resources.
            exclude: ["Fixtures", "__Snapshots__"],
            swiftSettings: [
                .treatAllWarnings(as: .error),
                .unsafeFlags([
                    "-Xfrontend", "-warn-long-function-bodies=300",
                    "-Xfrontend", "-warn-long-expression-type-checking=300",
                ]),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
