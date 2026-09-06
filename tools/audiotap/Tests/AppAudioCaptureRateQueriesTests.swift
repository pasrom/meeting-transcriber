@testable import AudioTapLib
import CoreAudio
import XCTest

/// The CoreAudio rate queries and the ladder that picks between them.
///
/// The queries need a real device to answer, which a test machine may or may
/// not have, so what is pinned about them is the machine-independent half: what
/// each does when the object it is asked about does not exist. The ladder is
/// pinned through `DeviceRateQueries`, which hands it the answers a device would
/// have given, so its composition (which answer it believes, and that it asks
/// at all) is assertable without hardware.
@available(macOS 14.2, *)
final class AppAudioCaptureRateQueriesTests: XCTestCase {
    private let unknown = AudioObjectID(kAudioObjectUnknown)

    func testEveryQueryReportsNoRateForAnObjectThatDoesNotExist() {
        // Zero is the ladder's "could not be queried" signal, so each of these
        // returning it is what lets the rung below be tried. A query that
        // returned a plausible-looking number here would be adopted.
        XCTAssertEqual(AppAudioCapture.queryNominalSampleRate(deviceID: unknown), 0)
        XCTAssertEqual(AppAudioCapture.queryStreamSampleRate(deviceID: unknown), 0)
        XCTAssertEqual(AppAudioCapture.queryActualSampleRate(deviceID: unknown), 0)
    }

    func testTheLadderFallsBackToTheRequestedRateWhenNothingAnswers() {
        // With no nominal rate and no stream format, the requested rate is all
        // there is. Publishing 0 instead would make the resampler build a
        // converter against nothing, and the restart coordinator treats a
        // rate-zero start as a failure wearing a success's clothes. Goes through
        // the real queries against a non-existent object, which is the path a
        // session takes when its device disappears mid-restart.
        let gone = DeviceRateQueries.real(deviceID: unknown)

        let at48 = AppAudioCapture.resolveActualSampleRate(requestedRate: 48000, queries: gone)
        XCTAssertEqual(at48.rate, 48000)
        XCTAssertEqual(at48.source, .requestedFallback)

        let at16 = AppAudioCapture.resolveActualSampleRate(requestedRate: 16000, queries: gone)
        XCTAssertEqual(at16.rate, 16000)
        XCTAssertEqual(at16.source, .requestedFallback)
    }

    func testTheLadderResolvesTheDeviceRateWhenNominalAndStreamAgree() {
        // The device case: both properties read the same rate and it differs
        // from the default the recorder asked for. The ladder must publish the
        // device's rate, or the resampler builds its converter against 48000
        // for buffers arriving at 96000.
        //
        // This is the row issue #683 got wrong, but it is not the test that
        // pins the fix, and the difference is worth stating so nobody trusts it
        // for that. With the tap rung still in place this same case passed as
        // long as the tap query answered 0, which is why it has to be measured
        // with the value production actually produces: feeding the old ladder a
        // tap of 48000 against a device at 44100 made it resolve 48000. The
        // rung is gone now, so no argument can express that case any more.
        // `testTheStreamFormatIsReadEvenWhenTheNominalRateAnswers` is what
        // guards the class of defect for the future.
        let device = DeviceRateQueries(nominal: { 96000 }, stream: { 96000 })

        let decision = AppAudioCapture.resolveActualSampleRate(requestedRate: 48000, queries: device)

        XCTAssertEqual(decision.rate, 96000, "the aggregate delivers at its own rate")
        XCTAssertEqual(decision.source, .consistent)
    }

    func testTheLadderTakesTheNominalRateWhenTheStreamFormatIsUnreadable() {
        // Not every device exposes an output-scope physical format. One answer
        // is enough, and the source says which one it was.
        let device = DeviceRateQueries(nominal: { 44100 }, stream: { 0 })

        let decision = AppAudioCapture.resolveActualSampleRate(requestedRate: 48000, queries: device)

        XCTAssertEqual(decision.rate, 44100)
        XCTAssertEqual(decision.source, .onlyNominal)
    }

    func testTheStreamFormatIsReadEvenWhenTheNominalRateAnswers() {
        // The defect shape of issue #683 was one answer suppressing the read
        // that carried the alarm. The mismatch warning only exists if both
        // properties are read every time, so "no need to ask the second when
        // the first answers" is exactly the optimisation this pins out.
        var streamWasRead = false
        let device = DeviceRateQueries(
            nominal: { 48000 },
            stream: {
                streamWasRead = true
                return 48000
            },
        )

        _ = AppAudioCapture.resolveActualSampleRate(requestedRate: 48000, queries: device)

        XCTAssertTrue(streamWasRead, "a nominal answer must not short-circuit the stream read")
    }

    // MARK: - What the log says about each rung

    func testEveryRungPrintsTheWordsTheDocumentationQuotes() {
        // These strings are not decoration. The capture log line is documented
        // in CLAUDE.md down to its example text, and the manual check for a
        // non-default device rate tells the reader which one to expect. They
        // drifted apart once already, when the label stopped being reflected off
        // the Swift case name and nothing failed. Pinning them makes a rename a
        // visible edit rather than a silent one.
        XCTAssertEqual(RateSource.consistent.logLabel, "nominal and stream agree")
        XCTAssertEqual(RateSource.mismatchPreferNominal.logLabel, "nominal, stream disagreed")
        XCTAssertEqual(RateSource.onlyNominal.logLabel, "nominal only")
        XCTAssertEqual(RateSource.streamOnlyDistrusted.logLabel, "stream only, not trusted")
        XCTAssertEqual(RateSource.requestedFallback.logLabel, "nothing queryable")
    }

    func testTheTwoRungsWorthWarningAboutAreReachedThroughTheResolver() {
        // The pure decision is pinned in SampleRateChooseRateTests. What is
        // pinned here is that those two classifications survive the trip through
        // the resolver, which is what decides whether anything is logged at all.
        // Neither warning branch had ever been executed by a test.
        let disagreeing = DeviceRateQueries(nominal: { 44100 }, stream: { 16000 })
        XCTAssertEqual(
            AppAudioCapture.resolveActualSampleRate(requestedRate: 48000, queries: disagreeing).source,
            .mismatchPreferNominal,
            "a Bluetooth stream reporting its HFP rate must not go unremarked",
        )

        let streamOnly = DeviceRateQueries(nominal: { 0 }, stream: { 24000 })
        let decision = AppAudioCapture.resolveActualSampleRate(requestedRate: 48000, queries: streamOnly)
        XCTAssertEqual(decision.source, .streamOnlyDistrusted)
        XCTAssertEqual(decision.rate, 48000, "and the distrusted answer is not the rate")
    }

    // MARK: - Real device (tolerant smoke test, HelpersTests pattern)

    func testTheRealReadsResolveTheDefaultOutputDevicesNominalRate() throws {
        // The only test that exercises the real property reads against an
        // object that exists, rather than only the failure handling the
        // unknown-id test covers.
        //
        // It does not prove the selectors and scopes are right, and it is worth
        // saying so rather than letting the next reader assume it. For the
        // nominal read the assertion is near-tautological, because
        // `getDefaultOutputDeviceSampleRate` asks for the same selector in the
        // same scope. For the stream read there is no assertion at all: swapping
        // its selector and scope to the virtual format on the input scope leaves
        // every test here green. What pins the stream read is that a lone answer
        // from it is never adopted, which `SampleRateChooseRateTests` covers. The device set on a runner varies (headless, BlackHole
        // only), so a machine without a default output device skips rather
        // than fails. Whichever rung the ladder takes, its answer is the
        // nominal rate: consistent and onlyNominal return it directly and the
        // mismatch rung prefers it, so the assertion holds on a Bluetooth
        // headset in call mode too.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID,
        )
        try XCTSkipUnless(status == noErr && deviceID != kAudioObjectUnknown, "no default output device here")
        guard let nominal = getDefaultOutputDeviceSampleRate() else {
            throw XCTSkip("the default output device has no readable nominal rate")
        }
        try XCTSkipUnless(nominal <= Double(SampleRateQuery.maxPlausibleRate), "nominal rate outside the ladder's range")

        // The measured-rate read is the other half of the pair: the ladder runs
        // at tap creation, this one runs on the first callback and is what
        // catches a device whose rate is not what the aggregate reported. Only
        // its failure path is otherwise exercised, against an id that does not
        // exist, so this is the one place its success path runs at all. It is
        // documented as valid only on a started device, so a zero is tolerated.
        let measured = AppAudioCapture.queryActualSampleRate(deviceID: deviceID)
        if measured > 0 {
            XCTAssertLessThanOrEqual(measured, SampleRateQuery.maxPlausibleRate)
        }

        let decision = AppAudioCapture.resolveActualSampleRate(
            requestedRate: 48000, queries: .real(deviceID: deviceID),
        )

        XCTAssertEqual(decision.rate, Int(nominal), "the ladder must read the device, not fall back")
        // Guards the equality against a device that happens to sit at the
        // requested 48000, where a fallback would pass the line above.
        XCTAssertNotEqual(decision.source, .requestedFallback)
    }
}
