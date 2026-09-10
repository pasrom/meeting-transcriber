// Row state for the speaker-naming dialog, held as a reference type so a
// row's write is observable from outside the view.
import Observation

/// Per-presentation state of the naming rows, keyed by speaker label
/// throughout.
///
/// Label, never row position. The rows are identified by label
/// (`ForEach(speakers, id: \.label)`) and a label's sorted position moves
/// between jobs, which is the crash of issue #700.
///
/// One `@Observable` object rather than one `@State` per field, because a
/// `@State` write from a ViewInspector tap is unobservable: the measurement and
/// the alternatives it rules out are in CLAUDE.md's GUI Testing section, rung 2.
/// With the state in an object, the object a test holds is the object the
/// action writes to, which is what `SpeakerNamingRowWritesTests` asserts on.
@Observable
@MainActor
final class SpeakerNamingRowState {
    /// What each row's name field holds, keyed by speaker label.
    var names: [String: String]
    /// Labels of the rows showing the full known-names list instead of the
    /// top-N ranked subset.
    var knownExpanded: Set<String> = []

    init(names: [String: String]) {
        self.names = names
    }

    /// Re-seed for a new presentation: another job, or the same job re-diarized.
    ///
    /// Mutates in place rather than the view assigning a fresh object, because
    /// `nameBinding(for:)` hands each field a binding that captures this object
    /// and SwiftUI keeps that binding until the field's next update. Replacing
    /// the object would leave the fields on screen writing into the one nobody
    /// reads any more.
    ///
    /// One call because the two halves must move together. Expansion is
    /// collapsed rather than carried over: the next presentation's known-names
    /// list is a different list, so a row left expanded would be expanded
    /// against names the user never chose to see.
    func reset(names: [String: String]) {
        self.names = names
        knownExpanded.removeAll()
    }
}
