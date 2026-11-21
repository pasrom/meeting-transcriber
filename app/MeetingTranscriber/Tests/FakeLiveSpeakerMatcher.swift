@testable import MeetingTranscriber

/// In-memory `LiveSpeakerMatching` fake. Returns canned names by call
/// order (`canned[call % canned.count]`); empty `canned` means every
/// call resolves to `nil` (channel-default fallback path). Probes count
/// and name no one. Every live-transcription test reaches for this fixture.
actor FakeLiveSpeakerMatcher: LiveSpeakerMatching {
    private let canned: [String]
    private(set) var matchCount = 0
    private(set) var probeCount = 0

    init(canned: [String] = []) {
        self.canned = canned
    }

    /// Convenience: keyed by channel name for readability at call sites,
    /// flattened into a stable order (mic → app) for deterministic
    /// playback.
    init(canned: [String: String]) {
        self.canned = [canned["mic"], canned["app"]].compactMap(\.self)
    }

    // swiftlint:disable:next unneeded_throws_rethrows async_without_await
    func prepare() async throws {} // protocol conformance — async/throws matches `LiveSpeakerMatching`

    // swiftlint:disable:next async_without_await
    func match(audio _: [Float]) async -> LiveSpeakerMatch { // protocol conformance — `async` matches `LiveSpeakerMatching`
        matchCount += 1
        guard !canned.isEmpty else { return .unknown }
        let name = canned[(matchCount - 1) % canned.count]
        return LiveSpeakerMatch(name: name, nearest: name)
    }

    func probe(audio _: [Float]) -> LiveSpeakerMatch {
        probeCount += 1
        return .unknown
    }
}
