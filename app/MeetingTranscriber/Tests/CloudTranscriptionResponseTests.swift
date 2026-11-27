@testable import MeetingTranscriber
import os
import XCTest

/// What `CloudTranscriptionEngine` makes of a provider's answer: timestamps it
/// cannot trust, error text kept out of public logs, a 400's scope, and the
/// partial upload body a failed write leaves.
@MainActor
final class CloudTranscriptionResponseTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "cloud_response_test")
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.redirectHandler = nil
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        tmpDir = nil
        try await super.tearDown()
    }

    private func transcribe(answering json: String, seconds: Int = 2) async throws -> [TimestampedSegment] {
        let audio = tmpDir.appendingPathComponent("rec_\(UUID().uuidString).wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: seconds * 16000), sampleRate: 16000, url: audio)
        MockURLProtocol.handler = { request in
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let engine = CloudTranscriptionEngine(
            configuration: { CloudTranscriptionConfiguration(baseURL: "https://cloud.test/v1", model: "whisper-1", apiKey: "sk") },
            session: URLSession(configuration: sessionConfig),
            sleep: { _ in },
            pieceDuration: CloudAudioSplitter.defaultPieceDuration,
        )
        return try await engine.transcribeSegments(audioPath: audio)
    }

    private func assertRejected(_ json: String, line: UInt = #line) async {
        do {
            _ = try await transcribe(answering: json)
            XCTFail("expected invalid timestamps", line: line)
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .invalidTimestamps, line: line)
        }
    }

    // MARK: - Timestamps

    /// 1e300 is a finite Double that `Int(time)` traps on when the transcript is
    /// rendered, before the job could be marked failed.
    func testATimestampFarPastTheRecordingIsClampedToItsEnd() async throws {
        let segments = try await transcribe(answering: #"{"segments":[{"start":1e300,"end":1e300,"text":"x"}]}"#)

        XCTAssertEqual(segments.first?.start ?? -1, 2.0, accuracy: 1e-9)
        XCTAssertEqual(segments.first?.formattedTimestamp, "[00:02]")
    }

    func testANegativeOrBackwardsSegmentFailsTheTrack() async {
        await assertRejected(#"{"segments":[{"start":-1,"end":0.5,"text":"x"}]}"#)
        await assertRejected(#"{"segments":[{"start":1.5,"end":0.5,"text":"x"}]}"#)
    }

    func testAnEndPastTheRecordingIsClampedToIt() async throws {
        let segments = try await transcribe(answering: #"{"segments":[{"start":1.5,"end":2.4,"text":"x"}]}"#)

        XCTAssertEqual(segments.first?.end ?? -1, 2.0, accuracy: 1e-9)
    }

    func testRecognizedTextWithoutTimedSegmentsFailsButSilenceSucceeds() async throws {
        do {
            _ = try await transcribe(answering: #"{"text":"Spoken words","segments":[]}"#)
            XCTFail("recognized words require timestamps")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .missingSegments(model: "whisper-1"))
        }

        let silence = try await transcribe(answering: #"{"text":"","segments":[]}"#)
        XCTAssertTrue(silence.isEmpty)
    }

    // MARK: - Error text

    /// A key that crosses the 500-character cut would otherwise keep its prefix.
    func testTheKeyIsRedactedBeforeTheBodyIsCut() {
        let key = "sk-0123456789abcdef"
        let body = String(repeating: "x", count: 490) + key
        let message = CloudTranscriptionEngine.errorMessage(Data(body.utf8), redacting: key)

        XCTAssertFalse(message.contains("sk-0123"), message)
        XCTAssertEqual(message.count, CloudTranscriptionEngine.errorMessageLimit)
    }

    /// The provider's text can echo the vocabulary prompt; only status and kind
    /// go to the public log.
    func testThePublicLogDescriptionCarriesNoProviderText() {
        let error = CloudTranscriptionError.httpError(status: 400, body: "prompt: Kubernetes, Grafana", param: "prompt")

        XCTAssertEqual(CloudTranscriptionError.publicLogDescription(of: error), "http status=400 param=prompt")
        XCTAssertEqual(
            CloudTranscriptionError.publicLogDescription(of: CocoaError(.fileNoSuchFile)),
            CocoaError(.fileNoSuchFile).localizedDescription,
        )
    }

    // MARK: - Failure scope

    /// A 400 naming another field fails the other track the same way, so the
    /// job ends instead of uploading it.
    func testA400NamingAnotherRequestFieldIsTheEnginesFailure() {
        XCTAssertEqual(TranscriptionFailureScope.of(CloudTranscriptionError.httpError(status: 400, body: "", param: "file")), .file)
        for param in ["model", "response_format"] {
            XCTAssertEqual(
                TranscriptionFailureScope.of(CloudTranscriptionError.httpError(status: 400, body: "", param: param)),
                .engine, param,
            )
        }
    }

    func testTheParamIsReadFromTheErrorEnvelope() {
        let litellm = Data(#"{"error":{"message":"m","type":"t","param":"None","code":"400"}}"#.utf8)
        let openAI = Data(#"{"error":{"message":"m","param":"response_format"}}"#.utf8)

        XCTAssertNil(CloudTranscriptionEngine.errorDetail(litellm, redacting: "").param)
        XCTAssertEqual(CloudTranscriptionEngine.errorDetail(openAI, redacting: "").param, "response_format")
    }

    // MARK: - Redirects

    /// A 307 or 308 replays the body, so without the refuser the recording
    /// (and, on the same origin, the key) would go to a host nobody configured.
    func testTheUploadRefusesARedirectToAnotherHost() async throws {
        let hosts = OSAllocatedUnfairLock<[String]>(initialState: [])
        let elsewhere = try XCTUnwrap(URL(string: "https://elsewhere.test/v1/audio/transcriptions"))
        MockURLProtocol.redirectHandler = { request in
            hosts.withLock { $0.append(request.url?.host ?? "?") }
            return request.url?.host == "cloud.test" ? (307, elsewhere) : nil
        }

        do {
            _ = try await transcribe(answering: #"{"segments":[]}"#)
            XCTFail("expected the refused redirect to fail the upload")
        } catch {}

        XCTAssertEqual(hosts.withLock { $0 }, ["cloud.test"], "the recording reached another host")
    }

    // MARK: - Upload body

    func testAFailedBodyWriteLeavesNoPartialFile() async {
        let destination = tmpDir.appendingPathComponent("body.multipart")

        do {
            try await CloudUploadPreparation().writeMultipartBody(
                to: destination, boundary: "b", audioPath: tmpDir.appendingPathComponent("missing.wav"), model: "m",
            )
            XCTFail("a missing input must fail the copy")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
