import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Long recordings cut into pieces for cloud transcription: where the cuts
/// fall, what each request uploads, and how piece times are put back on the
/// recording's timeline. Pieces are seconds long here through the injected
/// `pieceDuration`; production uses ten minutes.
@MainActor
final class CloudTranscriptionSplittingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!
    private static let rate = 16000

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "cloud_splitting_test")
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        tmpDir = nil
        try await super.tearDown()
    }

    /// Uploads seen on the URL loading thread.
    private final class Uploads: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [(contentType: String, body: Data)] = []

        func append(_ contentType: String, _ body: Data) {
            lock.withLock { bodies.append((contentType, body)) }
        }

        var all: [(contentType: String, body: Data)] {
            lock.withLock { bodies }
        }
    }

    /// Answers request n with one segment at 0.1–0.5 s reading "piece n";
    /// `failAt` answers that request with a 401 instead.
    private static func serve(failAt: Int? = nil) -> Uploads {
        let uploads = Uploads()
        MockURLProtocol.handler = { request in
            uploads.append(request.value(forHTTPHeaderField: "Content-Type") ?? "", body(of: request))
            let number = uploads.all.count
            let failed = number == failAt
            let json = failed
                ? #"{"error":{"message":"bad key"}}"#
                : #"{"segments":[{"start":0.1,"end":0.5,"text":"piece \#(number)"}]}"#
            // swiftlint:disable:next force_unwrapping
            let response = HTTPURLResponse(url: request.url!, statusCode: failed ? 401 : 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        return uploads
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

    /// The WAV bytes of an upload's `file` part.
    private static func wavBytes(_ upload: (contentType: String, body: Data)) throws -> Data {
        let boundary = try XCTUnwrap(upload.contentType.components(separatedBy: "boundary=").last)
        let start = try XCTUnwrap(upload.body.range(of: Data("Content-Type: audio/wav\r\n\r\n".utf8))).upperBound
        let trailer = Data("\r\n--\(boundary)--\r\n".utf8)
        return upload.body.subdata(in: start ..< upload.body.count - trailer.count)
    }

    /// The uploaded WAV opened as an audio file.
    private func uploadedAudio(_ upload: (contentType: String, body: Data)) throws -> AVAudioFile {
        let url = tmpDir.appendingPathComponent("upload_\(UUID().uuidString).wav")
        try Self.wavBytes(upload).write(to: url)
        return try AVAudioFile(forReading: url)
    }

    /// A 440 Hz tone with silence over `gaps` (seconds), written as 16-bit or
    /// Float32 WAV under a unique name.
    private func makeRecording(seconds: Double, gaps: [ClosedRange<Double>] = [], float32: Bool = false) throws -> URL {
        let samples = (0 ..< Int(seconds * Double(Self.rate))).map { index -> Float in
            let time = Double(index) / Double(Self.rate)
            return gaps.contains { $0.contains(time) } ? 0 : 0.5 * Float(sin(2 * .pi * 440 * time))
        }
        let url = tmpDir.appendingPathComponent("rec_\(UUID().uuidString).wav")
        guard float32 else {
            try AudioMixer.saveWAV(samples: samples, sampleRate: Self.rate, url: url)
            return url
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            buffer.floatChannelData?[0][index] = sample
        }
        try file.write(from: buffer)
        return url
    }

    private func makeEngine(maxPassthroughBytes: Int = 24_000_000) -> CloudTranscriptionEngine {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        return CloudTranscriptionEngine(
            configuration: { CloudTranscriptionConfiguration(baseURL: "https://cloud.test/v1", model: "whisper-1", apiKey: "sk") },
            session: URLSession(configuration: sessionConfig),
            sleep: { _ in },
            pieceDuration: 2,
            searchWindow: 1,
            maxPassthroughBytes: maxPassthroughBytes,
        )
    }

    // MARK: - Through transcribeSegments

    /// 5 s, pieces of 2 s searched over the last second: the first cut lands in
    /// the 1.4–1.8 s gap (at 1.7 s, the later silent frame's centre), the second
    /// finds only tone and falls on its boundary at 3.7 s.
    func testALongRecordingIsCutAtTheQuietGapAndEachPieceIsOffset() async throws {
        let audio = try makeRecording(seconds: 5, gaps: [1.4 ... 1.8])
        let uploads = Self.serve()
        let engine = makeEngine()

        let segments = try await engine.transcribeSegments(audioPath: audio)

        XCTAssertEqual(uploads.all.count, 3)
        XCTAssertEqual(try uploads.all.map { try uploadedAudio($0).length }, [27200, 32000, 20800])
        XCTAssertEqual(segments.map(\.text), ["piece 1", "piece 2", "piece 3"])
        for (segment, expected) in zip(segments, [0.1, 1.8, 3.8]) {
            XCTAssertEqual(segment.start, expected, accuracy: 1e-9)
            XCTAssertEqual(segment.end, expected + 0.4, accuracy: 1e-9)
        }
        XCTAssertEqual(engine.transcriptionProgress, 1)
        let stem = audio.deletingPathExtension().lastPathComponent
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix(stem) }
        XCTAssertEqual(leftovers, [], "pieces must be deleted after upload")
    }

    func testWithoutAQuietPointEachPieceIsHardCutAtItsBoundary() async throws {
        let audio = try makeRecording(seconds: 5)
        let uploads = Self.serve()

        let segments = try await makeEngine().transcribeSegments(audioPath: audio)

        XCTAssertEqual(try uploads.all.map { try uploadedAudio($0).length }, [32000, 32000, 16000])
        for (segment, expected) in zip(segments, [0.1, 2.1, 4.1]) {
            XCTAssertEqual(segment.start, expected, accuracy: 1e-9)
        }
    }

    /// A Float32 source still uploads 16-bit pieces, half the bytes, so ten
    /// minutes stays near 19 MB, well under the 25 MB provider limit.
    func testPiecesAre16BitPCMWhateverTheSourceFormat() async throws {
        let audio = try makeRecording(seconds: 5, float32: true)
        let uploads = Self.serve()

        _ = try await makeEngine().transcribeSegments(audioPath: audio)

        XCTAssertEqual(uploads.all.count, 3)
        for upload in uploads.all {
            let file = try uploadedAudio(upload)
            XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
            XCTAssertEqual(file.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool, false)
            XCTAssertLessThan(try Self.wavBytes(upload).count, Int(file.length) * 2 + 8192)
        }
        let tenMinuteBytes = CloudAudioSplitter.defaultPieceDuration * Double(Self.rate) * 2
        XCTAssertLessThan(tenMinuteBytes, 20_000_000)
    }

    func testAFailedPieceFailsTheTrackWithItsError() async throws {
        let audio = try makeRecording(seconds: 5)
        let uploads = Self.serve(failAt: 2)

        do {
            _ = try await makeEngine().transcribeSegments(audioPath: audio)
            XCTFail("expected the second piece's 401")
        } catch let CloudTranscriptionError.httpError(status, body, _) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(body, "bad key")
        }
        XCTAssertEqual(uploads.all.count, 2, "the third piece is not sent")
    }

    func testARecordingUpToOnePieceIsSentWhole() async throws {
        let audio = try makeRecording(seconds: 2)
        let uploads = Self.serve()

        let segments = try await makeEngine().transcribeSegments(audioPath: audio)

        XCTAssertEqual(uploads.all.count, 1)
        XCTAssertEqual(try Self.wavBytes(uploads.all[0]), try Data(contentsOf: audio))
        XCTAssertEqual(segments.first?.start ?? -1, 0.1, accuracy: 1e-9)
    }

    /// Eight minutes of 16 kHz Float32 is 30.7 MB, over a 25 MB provider cap
    /// though under one piece; such a file goes up rewritten as 16-bit.
    func testAOnePieceRecordingOverTheUploadCapIsSentAs16Bit() async throws {
        let audio = try makeRecording(seconds: 2, float32: true)
        let size = try Data(contentsOf: audio).count
        let uploads = Self.serve()

        let segments = try await makeEngine(maxPassthroughBytes: size - 1).transcribeSegments(audioPath: audio)

        XCTAssertEqual(uploads.all.count, 1)
        let file = try uploadedAudio(uploads.all[0])
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        // AVAudioFile's Float32-to-16-bit write keeps back its last 256 frames.
        try XCTAssertEqual(Double(file.length), Double(AVAudioFile(forReading: audio).length), accuracy: 256)
        XCTAssertEqual(segments.first?.start ?? -1, 0.1, accuracy: 1e-9)
    }

    func testCancelledPlanningDoesNotFallBackToAnUnreadableUpload() async {
        let missing = tmpDir.appendingPathComponent("missing.wav")
        let engine = makeEngine()
        let uploads = Self.serve()
        let job = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.transcribeSegments(audioPath: missing)
        }

        do {
            _ = try await job.value
            XCTFail("cancelled preparation must stop the upload")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected failure: \(error)")
        }
        XCTAssertTrue(uploads.all.isEmpty)
    }

    // MARK: - Cut-point selection

    private static let tone = (0 ..< 3200).map { Float(0.5 * sin(Double($0) * 0.17)) }
    private static let silence = [Float](repeating: 0, count: 3200)

    func testQuietCutIsNilWhenNoFrameIsQuiet() {
        XCTAssertNil(CloudAudioSplitter.quietCut(in: Self.tone + Self.tone, sampleRate: 16000))
    }

    func testQuietCutPicksTheQuietestFrame() {
        let soft = Self.tone.map { $0 * 0.005 } // about -49 dBFS
        let window = soft + Self.tone + Self.silence + Self.tone
        XCTAssertEqual(CloudAudioSplitter.quietCut(in: window, sampleRate: 16000), 2 * 3200 + 1600)
    }

    func testQuietCutPrefersTheLaterOfEquallyQuietFrames() {
        let window = Self.silence + Self.tone + Self.silence + Self.tone
        XCTAssertEqual(CloudAudioSplitter.quietCut(in: window, sampleRate: 16000), 2 * 3200 + 1600)
    }

    func testPlanPiecesKeepsARecordingOfExactlyOnePieceWhole() {
        let pieces = CloudAudioSplitter.planPieces(
            totalFrames: 100, pieceFrames: 100, windowFrames: 10, sampleRate: 16000,
        ) { _ in XCTFail("no window is read"); return [] }
        XCTAssertEqual(pieces, [0 ..< 100])
    }

    func testPlanPiecesReadsOnlyTheSearchWindows() {
        var windows: [Range<Int>] = []
        let pieces = CloudAudioSplitter.planPieces(
            totalFrames: 250, pieceFrames: 100, windowFrames: 30, sampleRate: 16000,
        ) { range in windows.append(range); return [Float](repeating: 0.5, count: range.count) }
        XCTAssertEqual(windows, [70 ..< 100, 170 ..< 200])
        XCTAssertEqual(pieces, [0 ..< 100, 100 ..< 200, 200 ..< 250])
    }
}
