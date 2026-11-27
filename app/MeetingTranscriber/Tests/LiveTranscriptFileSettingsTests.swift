@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The Settings rows of the live transcript file: one wiring test per control,
/// plus the setting's default and persistence.
@MainActor
final class LiveTranscriptFileSettingsTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "LiveTranscriptFileSettingsTests-\(getpid())-\(UUID().uuidString)"
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

    private func makeView(_ settings: AppSettings) -> TranscriptionSettingsView {
        TranscriptionSettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
    }

    func testSettingIsOffByDefaultAndPersists() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.liveTranscriptFileEnabled, "spoken text reaches disk only when asked for")

        settings.liveTranscriptFileEnabled = true

        XCTAssertTrue(AppSettings(defaults: defaults).liveTranscriptFileEnabled)
    }

    func testToggleWritesTheSetting() throws {
        let settings = AppSettings(defaults: defaults)
        settings.liveTranscriptionEnabled = true

        try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveTranscriptFileToggle)
            .find(ViewType.Toggle.self)
            .tap()

        XCTAssertTrue(settings.liveTranscriptFileEnabled)
    }

    /// Without captions there are no finals to write, so the toggle follows the
    /// live-captions toggle as the overlay toggle does.
    func testToggleIsDisabledWhileLiveCaptionsAreOff() throws {
        let settings = AppSettings(defaults: defaults)
        settings.liveTranscriptionEnabled = false

        let toggle = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveTranscriptFileToggle)

        XCTAssertTrue(toggle.isDisabled())
    }

    func testFolderButtonCreatesTheFolderOwnerOnlyAndRevealsIt() throws {
        let directory = makeTempFile(suffix: "-LiveTranscriptFolderButton")
        var revealed: [URL] = []
        let view = LiveTranscriptFileSettings(settings: AppSettings(defaults: defaults), directory: directory) { url in
            revealed.append(url)
        }

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveTranscriptFolderButton)
            .find(ViewType.Button.self)
            .tap()

        XCTAssertEqual(revealed, [directory])
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }
}
