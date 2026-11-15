import CoreML
@testable import MeetingTranscriber
import XCTest

/// Unit tests for `LiveSpeakerMatcher`'s fallback + sentinel-detection
/// semantics. The CoreML embedding extraction itself is exercised by
/// `LiveTranscriptionE2ETests` (real audio fixture) — these tests pin the
/// behaviour around an *empty* speaker DB and the SpeakerMatcher
/// integration, which doesn't need a real model load.
@MainActor
final class LiveSpeakerMatcherTests: XCTestCase {
    /// With no enrolled speakers in `speakers.json`, every match attempt
    /// must return nil so the controller falls back to the channel-default
    /// label. Catches a regression where the sentinel-name detection flips
    /// (e.g. returning `__live__` to the caller) or where the matcher
    /// returns a hallucinated name from an empty DB.
    func testMatchReturnsNilWithEmptyDB() async {
        // Empty DB: a fresh SpeakerMatcher with no entries falls through
        // every threshold check.
        let (matcher, _) = makeMatcher(slug: "empty-speakers")

        // `match` calls into the actor, which lazy-loads the WeSpeaker
        // model. Pre-warm fails fast in xctest's sandbox if the model
        // isn't already cached — that's fine, the matcher swallows the
        // error and returns nil.
        let name = await matcher.match(audio: [Float](repeating: 0.0, count: 16000)).name
        XCTAssertNil(
            name,
            "empty speaker DB must resolve to nil (channel-default fallback)",
        )
    }

    /// With one voice enrolled, an unenrolled guest is far from it and must keep the channel label:
    /// unbounded, the only enrolled speaker was always the nearest and the guest took their name.
    func testNearestVoiceFarPastTheThresholdIsNoNearestVoice() {
        let far = SpeakerMatcher.VerboseMatch(
            assignedName: "sentinel",
            topCandidates: [TopCandidate(name: "Speaker A", sample: 0.73, centroid: 0.71)],
        )
        XCTAssertNil(LiveSpeakerMatch(far, sentinel: "sentinel", threshold: 0.40).nearest)
    }

    /// Just past the threshold, the nearest voice is kept for the line before it to confirm.
    func testNearestVoiceJustPastTheThresholdIsKept() {
        let close = SpeakerMatcher.VerboseMatch(
            assignedName: "sentinel",
            topCandidates: [
                TopCandidate(name: "Speaker A", sample: 0.43, centroid: nil),
                TopCandidate(name: "Speaker B", sample: 0.80, centroid: nil),
            ],
        )
        let kept = LiveSpeakerMatch(close, sentinel: "sentinel", threshold: 0.40)
        XCTAssertNil(kept.name)
        XCTAssertEqual(kept.nearest, "Speaker A")
        let matched = SpeakerMatcher.VerboseMatch(assignedName: "Speaker A", topCandidates: close.topCandidates)
        XCTAssertEqual(LiveSpeakerMatch(matched, sentinel: "sentinel", threshold: 0.40).name, "Speaker A")
    }

    /// Through `match`, the nearest voice is bounded by the matcher's own threshold. The stored
    /// embedding's other length puts it at cosine distance 2 from any real one, so only the threshold
    /// decides: 1.90 leaves it far past the slack, 1.97 within it.
    func testMatchBoundsTheNearestVoiceByItsMatcherThreshold() async throws {
        let speech = try Array(AudioMixer.loadAudioFileAsFloat32(url: fixtureURL()).prefix(48000))
        func match(threshold: Float) async -> LiveSpeakerMatch {
            let tempDB = FileManager.default.temporaryDirectory
                .appendingPathComponent("test-cache-nearest-\(UUID()).json")
            addTeardownBlock { try? FileManager.default.removeItem(at: tempDB) }
            let speakerMatcher = SpeakerMatcher(dbPath: tempDB, threshold: threshold)
            speakerMatcher.saveDB([StoredSpeaker(name: "Speaker A", embeddings: [[1, 0, 0]])])
            let matcher = LiveSpeakerMatcher(
                speakerMatcher: speakerMatcher, readCachedFrameCount: { nil }, writeCachedFrameCount: { _ in },
            )
            return await matcher.match(audio: speech)
        }
        let far = await match(threshold: 1.90)
        let close = await match(threshold: 1.97)
        XCTAssertNil(far.nearest)
        XCTAssertNil(close.name)
        XCTAssertEqual(close.nearest, "Speaker A")
    }

    /// With one voice enrolled the closest is always that voice, so a probe names no one; the
    /// stored embeddings' other length puts both voices at the same distance from any real one.
    func testProbeNamesNoOneWithFewerThanTwoEnrolledVoices() async throws {
        let speech = try Array(AudioMixer.loadAudioFileAsFloat32(url: fixtureURL()).prefix(24000))
        func probe(voices: [String]) async throws -> LiveSpeakerMatch {
            let tempDB = FileManager.default.temporaryDirectory
                .appendingPathComponent("test-cache-probe-\(UUID()).json")
            addTeardownBlock { try? FileManager.default.removeItem(at: tempDB) }
            let speakerMatcher = SpeakerMatcher(dbPath: tempDB)
            speakerMatcher.saveDB(voices.map { StoredSpeaker(name: $0, embeddings: [[1, 0, 0]]) })
            let matcher = LiveSpeakerMatcher(
                speakerMatcher: speakerMatcher, readCachedFrameCount: { nil }, writeCachedFrameCount: { _ in },
            )
            try await matcher.prepare()
            return await matcher.probe(audio: speech)
        }
        let one = try await probe(voices: ["Speaker A"])
        let two = try await probe(voices: ["Speaker A", "Speaker B"])
        XCTAssertEqual(one, .unknown)
        XCTAssertNotNil(two.closest)
        XCTAssertEqual(two.margin, 0)
    }

    /// A probe runs inside the caption ingest: it must never start a model load, which a failed
    /// load would otherwise retry on every probe while that channel's captions wait.
    func testProbeNeverLoadsTheModel() async {
        let loads = RecordingModelLoaders()
        let (matcher, _) = makeMatcher(slug: "probe-no-load", prepopulate: 589, modelLoaders: loads.loaders)
        let result = await matcher.probe(audio: [Float](repeating: 0.1, count: 24000))
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(loads.embeddingUnits, [])
        XCTAssertEqual(loads.diarizerUnits, [])
    }

    /// A probe names the closest voice at any distance and its lead over the runner-up, whatever the
    /// order the voices are stored in.
    func testProbeRanksTheEnrolledVoicesByDistance() {
        let cases: [(distances: [(name: String, distance: Float)], expected: LiveSpeakerMatch)] = [
            ([("A", 0.3), ("B", 0.7)], LiveSpeakerMatch(closest: "A", distance: 0.3, margin: 0.4)),
            ([("B", 0.7), ("A", 0.3)], LiveSpeakerMatch(closest: "A", distance: 0.3, margin: 0.4)),
            ([("C", 0.9), ("A", 0.8), ("B", 0.55)], LiveSpeakerMatch(closest: "B", distance: 0.55, margin: 0.25)),
            ([("A", 0.2)], .unknown),
            ([], .unknown),
        ]
        for (distances, expected) in cases {
            let result = LiveSpeakerMatch(probing: distances)
            XCTAssertEqual(result.closest, expected.closest, "\(distances)")
            XCTAssertEqual(result.distance, expected.distance, "\(distances)")
            XCTAssertEqual(result.margin ?? -1, expected.margin ?? -1, accuracy: 1e-6, "\(distances)")
            XCTAssertNil(result.name)
            XCTAssertNil(result.nearest)
        }
    }

    /// A line match refreshes the voices a probe scores against, so a voice deleted in Settings
    /// stops being probed from the next line match on.
    func testALineMatchRefreshesTheVoicesAProbeReads() async throws {
        let speech = try Array(AudioMixer.loadAudioFileAsFloat32(url: fixtureURL()).prefix(24000))
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-cache-probe-refresh-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDB) }
        SpeakerMatcher(dbPath: tempDB)
            .saveDB(["Speaker A", "Speaker B"].map { StoredSpeaker(name: $0, embeddings: [[1, 0, 0]]) })
        let matcher = LiveSpeakerMatcher(
            speakerMatcher: SpeakerMatcher(dbPath: tempDB), readCachedFrameCount: { nil }, writeCachedFrameCount: { _ in },
        )
        try await matcher.prepare()
        // Settings deletes a voice: written through another matcher, as the app's own is.
        SpeakerMatcher(dbPath: tempDB).saveDB([StoredSpeaker(name: "Speaker A", embeddings: [[1, 0, 0]])])
        let kept = await matcher.probe(audio: speech)
        XCTAssertNotNil(kept.closest, "probes keep the voices of the last load until a line match")

        _ = await matcher.match(audio: speech)
        let refreshed = await matcher.probe(audio: speech)
        XCTAssertEqual(refreshed, .unknown)
    }

    /// The live matcher loads the same WeSpeaker embedding model as the
    /// offline pipeline, so it must use the same compute units. `.all` lets
    /// Core ML route that model through the GPU, the path the offline
    /// pipeline was moved off; the choice must also not differ between CI
    /// and a user's machine, or CI tests a configuration nobody ships.
    func testEmbeddingComputeUnitsMatchOfflinePipeline() {
        XCTAssertEqual(
            LiveSpeakerMatcher.embeddingComputeUnits,
            FluidOfflineProcessor.makeModelConfiguration().computeUnits,
            "live and offline WeSpeaker loads must use the same compute units",
        )
        XCTAssertEqual(LiveSpeakerMatcher.embeddingComputeUnits, .cpuAndNeuralEngine)
    }

    /// Cache-hit path: the embedding-only load must ask for the shared
    /// compute units, and the full load must not run.
    func testCacheHitLoadsEmbeddingWithSharedComputeUnits() async {
        let loads = RecordingModelLoaders()
        let (matcher, _) = makeMatcher(slug: "units-hit", prepopulate: 589, modelLoaders: loads.loaders)
        _ = try? await matcher.prepare()
        XCTAssertEqual(loads.embeddingUnits, [FluidOfflineProcessor.computeUnits])
        XCTAssertEqual(loads.diarizerUnits, [], "cache hit must not load the full diarizer models")
    }

    /// Cache-miss (first-launch) path: the full load, whose embedding model
    /// the matcher keeps for the session, must ask for the shared compute
    /// units too. FluidAudio's own default would pick `.all` outside CI.
    func testCacheMissLoadsDiarizerModelsWithSharedComputeUnits() async {
        let loads = RecordingModelLoaders()
        let (matcher, _) = makeMatcher(slug: "units-miss", modelLoaders: loads.loaders)
        _ = try? await matcher.prepare()
        XCTAssertEqual(loads.diarizerUnits, [FluidOfflineProcessor.computeUnits])
        XCTAssertEqual(loads.embeddingUnits, [], "cache miss must not take the embedding-only path")
    }

    /// Pre-warm errors must not propagate — the controller relies on
    /// `match` returning nil on any model-load failure so a transient
    /// network blip during the WeSpeaker download doesn't break captions.
    func testMatchReturnsNilWhenAudioIsEmpty() async {
        let (matcher, _) = makeMatcher(slug: "empty-audio")
        let name = await matcher.match(audio: []).name
        XCTAssertNil(name, "empty audio must resolve to nil")
    }

    /// First-launch path: with an empty cache, `prepare()` must load the
    /// full DiarizerModels once, derive the WeSpeaker mask frame count
    /// from the segmentation model's output shape, and call the write
    /// closure with the derived value. Subsequent launches will hit the
    /// cache and skip the segmentation model load entirely. Regression
    /// target: someone refactoring the loader path drops the cache
    /// write → every launch pays the full load cost silently.
    func testFirstLaunchDerivesAndCachesFrameCount() async throws {
        let (matcher, cache) = makeMatcher(slug: "derivation")
        try await matcher.prepare()

        // After prepare, the write closure must have been called with a
        // positive frame count. The exact value depends on the FluidAudio
        // segmentation model architecture (currently 589 for
        // pyannote_segmentation), but pinning the value here would
        // re-introduce the magic-number problem this caching approach
        // replaces — assert sanity instead.
        let cached = cache.read() ?? 0
        XCTAssertGreaterThan(
            cached, 0,
            "first-launch prepare() must call the write closure with a positive frame count",
        )
        XCTAssertLessThan(
            cached, 100_000,
            "frame count is sane (model swap producing a wildly different shape would fail here)",
        )
    }

    /// Cache-hit path: when the read closure returns a positive frame
    /// count, `prepare()` must succeed without calling the write closure
    /// (cache stays untouched). Verifies the fast path doesn't crash or
    /// overwrite a valid value — the visible cost saving (skipping the
    /// segmentation load) is verified by inspection of the loader code
    /// path, not directly testable without instrumenting `ModelHub`.
    func testSecondLaunchUsesCachedFrameCount() async throws {
        let seeded = 589
        let (matcher, cache) = makeMatcher(slug: "hit", prepopulate: seeded)
        try await matcher.prepare()

        // Cache value must survive the prepare unchanged — the fast path
        // reads but doesn't rewrite.
        XCTAssertEqual(
            cache.read(), seeded,
            "cache-hit path must not rewrite the cached value",
        )
        XCTAssertEqual(
            cache.writeCount, 1,
            "cache-hit path must not call the write closure (writeCount stays at the pre-seed 1)",
        )
    }

    /// Build a matcher backed by an isolated temp DB + in-memory cache, so no
    /// test reads or writes the frame-count cache in `UserDefaults.standard`.
    /// Returns the cache so the test can inspect read/write activity.
    /// Cleanup of the temp DB is registered via `addTeardownBlock` so the
    /// helper composes with async setUp/tearDown.
    private func makeMatcher(
        slug: String,
        prepopulate: Int? = nil,
        modelLoaders: LiveSpeakerMatcher.ModelLoaders = .fluidAudio,
    ) -> (LiveSpeakerMatcher, TestFrameCountCache) {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-cache-\(slug)-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDB) }
        let cache = TestFrameCountCache()
        if let initial = prepopulate {
            cache.write(initial)
        }
        let matcher = LiveSpeakerMatcher(
            speakerMatcher: SpeakerMatcher(dbPath: tempDB),
            readCachedFrameCount: { cache.read() },
            writeCachedFrameCount: { cache.write($0) },
            modelLoaders: modelLoaders,
        )
        return (matcher, cache)
    }
}

/// Thread-safe in-memory replacement for the `UserDefaults`-backed cache.
/// Uses `NSLock` so the `@Sendable` closures handed to `LiveSpeakerMatcher`
/// can mutate from arbitrary actor isolation. `@unchecked Sendable` is
/// safe because every access is locked.
private final class TestFrameCountCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    private var writes: Int = 0

    func read() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func write(_ v: Int) {
        lock.lock(); defer { lock.unlock() }
        value = v
        writes += 1
    }

    var writeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return writes
    }
}

/// Model loaders that record the compute units each launch path asks for
/// and then fail, so no model is loaded. Locked for the same reason as
/// `TestFrameCountCache`.
private final class RecordingModelLoaders: @unchecked Sendable {
    private struct LoadNotAttempted: Error {}

    private let lock = NSLock()
    private var embedding: [MLComputeUnits] = []
    private var diarizer: [MLComputeUnits] = []

    var embeddingUnits: [MLComputeUnits] {
        lock.lock(); defer { lock.unlock() }
        return embedding
    }

    var diarizerUnits: [MLComputeUnits] {
        lock.lock(); defer { lock.unlock() }
        return diarizer
    }

    var loaders: LiveSpeakerMatcher.ModelLoaders {
        LiveSpeakerMatcher.ModelLoaders(
            embeddingModel: { units in
                self.record { $0.embedding.append(units) }
                throw LoadNotAttempted()
            },
            diarizerModels: { units in
                self.record { $0.diarizer.append(units) }
                throw LoadNotAttempted()
            },
        )
    }

    private func record(_ change: (RecordingModelLoaders) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(self)
    }
}
