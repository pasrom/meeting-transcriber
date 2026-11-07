import Foundation

/// One stretch of the microphone track the user muted, in seconds of that track.
public struct MicMuteInterval: Codable, Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// When the microphone was muted, in seconds of the written track rather than
/// wall-clock time, because that is the timeline the transcript of the track is on.
///
/// `Codable` so the recorder can save it at each toggle: a crash during a mute
/// leaves `openSince` set, which recovery closes at the end of the surviving track.
public struct MicMuteTimeline: Codable, Equatable, Sendable {
    public private(set) var closed: [MicMuteInterval] = []
    public private(set) var openSince: TimeInterval?
    /// How much of the track has been written so far.
    public private(set) var position: TimeInterval = 0

    public init() {}

    public var isMuted: Bool {
        openSince != nil
    }

    public mutating func setMuted(_ muted: Bool) {
        if muted {
            guard openSince == nil else { return }

            openSince = position
        } else if let start = openSince {
            openSince = nil
            // Toggled back before a buffer was written: nothing was silenced.
            if position > start {
                closed.append(MicMuteInterval(start: start, end: position))
            }
        }
    }

    mutating func advance(to position: TimeInterval) {
        self.position = max(self.position, position)
    }

    /// Every muted stretch, with one still open closed at `end`.
    public func intervals(endingAt end: TimeInterval) -> [MicMuteInterval] {
        guard let openSince, end > openSince else { return closed }

        return closed + [MicMuteInterval(start: openSince, end: end)]
    }
}
