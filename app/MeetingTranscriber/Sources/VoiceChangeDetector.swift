import Foundation

/// Finds where the voice on one caption channel changes, from the nearest enrolled voice of short
/// overlapping windows, so a caption line can end where its speaker stops rather than where a word
/// count or a pause falls. Only enrolled voices count: the distance between consecutive windows alone
/// did not separate speakers (see docs/architecture/transcription.md).
struct VoiceChangeDetector {
    static let window: TimeInterval = 1.5
    static let hop: TimeInterval = 0.5
    /// Consecutive windows that must name the new voice; at a 0.5 s hop a change shows ~2.5 s late.
    static let windowsToConfirm = 3
    /// At 0.6 an unenrolled voice was cut once under an enrolled name; none at 0.5 (transcription.md).
    static let maxDistance: Float = 0.5
    /// Lead of the nearest voice over the runner-up.
    static let minMargin: Float = 0.15

    struct Change: Equatable {
        /// Audio time where the new voice starts: the middle of its first window.
        let at: TimeInterval
        let voice: String
    }

    private(set) var current: String?
    private var candidate: String?
    private var candidateStart: TimeInterval = 0
    private var candidateWindows = 0

    /// Feeds the window ending at `windowEnd`; returns a change once it is confirmed.
    mutating func add(windowEnd: TimeInterval, match: LiveSpeakerMatch) -> Change? {
        guard let voice = match.closest, let distance = match.distance, distance < Self.maxDistance,
              match.margin.map({ $0 >= Self.minMargin }) ?? true
        else {
            candidate = nil
            return nil
        }
        guard voice != current else {
            candidate = nil
            return nil
        }
        if voice != candidate {
            candidate = voice
            candidateStart = windowEnd - Self.window / 2
            candidateWindows = 0
        }
        candidateWindows += 1
        guard candidateWindows >= Self.windowsToConfirm else { return nil }
        // The first voice confirmed is no change: nothing was heard before it.
        defer { current = voice }
        candidate = nil
        return current == nil ? nil : Change(at: candidateStart, voice: voice)
    }
}
