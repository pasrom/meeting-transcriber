@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The live-caption backend footnote in Settings → Transcription, per engine.
@MainActor
final class TranscriptionSettingsCaptionFootnoteTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsCaptionFootnoteTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = DefaultsSuite.open(suiteName) else {
            XCTFail("could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() async throws {
        if let suiteName { DefaultsSuite.remove(suiteName) }
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    /// WhisperKit detects the language before captioning, so auto-detect can stream English.
    func testWhisperKitAutoDetectFootnoteSaysEnglishStreams() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = ""
        let view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
        let footnote = TranscriptionSettingsView.captionBackendFootnote(
            strategy: .reTranscribe, languageIsSet: false, detectsLanguage: true,
        )
        XCTAssertTrue(footnote.contains("English then streams"))
        XCTAssertNoThrow(try view.inspect().find(text: footnote))
    }

    /// Parakeet has no language detector, so its auto-detect captions stay on re-transcribe.
    func testParakeetAutoDetectFootnoteKeepsReTranscribe() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        let view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
        let footnote = TranscriptionSettingsView.captionBackendFootnote(
            strategy: .reTranscribe, languageIsSet: false, detectsLanguage: false,
        )
        XCTAssertTrue(footnote.contains("Auto-detect uses the standard re-transcribe engine"))
        XCTAssertNoThrow(try view.inspect().find(text: footnote))
    }
}
