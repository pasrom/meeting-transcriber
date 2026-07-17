import Foundation

/// Single source of truth for the accessibility identifiers used as automation
/// handles (ViewInspector `find`, the `/ui/tree` + `/ui/press` harness).
///
/// Referencing these constants from the SwiftUI `.accessibilityIdentifier`
/// modifier, the ViewInspector tests, and the `/ui/press` allowlist makes the
/// compiler catch a drifted identifier across those call sites — a raw string
/// literal duplicated per site drifts silently. Shell drivers (`test_rpc.sh`,
/// curl) still use the raw string; those are grep-checked.
///
/// Add an entry on demand when a test or the harness needs to find/drive a
/// control — don't spray identifiers onto controls nothing drives. The string
/// values are the stable contract (VoiceOver + tests + allowlist read them) and
/// are heterogeneous on purpose (some kebab-case, some camelCase — they mirror
/// the pre-existing identifiers); don't "tidy" or otherwise change a value
/// without updating every site.
enum A11yID {
    // Settings — section anchors + record-only controls.
    static let recordOnlyToggle = "recordOnlyToggle"
    static let recordOnlyBanner = "recordOnlyBanner"
    static let transcriptionSection = "transcriptionSection"
    static let protocolSection = "protocolSection"
    static let outputFolderSection = "outputFolderSection"
    static let vadSection = "vadSection"
    static let diarizationSection = "diarizationSection"
    static let liveTranscriptionSection = "liveTranscriptionSection"
    static let channelIndicatorSection = "channelIndicatorSection"
    static let experimentalTuningDisclosure = "experimentalTuningDisclosure"
    static let sortformerCapHint = "sortformer-cap-hint"

    // Speaker-naming dialog.
    static let confirmButton = "confirm-button"
    static let skipButton = "skip-button"
    static let rerunButton = "rerun-button"
    static let rerunStepper = "rerun-stepper"
    static let rerunModePicker = "rerun-mode-picker"

    /// Per-speaker play button (`play-<label>`); the label varies at runtime.
    static func play(_ speakerLabel: String) -> String {
        "play-\(speakerLabel)"
    }

    /// Prefix for the per-participant name chips (`participant-name-<name>`);
    /// the name is appended at the call site.
    static let participantNamePrefix = "participant-name-"

    static func knownName(_ name: String) -> String {
        "known-name-\(name)"
    }

    static func knownMore(_ speakerLabel: String) -> String {
        "known-more-\(speakerLabel)"
    }

    static func knownLess(_ speakerLabel: String) -> String {
        "known-less-\(speakerLabel)"
    }

    // Live captions overlay.
    static let liveCaptionBackend = "liveCaptionBackend"
}
