@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The live-caption footnotes in Settings → Transcription.
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

    /// The footnote is a plain String, so Markdown emphasis would show its asterisks.
    func testLiveTranscriptionFootnoteUsesPlainLoggingText() throws {
        let view = TranscriptionSettingsView(
            settings: makeSettings(),
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
        let footnote = try view.inspect().find(ViewType.Text.self) { text in
            try text.string().contains("Caption text is")
        }.string()

        XCTAssertTrue(footnote.contains("Caption text is not logged by default"))
        XCTAssertFalse(footnote.contains("**"))
    }
}
