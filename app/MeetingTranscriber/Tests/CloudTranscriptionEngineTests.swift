@testable import MeetingTranscriber
import os
import XCTest

/// `CloudTranscriptionEngine` against `MockURLProtocol`: the request it sends,
/// how it reads the answer, and a cloud job run through the real pipeline.
/// No live network.
@MainActor
final class CloudTranscriptionEngineTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!
    /// The waits the engine asked for between retries, recorded instead of slept.
    private var sleeps: [Duration] = []

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
        sleeps = []
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
        let record: @MainActor (Duration) async -> Void = { self.sleeps.append($0) }
        return CloudTranscriptionEngine(configuration: { config }, session: makeMockSession(), sleep: record)
    }

    private static func respond(
        _ request: URLRequest, body: Data, status: Int = 200, headers: [String: String] = [:],
    ) -> (HTTPURLResponse, Data) {
        // swiftlint:disable:next force_unwrapping
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, body)
    }

    /// Request counter shared with the URL loading thread, behind a lock:
    /// the cancellation test reads it while a request is in flight.
    private final class Counter: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)

        var value: Int {
            get { count.withLock { $0 } }
            set { count.withLock { $0 = newValue } }
        }

        /// The current count, then one more; one locked step.
        func next() -> Int {
            count.withLock { current in
                defer { current += 1 }
                return current
            }
        }
    }

    /// Answers the n-th request with the n-th status (the last one repeats);
    /// a 200 carries the verbose JSON.
    private static func serve(
        _ statuses: [Int], headers: [String: String] = [:], errorBody: Data = Data(),
    ) -> Counter {
        let counter = Counter()
        MockURLProtocol.handler = { request in
            let status = statuses[min(counter.next(), statuses.count - 1)]
            return respond(request, body: status == 200 ? verboseJSON : errorBody, status: status, headers: headers)
        }
        return counter
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
            engineResolver: settings.transcriptionEngineResolver(local: { localEngine }, session: makeMockSession()),
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

    /// One track rejected as a file (HTTP 400) is dropped with a warning; the
    /// other track's transcript survives and the job completes.
    func testARejectedTrackIsDroppedAndTheOtherKept() async throws {
        let (settings, cleanup) = try makeCloudSettings()
        defer { cleanup() }
        MockURLProtocol.handler = { request in
            let body = String(bytes: Self.body(of: request), encoding: .isoLatin1) ?? ""
            if body.contains("filename=\"mic_16k.wav\"") {
                return Self.respond(
                    request, body: Data(#"{"error":{"message":"Invalid file format."}}"#.utf8), status: 400,
                )
            }
            return Self.respond(request, body: Self.verboseJSON)
        }
        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            engineResolver: settings.transcriptionEngineResolver(local: { MockEngine() }, session: makeMockSession()),
            transcriptionTargetProvider: { settings.transcriptionTarget },
            stagingDir: tmpDir.appendingPathComponent("unused-staging", isDirectory: true),
            echoDedupEnabled: false,
        )
        func track(_ name: String) throws -> URL {
            let url = tmpDir.appendingPathComponent(name)
            try AudioMixer.saveWAV(
                samples: [Float](repeating: 0.05, count: 160_000), sampleRate: AudioConstants.targetSampleRate, url: url,
            )
            return url
        }

        try queue.enqueue(PipelineJob(
            meetingTitle: "Cloud Call", appName: "Teams",
            mixPath: nil, appPath: track("call_app.wav"), micPath: track("call_mic.wav"), micDelay: 0,
        ))
        await queue.processNext()
        await waitFor(queue.jobs.first?.state.isTerminal ?? false, timeout: .seconds(10))

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.state, .done, job.error ?? "no error")
        let warnings = job.warnings.joined(separator: " | ")
        XCTAssertTrue(warnings.contains("microphone track could not be transcribed"), warnings)
        XCTAssertTrue(warnings.contains("HTTP 400"), warnings)
        XCTAssertTrue(warnings.contains("Invalid file format."), warnings)
        let transcript = try String(contentsOf: XCTUnwrap(job.transcriptPath), encoding: .utf8)
        XCTAssertTrue(transcript.contains("General Kenobi."), transcript)
    }

    /// An engine-wide failure (here a rejected key) fails the job and leaves
    /// the recording where it was.
    func testAnAuthFailureFailsTheJobAndKeepsTheRecording() async throws {
        let (settings, cleanup) = try makeCloudSettings()
        defer { cleanup() }
        _ = Self.serve([401])
        let queue = makeCloudQueue(settings: settings, localEngine: MockEngine(), diarizer: MockDiarization())
        let recording = try createTestAudioFile(in: tmpDir)

        queue.enqueue(PipelineJob(
            meetingTitle: "Cloud Call", appName: "Teams", mixPath: recording, appPath: nil, micPath: nil, micDelay: 0,
        ))
        await queue.processNext()

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.state, .error)
        XCTAssertTrue(job.error?.contains("API key was rejected (HTTP 401)") ?? false, job.error ?? "no error")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
    }
}

// Retry, message and scope tests, kept out of the class body for its length cap.
extension CloudTranscriptionEngineTests {
    private func assertFails(_ engine: CloudTranscriptionEngine, _ audio: URL, line: UInt = #line) async {
        do {
            _ = try await engine.transcribeSegments(audioPath: audio)
            XCTFail("expected the transcription to fail", line: line)
        } catch {}
    }

    // MARK: - Retries

    func testATransientFailureIsRetriedAndThenSucceeds() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        let requests = Self.serve([503, 200])

        let segments = try await makeEngine().transcribeSegments(audioPath: audio)

        XCTAssertEqual(segments.map(\.text), ["Hello there.", "General Kenobi."])
        XCTAssertEqual(requests.value, 2)
        XCTAssertEqual(sleeps, [.seconds(2)])
    }

    /// 429 and every 5xx are retried twice, after about 2 s and then 8 s,
    /// and the last answer is what fails.
    func testRateLimitsAndServerErrorsAreRetriedTwiceThenFail() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        for status in [429, 500, 502, 503] {
            sleeps = []
            let requests = Self.serve([status])

            do {
                _ = try await makeEngine().transcribeSegments(audioPath: audio)
                XCTFail("HTTP \(status) must fail after its retries")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, .httpError(status: status, body: ""), "\(status)")
            }
            XCTAssertEqual(requests.value, 3, "\(status)")
            XCTAssertEqual(sleeps, [.seconds(2), .seconds(8)], "\(status)")
        }
    }

    func testRetryAfterReplacesTheBackoffAndIsCapped() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        _ = Self.serve([429, 200], headers: ["Retry-After": "5"])
        _ = try await makeEngine().transcribeSegments(audioPath: audio)
        XCTAssertEqual(sleeps, [.seconds(5)])

        sleeps = []
        _ = Self.serve([503, 200], headers: ["Retry-After": "3600"])
        _ = try await makeEngine().transcribeSegments(audioPath: audio)
        XCTAssertEqual(sleeps, [CloudTranscriptionEngine.maxRetryAfter])
    }

    func testRetryAfterReadsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 1_445_412_480) // Wed, 21 Oct 2015 07:28:00 GMT
        XCTAssertEqual(CloudTranscriptionEngine.retryAfter("7", now: now), .seconds(7))
        XCTAssertEqual(CloudTranscriptionEngine.retryAfter("Wed, 21 Oct 2015 07:28:30 GMT", now: now), .seconds(30))
        XCTAssertEqual(CloudTranscriptionEngine.retryAfter("Wed, 21 Oct 2015 07:27:00 GMT", now: now), .seconds(0))
        XCTAssertNil(CloudTranscriptionEngine.retryAfter(nil, now: now))
        XCTAssertNil(CloudTranscriptionEngine.retryAfter("soon", now: now))
    }

    func testTransientNetworkErrorsAreRetriedTwice() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        let requests = Counter()
        MockURLProtocol.errorHandler = { _ in
            _ = requests.next()
            return URLError(.networkConnectionLost)
        }

        do {
            _ = try await makeEngine().transcribeSegments(audioPath: audio)
            XCTFail("a lost connection must fail after its retries")
        } catch {
            guard case .network = error as? CloudTranscriptionError else {
                XCTFail("expected a network error, got \(error)")
                return
            }
            XCTAssertTrue(error.localizedDescription.hasPrefix("Cloud transcription failed"), error.localizedDescription)
        }
        XCTAssertEqual(requests.value, 3)
        XCTAssertEqual(sleeps, [.seconds(2), .seconds(8)])
    }

    func testAPermanentNetworkErrorIsNotRetried() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        let requests = Counter()
        MockURLProtocol.errorHandler = { _ in
            _ = requests.next()
            return URLError(.serverCertificateUntrusted)
        }

        await assertFails(makeEngine(), audio)
        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(sleeps, [])
    }

    func testAuthAndRejectedFilesAreNotRetried() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        for status in [400, 401, 403, 404, 413] {
            sleeps = []
            let requests = Self.serve([status])

            await assertFails(makeEngine(), audio)
            XCTAssertEqual(requests.value, 1, "\(status)")
            XCTAssertEqual(sleeps, [], "\(status)")
        }
    }

    /// The real sleeper: cancelling the job during the wait ends it at once,
    /// without another request.
    func testCancellingDuringTheBackoffStopsWithoutAnotherRequest() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        let requests = Self.serve([503])
        let engine = CloudTranscriptionEngine(
            configuration: { Self.config }, session: makeMockSession(), retryDelays: [.seconds(30)],
        )

        let task = Task { try await engine.transcribeSegments(audioPath: audio) }
        await waitFor(requests.value == 1, timeout: .seconds(5))
        let started = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled transcription must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertEqual(requests.value, 1)
    }

    // MARK: - Messages

    func testAnAuthFailureSaysTheKeyWasRejectedWithTheProvidersMessage() async throws {
        let audio = try createTestAudioFile(in: tmpDir)
        _ = Self.serve([401], errorBody: Data(#"""
        {"error":{"message":"Incorrect API key provided: sk-test.","type":"invalid_request_error"}}
        """#.utf8))

        do {
            _ = try await makeEngine().transcribeSegments(audioPath: audio)
            XCTFail("a 401 must fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Cloud transcription failed: the API key was rejected (HTTP 401): Incorrect API key provided: [redacted].",
            )
            XCTAssertFalse(error.localizedDescription.contains("sk-test"))
        }
    }

    func testANonJSONErrorBodyIsCappedAt500Characters() {
        let message = CloudTranscriptionEngine.errorMessage(Data(String(repeating: "x", count: 900).utf8), redacting: "")
        XCTAssertEqual(message.count, 500)
    }

    // MARK: - Failure scope

    /// Only a rejected file can be dropped from a dual-source job; everything
    /// else would fail the other track the same way.
    func testOnlyARejectedFileIsTheFilesFailure() {
        for status in [400, 413] {
            XCTAssertEqual(TranscriptionFailureScope.of(CloudTranscriptionError.httpError(status: status, body: "")), .file)
        }
        let engineWide: [CloudTranscriptionError] = [
            .httpError(status: 401, body: ""), .httpError(status: 403, body: ""), .httpError(status: 404, body: ""),
            .httpError(status: 429, body: ""), .httpError(status: 500, body: ""), .httpError(status: 503, body: ""),
            .network("offline"), .invalidBaseURL("x"), .invalidResponse, .missingSegments(model: "m"),
        ]
        for error in engineWide {
            XCTAssertEqual(TranscriptionFailureScope.of(error), .engine, "\(error)")
        }
    }
}
