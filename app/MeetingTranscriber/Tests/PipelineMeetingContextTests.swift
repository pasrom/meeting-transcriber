import Foundation
@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class PipelineMeetingContextTests: XCTestCase {
    private let transcript = "[00:20] [Speaker A] Please finish fly wheel curation before release."

    func testConfiguredRegenerationUsesRealMCPClientAndPreservesOriginalTranscript() async throws {
        let fixture = try await MCPTestFixture(.http)
        defer { fixture.stop() }
        let source = try fixture.approvedSource()
        let model = ContextTestModel()
        let generator = NotesGenerator(model: model)
        let folder = try makeTempDirectory(prefix: "context_notes")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = MockEngine()
        let queue = PipelineQueue(
            engine: engine, diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            meetingContextConfiguration: {
                MeetingContextConfiguration(sources: [source], authorize: { $0 == source }, credentials: { _ in
                    MCPTestFixture.httpCredentials
                })
            },
            outputDir: folder, logDir: folder,
        )
        let saved = folder.appendingPathComponent("meeting.txt")
        let notes = folder.appendingPathComponent("meeting.md")
        let original = Data(transcript.utf8)
        try original.write(to: saved)
        try "# Old notes".write(to: notes, atomically: true, encoding: .utf8)

        let outcome = queue.enqueueNotes(fromTranscripts: [saved, saved], regenerate: .configuredContext)
        XCTAssertEqual(outcome.queued.count, 1)
        XCTAssertEqual(outcome.alreadyQueued, [saved])
        await queue.awaitProcessing()

        XCTAssertEqual(engine.transcribeCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: saved), original)
        let markdown = try String(contentsOf: notes, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("# Blackwell"))
        let context = try String(contentsOf: MeetingContextFiles.sidecar(beside: notes), encoding: .utf8)
        XCTAssertTrue(context.contains(ContextDigest.hash(Data(markdown.utf8))))
        XCTAssertTrue(context.contains("seg-1"))
        XCTAssertFalse(context.contains("Blackwell"))
        XCTAssertTrue(try fixture.methods().contains("tools/call"))
        let calls = await generator.log.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].contains("Blackwell"))
    }

    func testOrdinaryAndFailedRegenerationPreserveOriginalFilesAndSkipContext() async throws {
        let folder = try makeTempDirectory(prefix: "notes_no_context")
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("meeting.txt")
        let notes = folder.appendingPathComponent("meeting.md")
        let oldNotes = Data("# Prior notes".utf8)
        let oldContext = Data("prior context".utf8)
        try Data(transcript.utf8).write(to: input)
        try oldNotes.write(to: notes)
        try oldContext.write(to: MeetingContextFiles.sidecar(beside: notes))
        let generator = NotesGenerator(model: ContextTestModel(), fail: true)
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            meetingContextConfiguration: { XCTFail("The context-free option touched MCP configuration"); return nil },
            outputDir: folder, logDir: folder,
        )

        let outcome = queue.enqueueNotes(fromTranscripts: [input], regenerate: .withoutContext)
        await queue.awaitProcessing()

        XCTAssertEqual(try Data(contentsOf: notes), oldNotes)
        XCTAssertEqual(try Data(contentsOf: MeetingContextFiles.sidecar(beside: notes)), oldContext)
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), transcript)
        let calls = await generator.log.calls
        XCTAssertEqual(calls, [transcript])
        let id = try XCTUnwrap(outcome.queued.first)
        XCTAssertTrue(queue.canRetryMeetingNotes(id: id))
    }

    func testDisabledContextUsesTheOrdinaryNotesPath() async throws {
        let folder = try makeTempDirectory(prefix: "context_disabled")
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("meeting.txt")
        let notes = folder.appendingPathComponent("meeting.md")
        let original = Data(transcript.utf8)
        try original.write(to: input)
        let model = ContextTestModel()
        let generator = NotesGenerator(model: model)
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            outputDir: folder, logDir: folder,
        )
        queue.enqueueNotes(fromTranscripts: [input])
        await queue.awaitProcessing()
        let calls = await generator.log.calls
        XCTAssertEqual(calls, [transcript])
        let plans = await model.capturedPlanning()
        XCTAssertTrue(plans.isEmpty)
        XCTAssertTrue(try String(contentsOf: notes, encoding: .utf8).hasPrefix("# Ordinary Notes"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MeetingContextFiles.sidecar(beside: notes).path))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testDefaultDisabledSettingAndToggleWriteThrough() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(DefaultsSuite.open(name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.meetingContextEnabled)
        XCTAssertNil(settings.meetingContextConfiguration())
        let toggle = try ContextMCPSettingsSection(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.meetingContextToggle)
            .find(ViewType.Toggle.self)
        try toggle.tap()
        XCTAssertTrue(settings.meetingContextEnabled)
        XCTAssertTrue(AppSettings(defaults: defaults).meetingContextEnabled)
    }
}

private struct NotesGenerator: ProtocolGenerating, ContextNotesModel {
    let model: ContextTestModel
    let fail: Bool
    let log = Log()

    actor Log {
        private(set) var calls: [String] = []
        func capture(_ value: String) {
            calls.append(value)
        }
    }

    init(model: ContextTestModel, fail: Bool = false) {
        self.model = model
        self.fail = fail
    }

    var contextEndpoint: URL {
        model.contextEndpoint
    }

    var contextProvider: String {
        model.contextProvider
    }

    var contextModel: String {
        model.contextModel
    }

    var contextSecret: String? {
        model.contextSecret
    }

    func planContext(
        instructions: String, data: String, seconds: TimeInterval, authorize: @escaping @MainActor @Sendable () -> Bool,
    ) async throws -> String {
        try await model.planContext(instructions: instructions, data: data, seconds: seconds, authorize: authorize)
    }

    func generateWithContext(
        transcript: String, diarized: Bool, meetingStartTime: Date?, evidence: String,
        authorize: @escaping @MainActor @Sendable () -> Bool,
    ) async throws -> String {
        await log.capture(evidence)
        return try await model.generateWithContext(
            transcript: transcript, diarized: diarized, meetingStartTime: meetingStartTime, evidence: evidence, authorize: authorize,
        )
    }

    func generate(transcript: String, title _: String, diarized _: Bool, meetingStartTime _: Date?) async throws -> String {
        await log.capture(transcript)
        if fail { throw ProtocolError.emptyProtocol }
        return "# Ordinary Notes"
    }
}
