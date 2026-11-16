@testable import MeetingTranscriber
import XCTest

/// The speaker-cap hints in Settings and in the naming dialog. A dual-source
/// recording diarizes the app track and the microphone track separately, so a
/// mode's cap holds per input. The texts are spelled out here; the view tests
/// check that each view shows what these functions return.
@MainActor
final class SpeakerCapHintTests: XCTestCase {
    func testSettingsHintStatesTheCapPerInput() {
        XCTAssertEqual(
            SpeakersSettingsView.speakerCapHint(for: .sortformer),
            "Sortformer supports up to 4 speakers per input. "
                + "A call recorded with your microphone has two inputs, the call audio and the microphone, each with this limit. "
                + "Switch to Offline mode for meetings with more participants.",
        )
        XCTAssertEqual(
            SpeakersSettingsView.speakerCapHint(for: .nemotron),
            "Nemotron 3 supports up to 8 speakers per input. "
                + "A call recorded with your microphone has two inputs, the call audio and the microphone, each with this limit. "
                + "Switch to Offline mode for meetings with more participants.",
        )
    }

    func testNamingHintStatesTheCapPerTrackForADualSourceJob() {
        XCTAssertEqual(
            SpeakerNamingView.capHint(for: .sortformer, isDualSource: true),
            "Sortformer caps at 4 speakers in the call audio and 4 on your microphone — switch to Offline for larger meetings.",
        )
        XCTAssertEqual(
            SpeakerNamingView.capHint(for: .nemotron, isDualSource: true),
            "Nemotron 3 caps at 8 speakers in the call audio and 8 on your microphone — switch to Offline for larger meetings.",
        )
    }

    /// A single-source job has one input, so its hint keeps the plain wording.
    func testNamingHintKeepsThePlainWordingForASingleSourceJob() {
        XCTAssertEqual(
            SpeakerNamingView.capHint(for: .sortformer, isDualSource: false),
            "Sortformer caps at 4 speakers — switch to Offline for larger meetings.",
        )
    }
}
