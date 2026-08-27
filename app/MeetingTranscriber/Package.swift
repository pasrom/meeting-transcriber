// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.3"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.1"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        // Upper bound, not a preference: 0.15.6 adds a Rust static library
        // (NemoTextProcessing) whose `_rust_eh_personality` is a fourth
        // exception personality routine in the linked image. Apple's compact
        // unwind format encodes three (`UNWIND_PERSONALITY_MASK` is a two bit
        // index, 0 means none), so the ThreadSanitizer build stops linking:
        // C++ and Rust come from FluidAudio itself, Objective-C from our
        // AVFAudio exception wrapper, and ThreadSanitizer injects the fourth.
        // The regular build still links because it sits at exactly three.
        //
        // Measured: Apple's ld fails the same on Xcode 26.6 and the 27.0 beta,
        // and `-Wl,-no_compact_unwind` links but then aborts on the first
        // exception. Lift this bound once FluidAudio offers a way to link
        // without that archive, or ships it as a dynamic library.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", "0.13.4" ..< "0.15.6"),
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
