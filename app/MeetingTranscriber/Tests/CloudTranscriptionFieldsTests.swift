@testable import MeetingTranscriber
import XCTest

/// The `language` and `prompt` fields a cloud request carries, and each Test
/// Connection outcome, against `MockURLProtocol`. No live network.
@MainActor
final class CloudTranscriptionFieldsTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    private static let config = CloudTranscriptionConfiguration(
        baseURL: "https://cloud.test/v1", model: "whisper-1", apiKey: "sk-test",
    )
    private static let verboseJSON = Data(#"{"segments":[{"start":0.0,"end":1.0,"text":" Hi."}]}"#.utf8)

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "cloud_fields_test")
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.errorHandler = nil
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        tmpDir = nil
        try await super.tearDown()
    }

    private func makeSession() -> URLSession {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: sessionConfig)
    }

    /// Request bodies seen on the URL loading thread, decoded as Latin-1 so the
    /// binary WAV part cannot fail the decode.
    private final class Bodies: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String] = []

        func append(_ body: String) {
            lock.withLock { bodies.append(body) }
        }

        var all: [String] {
            lock.withLock { bodies }
        }
    }

    private static func serve(status: Int = 200, body: Data = verboseJSON) -> Bodies {
        let bodies = Bodies()
        MockURLProtocol.handler = { request in
            bodies.append(String(bytes: Self.body(of: request), encoding: .isoLatin1) ?? "")
            // swiftlint:disable:next force_unwrapping
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
        return bodies
    }

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

    private func transcribe(
        _ config: CloudTranscriptionConfiguration, audio: URL? = nil, pieceDuration: TimeInterval = 600,
    ) async throws {
        let engine = CloudTranscriptionEngine(
            configuration: { config }, session: makeSession(), sleep: { _ in },
            pieceDuration: pieceDuration, searchWindow: 1,
        )
        _ = try await engine.transcribeSegments(audioPath: audio ?? createTestAudioFile(in: tmpDir))
    }

    // MARK: - Language

    func testAnExplicitLanguageIsSent() async throws {
        let bodies = Self.serve()
        var config = Self.config
        config.language = "id"

        try await transcribe(config)

        XCTAssertEqual(try Self.field("language", in: XCTUnwrap(bodies.all.first)), "id")
    }

    func testAutoDetectSendsNoLanguage() async throws {
        let bodies = Self.serve()

        try await transcribe(Self.config)

        XCTAssertNil(try Self.field("language", in: XCTUnwrap(bodies.all.first)))
    }

    func testPickerCodesWithoutAnISO6391CodeAreMapped() {
        XCTAssertEqual(CloudTranscriptionEngine.isoLanguage("fil"), "tl")
        XCTAssertEqual(CloudTranscriptionEngine.isoLanguage("yue"), "zh")
        XCTAssertEqual(CloudTranscriptionEngine.isoLanguage("de"), "de")
        XCTAssertNil(CloudTranscriptionEngine.isoLanguage(""))
    }

    // MARK: - Vocabulary prompt

    func testVocabularyTermsAreSentAsPrompt() async throws {
        let bodies = Self.serve()
        var config = Self.config
        config.vocabularyTerms = ["Acme", "Speaker A"]

        try await transcribe(config)

        XCTAssertEqual(try Self.field("prompt", in: XCTUnwrap(bodies.all.first)), "Acme, Speaker A")
    }

    func testNoVocabularySendsNoPrompt() async throws {
        let bodies = Self.serve()

        try await transcribe(Self.config)

        XCTAssertNil(try Self.field("prompt", in: XCTUnwrap(bodies.all.first)))
    }

    /// Whole terms in file order up to the character budget; one that would
    /// overrun is skipped and a shorter later one still fits.
    func testThePromptIsBoundedByTheCharacterBudget() async throws {
        let bodies = Self.serve()
        var config = Self.config
        config.vocabularyTerms = [
            "Alpha", String(repeating: "x", count: 130), "Beta",
            String(repeating: "y", count: 30), String(repeating: "z", count: 100), "Gamma",
        ]

        try await transcribe(config)

        let prompt = try XCTUnwrap(try Self.field("prompt", in: XCTUnwrap(bodies.all.first)))
        XCTAssertLessThanOrEqual(prompt.count, WhisperVocabularyPrompt.defaultCharacterBudget)
        XCTAssertEqual(prompt, "Alpha, Beta, \(String(repeating: "y", count: 30)), Gamma")
    }

    func testEveryPieceOfASplitRecordingCarriesLanguageAndPrompt() async throws {
        let samples = (0 ..< 5 * 16000).map { 0.5 * Float(sin(2 * .pi * 440 * Double($0) / 16000)) }
        let audio = tmpDir.appendingPathComponent("long.wav")
        try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: audio)
        let bodies = Self.serve()
        var config = Self.config
        config.language = "en"
        config.vocabularyTerms = ["Acme"]

        try await transcribe(config, audio: audio, pieceDuration: 2)

        XCTAssertEqual(bodies.all.count, 3)
        for body in bodies.all {
            XCTAssertEqual(Self.field("language", in: body), "en")
            XCTAssertEqual(Self.field("prompt", in: body), "Acme")
        }
    }

    // MARK: - Test Connection

    func testConnectionSucceedsWhenSegmentsComeBack() async throws {
        let bodies = Self.serve()

        let result = await CloudTranscriptionEngine.testConnection(Self.config, session: makeSession())

        XCTAssertEqual(result, .success)
        XCTAssertEqual(bodies.all.count, 1)
        XCTAssertEqual(try Self.field("model", in: XCTUnwrap(bodies.all.first)), "whisper-1")
    }

    func testConnectionReportsARejectedKeyWithoutRetrying() async {
        let bodies = Self.serve(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))

        let result = await CloudTranscriptionEngine.testConnection(Self.config, session: makeSession())

        XCTAssertEqual(result, .authFailed(status: 401))
        XCTAssertEqual(bodies.all.count, 1)
    }

    func testConnectionReportsAnUnreachableHostWithoutRetrying() async {
        nonisolated(unsafe) var attempts = 0
        MockURLProtocol.errorHandler = { _ in
            attempts += 1
            return URLError(.cannotFindHost)
        }

        let result = await CloudTranscriptionEngine.testConnection(Self.config, session: makeSession())

        guard case .unreachable = result else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(attempts, 1, "a transient error must not be retried by the test")
    }

    func testConnectionNamesAModelWithoutTimestamps() async {
        _ = Self.serve(body: Data(#"{"text":"Hi."}"#.utf8))
        var config = Self.config
        config.model = "gpt-4o-transcribe"

        let result = await CloudTranscriptionEngine.testConnection(config, session: makeSession())

        XCTAssertEqual(result, .missingTimestamps(model: "gpt-4o-transcribe"))
        XCTAssertTrue(result.message.contains("gpt-4o-transcribe"), result.message)
    }

    func testConnectionCarriesTheProvidersMessageForAnotherHTTPError() async {
        _ = Self.serve(status: 404, body: Data(#"{"error":{"message":"model not found"}}"#.utf8))

        let result = await CloudTranscriptionEngine.testConnection(Self.config, session: makeSession())

        guard case let .failed(message) = result else {
            XCTFail("\(result)")
            return
        }
        XCTAssertTrue(message.contains("HTTP 404"), message)
        XCTAssertTrue(message.contains("model not found"), message)
    }
}
