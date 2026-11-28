import Foundation

/// What the compactor asks of the registry about its marks.
extension RecordingCompaction {
    /// Whether a run for `request` has entries to look at: the explicit run
    /// always does, an automatic one only while an entry is marked for it.
    func hasWork(for request: RecordingCompactionPlan.Request) -> Bool {
        switch request {
        case let .awaiting(kind): registry.entries.contains { $0.awaiting.contains(kind) }
        case .everyEntry: true
        }
    }

    /// How many entries a run still owes FLAC, for `/state`.
    var awaitingCount: Int {
        registry.entries.count { $0.awaiting.contains(.flac) }
    }
}
