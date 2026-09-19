@testable import MeetingTranscriber
import XCTest

final class ProtocolResumePolicyTests: XCTestCase {
    /// Defaults describe the ordinary interrupted job: finished transcript on
    /// disk, naming already resolved, no protocol yet. Each test names only the
    /// one input it is about.
    private func decide(
        interruptedIn state: JobState = .generatingProtocol,
        namingDataOnDisk: Bool = false,
        transcriptExists: Bool = true,
        hasNamingSlug: Bool = true,
        protocolExists: Bool = false,
    ) -> ProtocolResumeDisposition {
        ProtocolResumePolicy.decide(
            interruptedIn: state,
            namingDataOnDisk: namingDataOnDisk,
            transcriptExists: transcriptExists,
            hasNamingSlug: hasNamingSlug,
            protocolExists: protocolExists,
        )
    }

    /// The decision keys on the stage the job was interrupted in, never on "a
    /// transcript exists". Stage 1 writes a draft, so a job killed during
    /// diarization has one without speaker labels, and resuming from it would
    /// publish that draft as the finished transcript.
    func testAStageBeforeProtocolGenerationAlwaysRunsInFull() {
        for state in [JobState.transcribing, .diarizing] {
            XCTAssertEqual(
                decide(interruptedIn: state), .fullRun,
                "\(state) leaves a draft transcript, not a finished one",
            )
        }
    }

    func testInterruptedProtocolGenerationResumesFromTheTranscript() {
        XCTAssertEqual(decide(), .resumeProtocolOnly)
    }

    /// The window that makes `.generatingProtocol` alone an unsafe signal: a
    /// confirm enters that state synchronously and only then rewrites the
    /// transcript, dropping its naming data as it commits the rewrite. Finding
    /// the sidecar therefore means the transcript still carries the auto-names,
    /// and resuming would publish them while silently discarding what the user
    /// had just confirmed. A full run asks again instead.
    func testNamingDataStillOnDiskRunsInFull() {
        XCTAssertEqual(decide(namingDataOnDisk: true), .fullRun)
    }

    /// Without the slug, `generateProtocol` falls back to a freshly stamped
    /// stem, so the `.md` would no longer match the `.txt` and the audio.
    func testAMissingNamingSlugRunsInFull() {
        XCTAssertEqual(decide(hasNamingSlug: false), .fullRun)
    }

    func testAMissingTranscriptRunsInFull() {
        XCTAssertEqual(decide(transcriptExists: false), .fullRun)
    }

    /// A crash between writing the protocol and the terminal transition leaves
    /// everything on disk. Generating again would only spend a second LLM call
    /// to overwrite an identical file.
    func testAnAlreadyWrittenProtocolOnlyNeedsFinishing() {
        XCTAssertEqual(decide(protocolExists: true), .finish)
    }

    /// `.finish` reports success without producing anything, and the terminal
    /// transition removes the transcript too when separate raw output is off.
    /// So it must rest on the file being there, not on a path having survived
    /// in the snapshot.
    func testAProtocolPathWhoseFileIsGoneDoesNotCountAsFinished() {
        XCTAssertEqual(decide(protocolExists: false), .resumeProtocolOnly)
    }
}
