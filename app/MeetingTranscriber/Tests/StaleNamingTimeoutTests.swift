@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// How long a meeting may wait for its speaker names before the launch-time
/// cleanup gives it the automatic names (`AppSettings.staleNamingTimeout`).
///
/// One day is what the cleanup always used and stays the default. Seven days
/// and "Forever" let a meeting wait longer, which matters most when the naming
/// window does not pop up by itself and a meeting is easy to forget.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class StaleNamingTimeoutTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    private let day: TimeInterval = 86400

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "stale_naming_timeout")
    }

    // MARK: - Setting

    /// An existing install keeps the one day it has always had.
    func testOneDayIsTheDefault() {
        XCTAssertEqual(freshSettings().staleNamingTimeout, .oneDay)
    }

    func testTheTimeoutsMapToTheirAges() {
        XCTAssertEqual(StaleNamingTimeout.oneDay.maxAge, day)
        XCTAssertEqual(StaleNamingTimeout.sevenDays.maxAge, 7 * day)
        XCTAssertNil(StaleNamingTimeout.never.maxAge)
    }

    func testTheChoicePersists() throws {
        let name = "stale-naming-persist-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        let defaults = try XCTUnwrap(DefaultsSuite.open(name))
        AppSettings(defaults: defaults).staleNamingTimeout = .never
        XCTAssertEqual(
            AppSettings(defaults: defaults).staleNamingTimeout, .never,
            "the choice has to survive a relaunch",
        )
    }

    /// A value this build does not know (a downgrade, a typo) falls back to the
    /// default rather than to "Forever".
    func testAnUnknownStoredValueFallsBackToOneDay() throws {
        let name = "stale-naming-unknown-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        let defaults = try XCTUnwrap(DefaultsSuite.open(name))
        defaults.set("fortnight", forKey: "staleNamingTimeout")
        XCTAssertEqual(AppSettings(defaults: defaults).staleNamingTimeout, .oneDay)
    }

    func testThePickerWritesBackToSettings() throws {
        let settings = freshSettings()
        let picker = try makeSpeakersView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.staleNamingTimeoutPicker)
        try picker.find(ViewType.Picker.self).select(value: StaleNamingTimeout.sevenDays)
        XCTAssertEqual(settings.staleNamingTimeout, .sevenDays)
    }

    /// Without diarization no meeting waits for names, so the row is not shown.
    func testThePickerIsHiddenWithoutDiarization() {
        let settings = freshSettings()
        settings.diarize = false
        XCTAssertThrowsError(
            try makeSpeakersView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.staleNamingTimeoutPicker),
        )
    }

    /// The queue is built once, when watching starts, so it has to read the
    /// setting live rather than keep the value it was built with.
    func testTheSettingReachesAQueueThatWasBuiltBeforeItChanged() {
        let settings = freshSettings()
        // Bound to a local first: as a trailing argument the formatter
        // detaches it from the call.
        let live: () -> TimeInterval? = { settings.staleNamingTimeout.maxAge }
        let queue = PipelineQueue(logDir: tmpDir, staleNamingMaxAge: live)
        XCTAssertEqual(queue.staleNamingMaxAge, day)

        settings.staleNamingTimeout = .never

        XCTAssertNil(queue.staleNamingMaxAge)
    }

    // MARK: - On launch

    func testAMeetingWaitingTwoDaysIsResolvedWithOneDay() throws {
        let job = try writePendingSnapshot(waitingFor: 2 * day)
        let queue = restoredQueue(timeout: .oneDay)
        XCTAssertEqual(state(of: job, in: queue), .done)
    }

    func testAMeetingWaitingTwoDaysStillWaitsWithSevenDays() throws {
        let job = try writePendingSnapshot(waitingFor: 2 * day)
        let queue = restoredQueue(timeout: .sevenDays)
        XCTAssertEqual(state(of: job, in: queue), .speakerNamingPending)
    }

    func testAMeetingWaitingEightDaysIsResolvedWithSevenDays() throws {
        let job = try writePendingSnapshot(waitingFor: 8 * day)
        let queue = restoredQueue(timeout: .sevenDays)
        XCTAssertEqual(state(of: job, in: queue), .done)
    }

    func testForeverKeepsEvenAVeryOldMeetingWaiting() throws {
        let job = try writePendingSnapshot(waitingFor: 30 * day)
        let queue = restoredQueue(timeout: .never)
        XCTAssertEqual(state(of: job, in: queue), .speakerNamingPending)
        XCTAssertNotNil(queue.speakerNamingDataByJob[job.id], "the names must still be assignable later")
    }

    /// The explicit-age form tests and callers use is not gated by the setting.
    func testAnExplicitAgeIgnoresTheSetting() throws {
        let job = try writePendingSnapshot(waitingFor: 2 * day)
        let queue = restoredQueue(timeout: .never)
        queue.cleanupStalePending(maxAge: day)
        XCTAssertEqual(state(of: job, in: queue), .done)
    }

    // MARK: - Fixture

    private func freshSettings() -> AppSettings {
        let name = "stale-naming-\(UUID().uuidString)"
        let defaults = DefaultsSuite.open(name)!
        // swiftlint:disable:previous force_unwrapping
        addTeardownBlock { DefaultsSuite.remove(name) }
        return AppSettings(defaults: defaults)
    }

    private func makeSpeakersView(settings: AppSettings) -> SpeakersSettingsView {
        SpeakersSettingsView(
            settings: settings,
            recognitionStatsLog: RecognitionStatsLog(),
            stageTimingLog: StageTimingLog(),
            enrollmentDiarizerFactory: nil,
            namingDialogActive: false,
            pipelineBusy: false,
        )
    }

    private func restoredQueue(timeout: StaleNamingTimeout) -> PipelineQueue {
        let maxAge: () -> TimeInterval? = { timeout.maxAge }
        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            diarizeEnabled: true,
            staleNamingMaxAge: maxAge,
            inFlightRuns: InFlightRunRegistry(),
        )
        queue.loadSnapshot()
        return queue
    }

    private func state(of job: PipelineJob, in queue: PipelineQueue) -> JobState? {
        queue.jobs.first { $0.id == job.id }?.state
    }

    /// A job left waiting for names when the app quit, `age` after it entered
    /// the naming dialog, with its naming sidecar.
    @discardableResult
    private func writePendingSnapshot(waitingFor age: TimeInterval) throws -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Standup", appName: "Teams",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.namingSlug = "standup_pending"
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        encoded["namingStartedAt"] = Date().addingTimeInterval(-age).timeIntervalSinceReferenceDate
        let snapshot = try JSONSerialization.data(withJSONObject: [encoded])
        try snapshot.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))
        let namingData = PipelineQueue.SpeakerNamingData(
            jobID: job.id, meetingTitle: "Standup", mapping: [:], speakingTimes: [:], embeddings: [:],
            audioPath: nil, segments: [], participants: [], isDualSource: false,
        )
        try SpeakerNamingStore(outputDir: tmpDir).save(namingData, slug: "standup_pending")
        return job
    }
}
