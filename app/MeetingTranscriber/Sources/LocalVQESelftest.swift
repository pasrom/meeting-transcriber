// Hidden command-line probe (--localvqe-selftest [model.gguf]) that exercises
// the statically linked LocalVQE library from whatever location the executable
// was launched at. It answers the one question the SwiftPM link spike could
// not: does the library still resolve its compute backend when the binary
// lives in Contents/MacOS of a signed .app bundle? Driven by
// scripts/localvqe-bundle-check.sh; a normal GUI launch never enters it.
// Compiled out of the App Store variant (no bundle check exists for it, and
// the sandboxed build should carry no diagnostic entry points).
#if !APPSTORE
    import CLocalVQE
    import Foundation

    enum LocalVQESelftest {
        static let flag = "--localvqe-selftest"

        enum Mode: Equatable {
            /// Prove linking, backend registration, and error plumbing — no model.
            case linkOnly
            /// Additionally run synthetic audio through the full streaming seam.
            case model(path: String)
        }

        /// Returns the requested selftest mode, or nil for a normal GUI launch.
        /// The argument after the flag is a model path unless it is another
        /// flag; with no path the bundled model is used, and only a build that
        /// bundles none falls back to the link-only probe.
        ///
        /// `bundledModel` is a parameter rather than a resolver call so this
        /// stays pure: with a default it would read ambient bundle and
        /// environment state, and the link-only case would then pass or fail
        /// depending on what the surrounding test run had exported. It is
        /// autoclosed because the caller is the pre-GUI launch path and the
        /// flag is absent on every real launch — eagerly evaluated, a bundle
        /// scan and a stat would run before every window the user ever sees.
        static func parse(arguments: [String], bundledModel: @autoclosure () -> String?) -> Mode? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            if let next = arguments.dropFirst(index + 1).first, !next.hasPrefix("--") {
                return .model(path: next)
            }
            if let bundledModel = bundledModel() { return .model(path: bundledModel) }
            return .linkOnly
        }

        /// The synthetic far-end probe tone: a 440 Hz carrier with a slow
        /// amplitude wobble, capped at half scale so the half-level mic copy
        /// stays well inside the C API's [-1, 1] contract. Deliberately not
        /// EchoTestAudio (a test-target helper tuned for the echo-bleed
        /// detector's envelope correlation): the probe is a Sources-side link
        /// check and stays self-contained.
        static func probeFarEnd(seconds: Int) -> [Float] {
            let sampleRate = AudioConstants.targetSampleRate
            return (0 ..< seconds * sampleRate).map { sampleIndex in
                let t = Double(sampleIndex) / Double(sampleRate)
                let wobble = 0.6 + 0.4 * sin(2 * .pi * 1.3 * t)
                return Float(0.5 * wobble * sin(2 * .pi * 440 * t))
            }
        }

        /// Runs the probe and returns the process exit code. Prints its verdict to
        /// stdout; the library reports registered backends on stderr.
        static func run(_ mode: Mode) -> Int32 {
            print("localvqe-selftest: executable=\(CommandLine.arguments.first ?? "?")")
            // Prints every registered backend + device to stderr, no model needed —
            // the cheapest visible signal of backend registration.
            localvqe_list_devices()

            // The model-load path must fail cleanly (not crash, not succeed) for a
            // nonexistent file, and the error string must come through.
            let bogusPath = "/nonexistent/localvqe-selftest.gguf"
            let bogusCtx = localvqe_new(bogusPath)
            guard bogusCtx == 0 else {
                localvqe_free(bogusCtx)
                print("localvqe-selftest: FAIL — nonexistent model path yielded a context")
                return 1
            }
            let message = LocalVQECanceller.lastError(ctx: 0)
            print("localvqe-selftest: bogus model load failed as expected (\(message))")

            switch mode {
            case .linkOnly:
                print("LOCALVQE_SELFTEST_OK link-only")
                return 0

            case let .model(path):
                return runModelProbe(modelPath: path)
            }
        }

        /// Streams synthetic echo-only audio through LocalVQECanceller — the same
        /// seam the app will use — and checks shape, finiteness, and that the
        /// echo actually drops. All audio is generated; nothing is recorded.
        private static func runModelProbe(modelPath: String) -> Int32 {
            let sampleRate = AudioConstants.targetSampleRate
            let farEnd = probeFarEnd(seconds: 4)
            // Half-level echo, with a deliberate partial trailing hop.
            let mic = farEnd.dropLast(100).map { $0 * 0.5 }

            // Bridge the async seam back to this pre-run-loop synchronous entry
            // point. The semaphore orders the box write before the read.
            final class ResultBox: @unchecked Sendable {
                // Seeded, not optional: every path through the task body
                // assigns before signalling, so an "absent result" case would be
                // unreachable code with a permanent coverage hole behind it.
                var result: Result<[Float], any Error> = .failure(
                    EchoCancellationError.processingFailed(code: -1, message: "probe task delivered no result"),
                )
            }
            let box = ResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    box.result = try await .success(
                        LocalVQECanceller(modelPath: modelPath)
                            .cancelEcho(mic: mic, reference: farEnd),
                    )
                } catch {
                    box.result = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()

            switch box.result {
            case let .success(output):
                guard output.count == mic.count, output.allSatisfy(\.isFinite) else {
                    print("localvqe-selftest: FAIL — bad output shape (\(output.count) for \(mic.count) in)")
                    return 1
                }
                // Skip the first second: the canceller converges from zero state.
                let verdict = EchoReductionVerdict.measure(mic: mic[sampleRate...], output: output[sampleRate...])
                print(String(
                    format: "localvqe-selftest: echo-only %.1f dBFS -> %.1f dBFS (%.1f dB reduction)",
                    verdict.beforeDbfs, verdict.afterDbfs, verdict.reductionDb,
                ))
                guard verdict.passes else {
                    print("localvqe-selftest: FAIL — echo-only input barely attenuated")
                    return 1
                }
                print("LOCALVQE_SELFTEST_OK model")
                return 0

            case let .failure(error):
                print("localvqe-selftest: FAIL — \(error)")
                return 1
            }
        }
    }
#endif
