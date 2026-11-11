import Foundation

/// Why a job's meeting notes could not be generated, as a kind with a fixed
/// sentence. Decided in the catch of `PipelineQueue.generateProtocol`, where
/// the error case is still known; the provider's own message, which for an
/// HTTP error carries part of the server's response body, goes to the log only.
enum MeetingNotesFailure: String, Codable, Equatable {
    // The case names are what snapshots store, as on `JobState`.
    // swiftlint:disable raw_value_for_camel_cased_codable_enum
    /// The Claude CLI answered that it is not signed in.
    case claudeSignedOut
    case claudeNotFound
    case claudeFailed
    case timedOut
    case empty
    case truncated
    case providerRejected
    case providerUnreachable
    /// A notes-only run found no provider: switched to None while it waited.
    case noProvider
    /// A notes-only run could not read its transcript.
    case transcriptUnreadable
    case other
    // swiftlint:enable raw_value_for_camel_cased_codable_enum

    init(_ error: any Error) {
        guard let error = error as? ProtocolError else {
            self = .other
            return
        }
        switch error {
        #if !APPSTORE
            // The CLI ends every sign-in problem ("Not logged in", "Invalid API
            // key") with "Please run /login", and only the CLI's own error is
            // read for it, so no other provider's text can send a user there.
            case let .cliFailed(_, message): self = message.contains("/login") ? .claudeSignedOut : .claudeFailed

            case .cliNotFound: self = .claudeNotFound

            case .timeout: self = .timedOut
        #endif

        case .generationTimedOut: self = .timedOut

        case .emptyProtocol: self = .empty

        case .protocolTruncated: self = .truncated

        case .httpError: self = .providerRejected

        case .connectionFailed: self = .providerUnreachable
        }
    }

    /// One sentence, without the final full stop.
    var summary: String {
        switch self {
        case .claudeSignedOut: "The Claude CLI is not signed in"
        case .claudeNotFound: "The Claude CLI was not found"
        case .claudeFailed: "The Claude CLI stopped with an error"
        case .timedOut: "The notes provider took too long"
        case .empty: "The notes provider returned no text"
        case .truncated: "The notes were cut off before they were finished"
        case .providerRejected: "The notes provider refused the request"
        case .providerUnreachable: "The notes provider could not be reached"
        case .noProvider: "No meeting notes provider is chosen in Settings → Output"
        case .transcriptUnreadable: "The saved transcript could not be read"
        case .other: "Generating them failed"
        }
    }

    /// What the user can do about it, when there is one thing to do.
    var hint: String? {
        self == .claudeSignedOut ? "Run claude in Terminal and sign in with /login." : nil
    }
}
