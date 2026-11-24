// swift-tools-version: 6.2

import PackageDescription

// Type-check gate for both targets. Surfaces accidental compile-time blowups:
// pathological generic-overload search or deeply nested SwiftUI builders take
// seconds to type-check.
//
// 1000 ms, not the 100 ms often recommended, because the timer also counts the
// lazy `@Observable` expansion of a type declared in another file, charged to
// whichever body first touches it in a compile job. For `AppSettings` and
// `PipelineQueue` that is about 50 to 70 ms each on an M-series Mac, so a
// 10-line body that touches both measures over 100 ms on its own, and 300 to
// 430 ms on a loaded CI runner while the body itself takes 1 ms. Rewriting the
// body only moves the cost to the next first toucher.
//
// The expression timer is charged the same way (53 ms on the first
// `settings.watchApps` expression in `defaultDetectors`), so both flags move
// together. Raised from 300 ms.
let typeCheckGate: SwiftSetting = .unsafeFlags([
    "-Xfrontend", "-warn-long-function-bodies=1000",
    "-Xfrontend", "-warn-long-expression-type-checking=1000",
])

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.5"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.1"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        // Floor 0.17.4, for two reasons. API: `Nemotron3Diarizer` streaming
        // (`appendAudio` / `finishStream`) exists since 0.17.0. Behaviour:
        // the Nemotron 3 bundles that 0.17.0 to 0.17.3 load do not compile for
        // the Neural Engine on M3-class Macs (upstream issue 951); 0.17.2
        // stops the resulting first-prediction failure by retrying without the
        // fixed output buffers, and 0.17.4 loads the re-exported
        // `monolithic/v2` bundles that compile there. It also keeps the older
        // 0.15.5 floor, below which the offline diarizer silently ignores the
        // `computeUnits` passed to `prepareModels` and falls back to Metal.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
        .package(path: "../../tools/audiotap"),
    ],
    targets: [
        // LocalVQE echo-cancellation library (C API over a static xcframework).
        // SwiftPM downloads the artifact from a pinned release asset and
        // verifies it against the checksum before linking; no binary lives in
        // this repository. The artifact is genuinely static — the linked app
        // gains no new dynamic-library dependencies (otool -L shows system
        // libraries only).
        // Hosted on a release of our own vendor repository because upstream
        // publishes no macOS artifact at all. Checksum-pinned, so a swapped
        // asset fails the build rather than shipping silently; the exposure
        // that remains is availability, since the asset disappearing breaks
        // `swift build` for everyone including CI. Mirror it before relying on
        // this for a release.
        //
        // Its headers sit in `Headers/CLocalVQE/`, not at the root of
        // `Headers/`, and a rebuild must keep it that way. For a static-library
        // slice xcodebuild stages every artifact's `Headers/*` into one shared
        // `include/` directory, so two xcframeworks with a root-level
        // `module.modulemap` write the same path and the build dies with
        // "Multiple commands produce". FluidAudio started shipping a binary
        // target in 0.15.6 and hit exactly that. `swift build` never noticed,
        // because it passes each artifact's Headers directory as its own `-I`,
        // which is why this can only fail in Xcode and in the analyze lane.
        .binaryTarget(
            name: "CLocalVQE",
            url: "https://github.com/pasrom/localvqe-xcframework/releases/download/1.0.3/LocalVQE.xcframework.zip",
            checksum: "15a7503e7d764012ee955ba04cef78a0b24f8d51856fc85b96d9be49d38624ba"
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
            // Assets.xcassets is never compiled as a catalog, by SPM or anything
            // else: scripts/build_release.sh copies the PNGs out of its
            // AppIcon.appiconset and turns them into AppIcon.icns with
            // `iconutil -c icns`. Excluding it silences "unhandled file" warnings
            // without changing the runtime bundle.
            exclude: ["Info.plist", "Assets.xcassets"],
            // Treat any new compiler warning as a build failure so deprecations
            // and concurrency hints are caught at PR time, not on a future
            // dependency bump. Scoped to our targets only — does not propagate
            // to WhisperKit/FluidAudio.
            swiftSettings: [
                .treatAllWarnings(as: .error),
                typeCheckGate,
                .enableUpcomingFeature("ExistentialAny"),
            ],
            linkerSettings: [
                // CLocalVQE is C++ inside and uses Accelerate for its FFT.
                // A static archive carries no autolink hints, so the consumer
                // has to name both dependencies explicitly (proven necessary
                // in the vendoring link spike).
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
                typeCheckGate,
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
