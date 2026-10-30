import Foundation

/// Whether the naming dialog still takes an answer for the job it shows, and
/// why the host refused the last one.
///
/// An answer is handed over at most once per job, so a double click cannot
/// resolve a job twice. A refused answer does not count as given: the buttons
/// stay live and `refusalMessage` says why. Without that, a Re-run the
/// session could not start left Confirm, Skip and Re-run all dead until the
/// window was reopened.
///
/// Per job rather than a single flag, so that when the window moves on to
/// another pending job its buttons respond again.
struct NamingAnswerGate: Equatable {
    private(set) var answeredJobID: UUID?
    private(set) var refusalMessage: String?

    /// Hand `jobID`'s answer to `deliver`, which returns why the host refused
    /// it, nil when it took it. Returns whether `deliver` ran.
    @discardableResult
    mutating func submit(jobID: UUID, _ deliver: () -> String?) -> Bool {
        guard answeredJobID != jobID else { return false }
        refusalMessage = deliver()
        answeredJobID = refusalMessage == nil ? jobID : nil
        return true
    }

    /// Start over for a fresh presentation (a new job, or new data for it).
    mutating func reset() {
        self = Self()
    }
}
