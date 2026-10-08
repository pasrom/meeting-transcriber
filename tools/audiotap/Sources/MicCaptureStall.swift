/// The microphone's stall as the capture layer reports it (issues #724, #706):
/// released after going without audio for the whole budget.
///
/// Two values, because one flag cannot carry both. Whether the microphone is
/// released right now is what `/state` shows, and it clears only once a
/// revived microphone delivers again. Whether there is a stall the user has
/// not heard about yet is a different question: a revival that never
/// delivers stalls again without the flag ever clearing, and a remedy that
/// did not work is news the user needs as much as the first stall.
public struct MicCaptureStall: Equatable, Sendable {
    /// Released for lack of audio right now.
    public var isActive: Bool
    /// Stalls so far in this recording, every failed revival included.
    public var count: Int
    /// What the latest stall said about itself, which the notice's wording
    /// depends on.
    public var details: MicStallDetails

    public init(isActive: Bool = false, count: Int = 0, details: MicStallDetails = MicStallDetails()) {
        self.isActive = isActive
        self.count = count
        self.details = details
    }

    /// Released for lack of audio, once more.
    public mutating func noteStalled(_ details: MicStallDetails) {
        isActive = true
        count += 1
        self.details = details
    }

    /// A revival delivered again.
    public mutating func noteResumed() {
        isActive = false
    }

    /// A revival wedged and the microphone is lost for good: no longer
    /// released for lack of audio, so the stall ends here rather than being
    /// reported alongside the give-up.
    public mutating func noteGaveUp() {
        isActive = false
    }
}
