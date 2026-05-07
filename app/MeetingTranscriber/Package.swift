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
        .executableTarget(
            name: "MeetingTranscriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "AudioTapLib", package: "audiotap"),
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
                // nested SwiftUI builders. 300 ms instead of Apple's
                // recommended 100 ms gives headroom for cold CI runners; can
                // be tightened later.
                .unsafeFlags([
                    "-Xfrontend", "-warn-long-function-bodies=300",
                    "-Xfrontend", "-warn-long-expression-type-checking=300",
                ]),
                .enableUpcomingFeature("ExistentialAny"),
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
    // Pin Swift 5 language mode. Tools-version 6.2 defaults to Swift 6 mode,
    // which enables full strict-concurrency checks — that migration is
    // tracked separately (see strict-warnings escalation plan, Stufe 5).
    // Bumping the manifest API to 6.2 only to get `treatAllWarnings(as:)`.
    swiftLanguageModes: [.v5]
)
