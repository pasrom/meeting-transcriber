@testable import MeetingTranscriber
import XCTest

final class PairedRecordingResolverTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/rec")

    private func url(_ name: String) -> URL {
        dir.appendingPathComponent(name)
    }

    // MARK: - Single recording groups

    func testFullTriplet() {
        let result = PairedRecordingResolver.resolve(urls: [
            url("standup_app.wav"),
            url("standup_mic.wav"),
            url("standup_mix.wav"),
        ])

        XCTAssertEqual(result.paired.count, 1)
        XCTAssertEqual(result.singletons.count, 0)

        let group = result.paired[0]
        XCTAssertEqual(group.stem, "standup")
        XCTAssertNotNil(group.app)
        XCTAssertNotNil(group.mic)
        XCTAssertEqual(group.mix?.lastPathComponent, "standup_mix.wav")
    }

    func testMixOnlyIsPaired() {
        let result = PairedRecordingResolver.resolve(urls: [
            url("meeting_mix.wav"),
        ])

        XCTAssertEqual(result.paired.count, 1)
        XCTAssertEqual(result.singletons.count, 0)

        let group = result.paired[0]
        XCTAssertEqual(group.stem, "meeting")
        XCTAssertEqual(group.mix?.lastPathComponent, "meeting_mix.wav")
        XCTAssertNil(group.app)
        XCTAssertNil(group.mic)
    }

    func testAppPlusMicWithoutMixIsPaired() {
        // Both tracks present → dual-track pipeline can run; `mix` will be
        // synthesized from app+mic at enqueue time.
        let result = PairedRecordingResolver.resolve(urls: [
            url("20260311_143000_app.wav"),
            url("20260311_143000_mic.wav"),
        ])

        XCTAssertEqual(result.paired.count, 1)
        XCTAssertEqual(result.singletons.count, 0)

        let group = result.paired[0]
        XCTAssertEqual(group.stem, "20260311_143000")
        XCTAssertNil(group.mix, "no mix in selection — synthesizer will create one")
        XCTAssertEqual(group.app?.lastPathComponent, "20260311_143000_app.wav")
        XCTAssertEqual(group.mic?.lastPathComponent, "20260311_143000_mic.wav")
    }

    // MARK: - Singleton fallback

    func testLoneAppFallsBackToSingleton() {
        let result = PairedRecordingResolver.resolve(urls: [
            url("alone_app.wav"),
        ])

        XCTAssertEqual(result.paired.count, 0)
        XCTAssertEqual(result.singletons.count, 1)
        XCTAssertEqual(result.singletons[0].lastPathComponent, "alone_app.wav")
    }

    func testLoneMicFallsBackToSingleton() {
        let result = PairedRecordingResolver.resolve(urls: [
            url("alone_mic.wav"),
        ])

        XCTAssertEqual(result.paired.count, 0)
        XCTAssertEqual(result.singletons.count, 1)
        XCTAssertEqual(result.singletons[0].lastPathComponent, "alone_mic.wav")
    }

    func testUnrecognizedSuffixIsSingleton() {
        let result = PairedRecordingResolver.resolve(urls: [
            url("podcast.mp3"),
            url("interview.m4a"),
        ])

        XCTAssertEqual(result.paired.count, 0)
        XCTAssertEqual(result.singletons.count, 2)
    }

    // MARK: - Mixed batches

    func testOnePairPlusOneSingleton() {
        let result = PairedRecordingResolver.resolve(urls: [
            url("meeting_app.wav"),
            url("meeting_mic.wav"),
            url("meeting_mix.wav"),
            url("standalone.mp3"),
        ])

        XCTAssertEqual(result.paired.count, 1)
        XCTAssertEqual(result.singletons.count, 1)
        XCTAssertEqual(result.singletons[0].lastPathComponent, "standalone.mp3")
    }

    func testTwoSeparatePairs() {
        let result = PairedRecordingResolver.resolve(urls: [
            url("aaa_app.wav"), url("aaa_mic.wav"), url("aaa_mix.wav"),
            url("bbb_app.wav"), url("bbb_mic.wav"), url("bbb_mix.wav"),
        ])

        XCTAssertEqual(result.paired.count, 2)
        XCTAssertEqual(result.singletons.count, 0)

        let stems = Set(result.paired.map(\.stem))
        XCTAssertEqual(stems, ["aaa", "bbb"])
    }

    func testSameStemDifferentDirectoriesAreSeparateGroups() {
        let dirA = URL(fileURLWithPath: "/tmp/a")
        let dirB = URL(fileURLWithPath: "/tmp/b")
        let result = PairedRecordingResolver.resolve(urls: [
            dirA.appendingPathComponent("meeting_app.wav"),
            dirA.appendingPathComponent("meeting_mic.wav"),
            dirA.appendingPathComponent("meeting_mix.wav"),
            dirB.appendingPathComponent("meeting_app.wav"),
            dirB.appendingPathComponent("meeting_mic.wav"),
            dirB.appendingPathComponent("meeting_mix.wav"),
        ])

        XCTAssertEqual(result.paired.count, 2)
        XCTAssertEqual(result.singletons.count, 0)
    }

    func testEmptyInput() {
        let result = PairedRecordingResolver.resolve(urls: [])
        XCTAssertTrue(result.paired.isEmpty)
        XCTAssertTrue(result.singletons.isEmpty)
    }

    // MARK: - Regression: mixPath aliasing

    func testResolverNeverAliasesMixWithAppOrMic() {
        // When a `_mix.wav` is part of the selection, it must be distinct from
        // app/mic by suffix construction. Groups without a mix carry `nil`,
        // and the synthesizer creates a real mix file at enqueue time.
        let cases: [[URL]] = [
            [url("a_app.wav"), url("a_mic.wav"), url("a_mix.wav")],
            [url("b_mix.wav")],
            [url("c_app.wav"), url("c_mix.wav")],
            [url("d_mic.wav"), url("d_mix.wav")],
        ]
        for urls in cases {
            let result = PairedRecordingResolver.resolve(urls: urls)
            for group in result.paired where group.mix != nil {
                XCTAssertNotEqual(group.mix, group.app)
                XCTAssertNotEqual(group.mix, group.mic)
            }
        }
    }

    func testGroupOrderFollowsFirstURLIndex() {
        // Mix at index 0 → pair "early" is enqueued first;
        // singleton at index 1; pair "late" (mix at index 2) is enqueued second.
        let result = PairedRecordingResolver.resolve(urls: [
            url("early_mix.wav"), // 0 — pair "early" earliest member
            url("solo.mp3"), // 1 — singleton
            url("late_mix.wav"), // 2 — pair "late" earliest member
            url("early_app.wav"), // 3 — pair "early" later member (irrelevant for order)
            url("late_mic.wav"), // 4
        ])

        XCTAssertEqual(result.paired.map(\.stem), ["early", "late"])
        XCTAssertEqual(result.singletons.map(\.lastPathComponent), ["solo.mp3"])
    }
}
