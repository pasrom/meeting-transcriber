@testable import MeetingTranscriber
import XCTest

/// Backtest the speaker matcher against real local recordings.
///
/// Loads `_mix.wav` files from `~/Downloads/MeetingTranscriber/recordings/`,
/// runs FluidDiarizer's offline mode to get fresh embeddings, then matches
/// against the user's real `speakers.json` using both the **legacy** algorithm
/// (min-distance over recent samples) and the **hybrid** algorithm (centroid
/// added as an extra anchor — the production code in this PR).
///
/// Skipped on CI / when neither the recordings dir nor speakers.json exists.
/// Run manually:
///   swift test --filter SpeakerMatcherRealRecordingBacktest
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

    func testCompareMatchersOnLocalRecordings() async throws {
        let config = try loadConfigOrSkip()
        let dbData = try Data(contentsOf: config.speakersDB)
        let db = try JSONDecoder().decode([StoredSpeaker].self, from: dbData)

        let candidates = try FileManager.default
            .contentsOfDirectory(at: config.recordingsDir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasSuffix("_mix.wav") }
            .sorted { lhs, rhs -> Bool in
                let lhsSize = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let rhsSize = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return lhsSize > rhsSize
            }
            .prefix(config.maxFiles)

        guard !candidates.isEmpty else {
            throw XCTSkip("no _mix.wav files found in \(config.recordingsDir.path)")
        }

        print("=== Backtest against \(candidates.count) recording(s); DB has \(db.count) speakers ===")

        let diarizer = FluidDiarizer(mode: .offline)

        var legacyHits = 0
        var hybridHits = 0
        var diffs: [(file: String, label: String, legacy: String?, hybrid: String?)] = []

        for url in candidates {
            print("\n>>> \(url.lastPathComponent)")
            let result: DiarizationResult
            do {
                result = try await diarizer.run(audioPath: url, numSpeakers: nil, meetingTitle: "")
            } catch {
                print("  diarization failed: \(error.localizedDescription)")
                continue
            }
            let embeddings = result.embeddings ?? [:]
            print("  speakers in mix: \(embeddings.keys.sorted())")

            for label in embeddings.keys.sorted() {
                guard let emb = embeddings[label] else { continue }
                let legacy = matchLegacy(embedding: emb, db: db)
                let hybrid = matchHybrid(embedding: emb, db: db)
                if legacy != nil { legacyHits += 1 }
                if hybrid != nil { hybridHits += 1 }
                let mark = legacy != hybrid ? " ← differs" : ""
                print("  \(label): legacy=\(legacy ?? "nil")  hybrid=\(hybrid ?? "nil")\(mark)")
                if legacy != hybrid {
                    diffs.append((file: url.lastPathComponent, label: label, legacy: legacy, hybrid: hybrid))
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
