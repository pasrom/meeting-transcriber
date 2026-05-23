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
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-empty-speakers-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        // Empty DB: a fresh SpeakerMatcher with no entries falls through
        // every threshold check.
        let sm = SpeakerMatcher(dbPath: tempDB)
        let matcher = LiveSpeakerMatcher(speakerMatcher: sm)

        // `match` calls into the actor, which lazy-loads the WeSpeaker
        // model. Pre-warm fails fast in xctest's sandbox if the model
        // isn't already cached — that's fine, the matcher swallows the
        // error and returns nil.
        let name = await matcher.match(audio: [Float](repeating: 0.0, count: 16000))
        XCTAssertNil(
            name,
            "empty speaker DB must resolve to nil (channel-default fallback)",
        )
    }

    /// Pre-warm errors must not propagate — the controller relies on
    /// `match` returning nil on any model-load failure so a transient
    /// network blip during the WeSpeaker download doesn't break captions.
    func testMatchReturnsNilWhenAudioIsEmpty() async {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-empty-audio-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let matcher = LiveSpeakerMatcher(speakerMatcher: SpeakerMatcher(dbPath: tempDB))
        let name = await matcher.match(audio: [])
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
    /// path, not directly testable without instrumenting `DownloadUtils`.
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

    /// Build a matcher backed by an isolated temp DB + in-memory cache.
    /// Returns the cache so the test can inspect read/write activity.
    /// Cleanup of the temp DB is registered via `addTeardownBlock` so the
    /// helper composes with async setUp/tearDown.
    private func makeMatcher(
        slug: String,
        prepopulate: Int? = nil,
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
