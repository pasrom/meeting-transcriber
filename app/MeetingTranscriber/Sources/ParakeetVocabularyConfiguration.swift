import Foundation

/// Immutable identity of a Parakeet vocabulary configuration. The file revision
/// matters as much as the path: users commonly edit an existing terminology
/// file between meetings.
struct ParakeetVocabularyConfiguration: Equatable, Sendable {
    let path: String
    let bookmark: Data?
    let revision: WhisperVocabularyPrompt.FileRevision?
}

/// Lifecycle of one exact CTC vocabulary configuration. A failed preparation
/// is still terminal for that file revision: retrying it for every recording
/// window only adds repeated I/O and log noise. A new path, bookmark, or file
/// revision produces a different configuration and is eligible again.
enum ParakeetVocabularyPreparationState: Equatable, Sendable {
    case preparing(ParakeetVocabularyConfiguration)
    case ready(ParakeetVocabularyConfiguration)
    case unavailable(ParakeetVocabularyConfiguration)
    case failed(ParakeetVocabularyConfiguration)

    var configuration: ParakeetVocabularyConfiguration {
        switch self {
        case let .preparing(configuration),
             let .ready(configuration),
             let .unavailable(configuration),
             let .failed(configuration):
            configuration
        }
    }
}

/// Invalidates in-flight vocabulary preparation when Settings changes. A
/// configuration task may resume after a model download, so callers must check
/// its captured generation before adopting the prepared CTC booster.
struct ParakeetVocabularyRefreshGate: Sendable {
    private var generation = 0

    mutating func invalidate() -> Int {
        generation &+= 1
        return generation
    }

    func isCurrent(_ attempt: Int) -> Bool {
        attempt == generation
    }

    var current: Int {
        generation
    }
}
