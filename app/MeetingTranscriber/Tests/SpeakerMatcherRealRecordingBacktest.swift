@testable import MeetingTranscriber
import XCTest

/// Backtest the speaker matcher against real local recordings.
///
/// Groups recordings in `~/Downloads/MeetingTranscriber/recordings/` into
/// dual-source groups via `PairedRecordingResolver` and diarizes the `_app` +
/// `_mic` tracks separately, mirroring the production dual-track path — a
/// combined mix often collapses several speakers into one cluster. Groups
/// with only a `_mix.wav` (recordings predating persisted split tracks) fall
/// back to diarizing the mix. The fresh embeddings are then matched against
/// the user's real `speakers.json` using both the **legacy** algorithm
/// (min-distance over recent samples) and the **hybrid** algorithm (centroid
/// added as an extra anchor, which is what production uses).
///
/// Opt-in, because it reads the developer's own meeting recordings and their
/// real speaker database, and the presence of those folders is not consent to
/// touch them. On the machine that has them, a plain `swift test` pulled up to
/// `MAX_BACKTEST_RECORDINGS` recording groups (eight by default) through
/// diarization, and a dual-source group is diarized twice, once per track, so
/// up to sixteen runs. That is minutes of work in a run meant to check
/// something else.
///
/// Observed twice on this machine, not derivable from the code: the run ends in
/// SIGSEGV somewhere under the CoreML models. A process-level crash sets the
/// suite's exit code even when every test passed, which makes "did anything
/// break" unanswerable from it. Unexplained, and not what this gate fixes; it
/// only keeps it out of runs that were asking about something else. Run it
/// deliberately:
///   RUN_SPEAKER_BACKTEST=1 swift test --filter SpeakerMatcherRealRecordingBacktest
///   (use `MAX_BACKTEST_RECORDINGS=5` to cap the run for a quicker iteration)
final class SpeakerMatcherRealRecordingBacktest: XCTestCase {
    private struct Config {
        let recordingsDir: URL
        let speakersDB: URL
        let maxFiles: Int
    }

    private func loadConfigOrSkip() throws -> Config {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let recordings = home.appending(path: "Downloads/MeetingTranscriber/recordings")
        let speakersDB = home.appending(path:
            "Library/Application Support/MeetingTranscriber/speakers.json")
        guard FileManager.default.fileExists(atPath: recordings.path),
              FileManager.default.fileExists(atPath: speakersDB.path) else {
            throw XCTSkip("real recordings or speakers.json not present locally")
        }
        let max = ProcessInfo.processInfo.environment["MAX_BACKTEST_RECORDINGS"]
            .flatMap(Int.init) ?? 8
        return Config(recordingsDir: recordings, speakersDB: speakersDB, maxFiles: max)
    }

    /// Legacy match: min-distance across recent samples only (centroid ignored).
    /// Mirrors what the matcher did before this PR; used for A/B comparison.
    private func matchLegacy(
        embedding: [Float],
        db: [StoredSpeaker],
        threshold: Float = 0.40,
        margin: Float = 0.10,
    ) -> String? {
        var best: (name: String, dist: Float)?
        var second = Float.greatestFiniteMagnitude
        for sp in db {
            let d = sp.embeddings.map { SpeakerMatcher.cosineDistance(embedding, $0) }
                .min() ?? .greatestFiniteMagnitude
            if d < (best?.dist ?? .greatestFiniteMagnitude) {
                second = best?.dist ?? second
                best = (sp.name, d)
            } else if d < second {
                second = d
            }
        }
        guard let b = best, b.dist < threshold, second - b.dist >= margin else { return nil }
        return b.name
    }

    /// Production match (hybrid: min over centroid + samples).
    private func matchHybrid(
        embedding: [Float],
        db: [StoredSpeaker],
        threshold: Float = 0.40,
        margin: Float = 0.10,
    ) -> String? {
        var best: (name: String, dist: Float)?
        var second = Float.greatestFiniteMagnitude
        for sp in db {
            let d = SpeakerMatcher.distance(query: embedding, speaker: sp)
            if d < (best?.dist ?? .greatestFiniteMagnitude) {
                second = best?.dist ?? second
                best = (sp.name, d)
            } else if d < second {
                second = d
            }
        }
        guard let b = best, b.dist < threshold, second - b.dist >= margin else { return nil }
        return b.name
    }

    private func fileSize(_ url: URL?) -> Int {
        guard let url else { return 0 }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Diarize a recording group the way production does: app + mic tracks
    /// separately (merged with `R_`/`M_` prefixes) when both exist, the mix
    /// as a fallback for recordings predating persisted split tracks.
    /// Unlike production, a failing track skips the whole group (no app-only
    /// degradation) and micDelay is not applied — the backtest only compares
    /// matchers on embeddings, so segment timing is irrelevant.
    private func diarize(
        group: PairedRecordingResolver.Group, with diarizer: FluidDiarizer,
    ) async throws -> DiarizationResult {
        if let app = group.app, let mic = group.mic {
            let appResult = try await diarizer.run(audioPath: app, numSpeakers: nil, meetingTitle: "")
            let micResult = try await diarizer.run(audioPath: mic, numSpeakers: nil, meetingTitle: "")
            return DiarizationProcess.mergeDualTrackDiarization(
                appDiarization: appResult, micDiarization: micResult,
            )
        }
        // `PairedRecordingResolver.paired` guarantees app+mic or a mix.
        guard let mix = group.mix else { throw DiarizationError.notAvailable }
        return try await diarizer.run(audioPath: mix, numSpeakers: nil, meetingTitle: "")
    }

    func testCompareMatchersOnLocalRecordings() async throws {
        // First line, before any folder probe, so a skip cannot be read as "no
        // recordings on this machine". A method added here later needs the same
        // line: the gate cannot live in `setUpWithError`, because the suite's
        // lint rule then demands a matching `tearDown`, and it must not live in
        // the config loader, which a future method could simply not call.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SPEAKER_BACKTEST"] == "1",
            "gated: set RUN_SPEAKER_BACKTEST=1 (reads your own recordings)",
        )
        let config = try loadConfigOrSkip()
        let dbData = try Data(contentsOf: config.speakersDB)
        let db = try JSONDecoder().decode([StoredSpeaker].self, from: dbData)

        let wavs = try FileManager.default
            .contentsOfDirectory(at: config.recordingsDir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "wav" }
        let candidates = PairedRecordingResolver.resolve(urls: wavs).paired
            .sorted { fileSize($0.app ?? $0.mix) > fileSize($1.app ?? $1.mix) }
            .prefix(config.maxFiles)

        guard !candidates.isEmpty else {
            throw XCTSkip("no recording groups found in \(config.recordingsDir.path)")
        }

        print("=== Backtest against \(candidates.count) recording(s); DB has \(db.count) speakers ===")

        let diarizer = FluidDiarizer(mode: .offline)

        var legacyHits = 0
        var hybridHits = 0
        var diffs: [(file: String, label: String, legacy: String?, hybrid: String?)] = []

        for group in candidates {
            let isDual = group.app != nil && group.mic != nil
            print("\n>>> \(group.stem) (\(isDual ? "dual-track" : "mix fallback"))")
            let result: DiarizationResult
            do {
                result = try await diarize(group: group, with: diarizer)
            } catch {
                print("  diarization failed: \(error.localizedDescription)")
                continue
            }
            let embeddings = result.embeddings ?? [:]
            print("  speakers: \(embeddings.keys.sorted())")

            for label in embeddings.keys.sorted() {
                guard let emb = embeddings[label] else { continue }
                let legacy = matchLegacy(embedding: emb, db: db)
                let hybrid = matchHybrid(embedding: emb, db: db)
                if legacy != nil { legacyHits += 1 }
                if hybrid != nil { hybridHits += 1 }
                let mark = legacy != hybrid ? " ← differs" : ""
                print("  \(label): legacy=\(legacy ?? "nil")  hybrid=\(hybrid ?? "nil")\(mark)")
                if legacy != hybrid {
                    diffs.append((file: group.stem, label: label, legacy: legacy, hybrid: hybrid))
                }
            }
        }

        print("\n=== Summary ===")
        print("Legacy matched: \(legacyHits) labels")
        print("Hybrid matched: \(hybridHits) labels")
        print("Differing labels: \(diffs.count)")
        for d in diffs {
            print("  \(d.file) \(d.label): \(d.legacy ?? "nil") → \(d.hybrid ?? "nil")")
        }
    }
}
