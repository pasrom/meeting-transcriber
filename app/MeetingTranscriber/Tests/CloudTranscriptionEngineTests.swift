@testable import MeetingTranscriber
import XCTest

/// `CloudTranscriptionEngine` against `MockURLProtocol`: the request it sends,
/// how it reads the answer, and a cloud job run through the real pipeline.
/// No live network.
@MainActor
final class CloudTranscriptionEngineTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    private static let config = CloudTranscriptionConfiguration(
        baseURL: "https://cloud.test/v1", model: "whisper-1", apiKey: "sk-test",
    )
    private static let verboseJSON = Data("""
    {"task":"transcribe","language":"english","duration":2.0,"text":"Hello there. General Kenobi.",
     "segments":[{"id":0,"start":0.0,"end":1.2,"text":" Hello there."},
                 {"id":1,"start":1.2,"end":2.0,"text":" General Kenobi."}]}
    """.utf8)

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "cloud_transcription_test")
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.errorHandler = nil
        MockURLProtocol.rawResponseHandler = nil
        MockURLProtocol.hangHandler = nil
        MockURLProtocol.redirectHandler = nil
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        tmpDir = nil
        try await super.tearDown()
    }

    private func makeMockSession() -> URLSession {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: sessionConfig)
    }

    private func makeEngine(_ config: CloudTranscriptionConfiguration = config) -> CloudTranscriptionEngine {
        CloudTranscriptionEngine(configuration: { config }, session: makeMockSession())
    }

    private static func respond(_ request: URLRequest, body: Data, status: Int = 200) -> (HTTPURLResponse, Data) {
        // swiftlint:disable:next force_unwrapping
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
    }

    /// The upload body, from `httpBody` or the stream URLSession turns it into.
    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            collected.append(buffer, count: read)
        }
        return collected
    }

    /// The value of a plain multipart field, nil when absent.
    private static func field(_ name: String, in body: String) -> String? {
        let marker = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        guard let start = body.range(of: marker)?.upperBound,
              let end = body.range(of: "\r\n", range: start ..< body.endIndex)?.lowerBound
        else { return nil }
        return String(body[start ..< end])
    }

    // MARK: - Request shape

    func testPostsTheRecordingAsMultipartWithBearerAuth() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        let audioBytes = try Data(contentsOf: audio)
        nonisolated(unsafe) var captured: (request: URLRequest, body: Data)?
        MockURLProtocol.handler = { request in
            captured = (request, Self.body(of: request))
            return Self.respond(request, body: Self.verboseJSON)
        }

        _ = try await makeEngine().transcribeSegments(audioPath: audio)

        let (request, body) = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://cloud.test/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)

        // Latin-1 maps every byte, so the binary WAV part cannot fail the decode.
        let text = try XCTUnwrap(String(bytes: body, encoding: .isoLatin1))
        XCTAssertEqual(Self.field("model", in: text), "whisper-1")
        XCTAssertEqual(Self.field("response_format", in: text), "verbose_json")
        XCTAssertEqual(Self.field("timestamp_granularities[]", in: text), "segment")
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"\(audio.lastPathComponent)\""))
        XCTAssertNotNil(body.range(of: audioBytes), "the WAV must be uploaded byte for byte")
    }

    func testAnEmptyKeySendsNoAuthorizationHeader() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        nonisolated(unsafe) var authorization: String? = "unset"
        MockURLProtocol.handler = { request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return Self.respond(request, body: Self.verboseJSON)
        }
        var config = Self.config
        config.apiKey = ""

        _ = try await makeEngine(config).transcribeSegments(audioPath: audio)

        XCTAssertNil(authorization)
    }

    // MARK: - Response

    func testParsesSegmentsIntoTimestampedSegments() async throws {
        // As long as the canned answer, whose times are clamped to the audio.
        let audio = tmpDir.appendingPathComponent("two_seconds.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: 32000), sampleRate: 16000, url: audio)
        MockURLProtocol.handler = { Self.respond($0, body: Self.verboseJSON) }

        let segments = try await makeEngine().transcribeSegments(audioPath: audio)

        XCTAssertEqual(segments.map(\.text), ["Hello there.", "General Kenobi."])
        XCTAssertEqual(segments.map(\.start), [0.0, 1.2])
        XCTAssertEqual(segments.map(\.end), [1.2, 2.0])
    }

    func testAResponseWithoutSegmentsFailsNamingTheModel() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        MockURLProtocol.handler = { Self.respond($0, body: Data(#"{"text":"Hello there."}"#.utf8)) }
        var config = Self.config
        config.model = "gpt-4o-transcribe"

        do {
            _ = try await makeEngine(config).transcribeSegments(audioPath: audio)
            XCTFail("a response without segments must fail")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .missingSegments(model: "gpt-4o-transcribe"))
            XCTAssertTrue(error.localizedDescription.contains("gpt-4o-transcribe"), error.localizedDescription)
        }
    }

    func testAnHTTPErrorCarriesTheStatusAndBody() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        MockURLProtocol.handler = { Self.respond($0, body: Data("bad key".utf8), status: 401) }

        do {
            _ = try await makeEngine().transcribeSegments(audioPath: audio)
            XCTFail("a 401 must fail")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .httpError(status: 401, body: "bad key"))
        }
    }

    // MARK: - Through the pipeline

    /// A queue wired the way `PipelineController.makeQueue` wires it: the
    /// target and the resolver both come from `settings`.
    private func makeCloudQueue(settings: AppSettings, localEngine: MockEngine, diarizer: MockDiarization) -> PipelineQueue {
        PipelineQueue(
            engine: localEngine,
            diarizationFactory: { diarizer },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            engineResolver: settings.transcriptionEngineResolver(local: localEngine, session: makeMockSession()),
            transcriptionTargetProvider: { settings.transcriptionTarget },
            stagingDir: tmpDir.appendingPathComponent("unused-staging", isDirectory: true),
            diarizeEnabled: true,
        )
    }

    private func makeCloudSettings() throws -> (AppSettings, cleanup: () -> Void) {
        let suiteName = "CloudTranscriptionEngineTests-\(getpid())-\(UUID().uuidString)"
        let account = "CloudTranscriptionEngineTests-key-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suiteName)), cloudTranscriptionAPIKeyAccount: account,
        )
        settings.cloudTranscriptionBaseURL = Self.config.baseURL
        settings.cloudTranscriptionModel = Self.config.model
        settings.cloudTranscriptionEnabled = true
        return (settings, {
            KeychainHelper.delete(key: account)
            DefaultsSuite.remove(suiteName)
        })
    }

    private func enqueueRecording(on queue: PipelineQueue) throws {
        try queue.enqueue(PipelineJob(
            meetingTitle: "Cloud Call", appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
        ))
    }

    /// The acceptance path: queued with cloud on, transcribed by the endpoint,
    /// diarized locally, finished with the usual transcript. Switching cloud
    /// off after the job was queued does not move it.
    func testAJobQueuedWithCloudOnIsTranscribedByTheEndpointAndDiarizedLocally() async throws {
        let (settings, cleanup) = try makeCloudSettings()
        defer { cleanup() }
        nonisolated(unsafe) var uploads = 0
        MockURLProtocol.handler = { request in
            uploads += 1
            return Self.respond(request, body: Self.verboseJSON)
        }
        let localEngine = MockEngine()
        let diarizer = MockDiarization()
        let queue = makeCloudQueue(settings: settings, localEngine: localEngine, diarizer: diarizer)

        try enqueueRecording(on: queue)
        settings.cloudTranscriptionEnabled = false
        await queue.processNext()

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.transcriptionTarget, .cloud)
        XCTAssertEqual(job.state, .done, job.error ?? "no error")
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(localEngine.transcribeCallCount, 0)
        XCTAssertGreaterThan(diarizer.runCount, 0)
        let transcript = try String(contentsOf: XCTUnwrap(job.transcriptPath), encoding: .utf8)
        XCTAssertTrue(transcript.contains("General Kenobi."), transcript)
    }

    func testAJobQueuedWithCloudOffStaysLocal() async throws {
        let (settings, cleanup) = try makeCloudSettings()
        defer { cleanup() }
        settings.cloudTranscriptionEnabled = false
        nonisolated(unsafe) var uploads = 0
        MockURLProtocol.handler = { request in
            uploads += 1
            return Self.respond(request, body: Self.verboseJSON)
        }
        let localEngine = MockEngine()
        let queue = makeCloudQueue(settings: settings, localEngine: localEngine, diarizer: MockDiarization())

        try enqueueRecording(on: queue)
        settings.cloudTranscriptionEnabled = true
        await queue.processNext()

        XCTAssertEqual(queue.jobs.first?.transcriptionTarget, .local)
        XCTAssertEqual(uploads, 0)
        XCTAssertGreaterThan(localEngine.transcribeCallCount, 0)
    }

    func testMissingSegmentsFailTheJobNamingTheModel() async throws {
        let (settings, cleanup) = try makeCloudSettings()
        defer { cleanup() }
        MockURLProtocol.handler = { Self.respond($0, body: Data(#"{"text":"Hello there."}"#.utf8)) }
        let queue = makeCloudQueue(settings: settings, localEngine: MockEngine(), diarizer: MockDiarization())

        try enqueueRecording(on: queue)
        await queue.processNext()

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.state, .error)
        XCTAssertTrue(job.error?.contains("whisper-1") ?? false, job.error ?? "no error")
    }
}
