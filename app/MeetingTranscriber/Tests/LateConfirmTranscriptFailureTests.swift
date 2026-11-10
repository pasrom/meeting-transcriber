@testable import MeetingTranscriber
import XCTest

/// A late speaker confirmation whose transcript cannot be used. The job still
/// ends `.done`, like the auto-accept path, so it has to say on the job that no
/// names were applied and no protocol was made. Its own file because
/// `SpeakerNamingSessionTests` is at the `type_body_length` cap.
@MainActor
final class LateConfirmTranscriptFailureTests: XCTestCase {
    /// A confirm whose transcript cannot be read applies no names and makes no
    /// protocol. It still ends `.done`, like the auto-accept path, but it must
    /// say so on the job rather than look like a normal finish.
    func testLateConfirmWithAnUnreadableTranscriptWarnsOnTheJob() async throws {
        let tmp = try makeTempDirectory(prefix: "LateConfirmUnreadable")
        for transcriptPath in [tmp.appendingPathComponent("gone.txt"), nil] {
            let session = NamingSessionFixture.session(outputDir: tmp)
            let mock = NamingSessionMockDelegate()
            session.delegate = mock
            let job = NamingSessionFixture.pendingJob(namingSlug: "standup_abcd1234", transcriptPath: transcriptPath)
            mock.jobs[job.id] = job
            session.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)

            session.completeSpeakerNaming(
                jobID: job.id, result: .confirmed(["SPEAKER_0": "Speaker A"]), source: .dialog,
            )

            await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
            XCTAssertTrue(mock.generateProtocolCalls.isEmpty)
            XCTAssertEqual(
                mock.warnings.map(\.message), ["Protocol not generated — transcript file is missing"],
                "transcript \(transcriptPath?.lastPathComponent ?? "nil")",
            )
        }
    }

    /// A transcript that reads but cannot be rewritten keeps its old labels and
    /// gets no protocol either, so that finish is flagged as well.
    func testLateConfirmThatCannotRewriteTheTranscriptWarnsOnTheJob() async throws {
        let folder = try makeTempDirectory(prefix: "LateConfirmReadOnly")
        let transcriptPath = folder.appendingPathComponent("transcript.txt")
        try "[00:00] SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        let session = NamingSessionFixture.session(outputDir: folder)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock
        let job = NamingSessionFixture.pendingJob(namingSlug: "standup_abcd1234", transcriptPath: transcriptPath)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)

        session.completeSpeakerNaming(
            jobID: job.id, result: .confirmed(["SPEAKER_0": "Speaker A"]), source: .dialog,
        )

        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        XCTAssertTrue(mock.generateProtocolCalls.isEmpty)
        XCTAssertEqual(
            mock.warnings.map(\.message),
            ["Protocol not generated: rewriting the transcript with the speaker names failed"],
        )
    }
}
