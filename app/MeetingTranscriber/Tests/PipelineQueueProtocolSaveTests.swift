@testable import MeetingTranscriber
import XCTest

/// What a job says when its protocol was generated but could not be written.
///
/// The save used to share a `catch` with the generation call, so a write
/// failure was reported as "Protocol generation failed", and the model's output
/// was gone without the job saying it had existed. The folder is made
/// unwritable with POSIX permissions, which the unsandboxed test process can
/// observe; in the sandboxed build the same failure is a missing scope.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class PipelineQueueProtocolSaveTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_protocol_save_test")
    }

    func testAProtocolThatCannotBeSavedSaysSoInsteadOfClaimingGenerationFailed() async throws {
        let root = tmpDir.appendingPathComponent("output", isDirectory: true)
        let protocols = root.appendingPathComponent("protocols", isDirectory: true)
        try FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: protocols.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protocols.path)
        }

        let protocolGen = MockProtocolGen()
        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: root,
            logDir: tmpDir,
            micLabel: "Me",
            inFlightRuns: InFlightRunRegistry(),
        )
        let job = PipelineJob(
            meetingTitle: "Unwritable", appName: "Teams",
            mixPath: tmpDir.appendingPathComponent("unused.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.insertJobForTesting(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "[00:00] Speaker A: Hello", title: job.meetingTitle, protocolsDir: protocols,
        )

        XCTAssertTrue(protocolGen.generateCalled, "test premise: the protocol was generated")
        let after = try XCTUnwrap(queue.jobs.first)
        XCTAssertNil(after.protocolPath, "test premise: the save failed")
        XCTAssertTrue(
            after.warnings.contains { $0.contains("generated but could not be saved") },
            "the warning does not say the save failed: \(after.warnings)",
        )
        XCTAssertFalse(after.warnings.contains { $0.contains("generation failed") }, "\(after.warnings)")
    }
}
