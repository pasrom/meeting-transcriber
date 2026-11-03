import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "CloudTranscriptionEngine")

/// Where and how a recording is sent for cloud transcription. Read when a
/// track is transcribed, not when the job is queued: only the choice of
/// cloud over local is captured per job.
struct CloudTranscriptionConfiguration: Equatable {
    /// OpenAI-compatible API base, e.g. `https://api.openai.com/v1`.
    var baseURL: String
    var model: String
    /// Sent as a Bearer token; empty sends no `Authorization` header.
    var apiKey: String
}

enum CloudTranscriptionError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    /// `body` is the provider's own error message when it sent one, else the
    /// first 500 characters of the response, with the API key redacted.
    /// `param` is the request field the provider blamed, when it named one.
    case httpError(status: Int, body: String, param: String? = nil)
    /// The request did not complete; carries the transport's description.
    case network(String)
    case invalidResponse
    /// A segment timestamp that is not a time: negative, or an end before its start.
    case invalidTimestamps
    /// The response carried no segment timestamps, which diarization needs.
    case missingSegments(model: String)

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            "Cloud transcription base URL is not valid: \"\(value)\""

        case let .httpError(status, body, _):
            "Cloud transcription failed: \(Self.reason(status: status)) (HTTP \(status))"
                + (body.isEmpty ? "" : ": \(body)")

        case let .network(description):
            "Cloud transcription failed: the provider could not be reached (\(description))"

        case .invalidResponse:
            "Cloud transcription returned a response that is not a transcription"

        case .invalidTimestamps:
            "Cloud transcription returned segment timestamps that are not valid times"

        case let .missingSegments(model):
            "Cloud model \"\(model)\" returned no segment timestamps. "
                + "Choose a model that supports response_format=verbose_json with segment timestamps, such as whisper-1."
        }
    }

    /// Only known request fields are public: even the parameter name is provider text.
    private static let publicParams: Set<String> = [
        "file", "model", "language", "prompt", "response_format", "temperature", "timestamp_granularities",
    ]

    /// Status and kind only: the description can carry the provider's text,
    /// which may echo the vocabulary or the key, so it stays out of public logs.
    var logSummary: String {
        switch self {
        case .invalidBaseURL: "invalid_base_url"
        case let .httpError(status, _, param): "http status=\(status) param=\(Self.publicParam(param))"
        case .network: "network"
        case .invalidResponse: "invalid_response"
        case .invalidTimestamps: "invalid_timestamps"
        case .missingSegments: "missing_segments"
        }
    }

    private static func publicParam(_ param: String?) -> String {
        guard let param else { return "-" }
        return publicParams.contains(param) ? param : "other"
    }

    /// `logSummary` for a cloud error, else the error's own description.
    static func publicLogDescription(of error: any Error) -> String {
        (error as? Self)?.logSummary ?? error.localizedDescription
    }

    private static func reason(status: Int) -> String {
        switch status {
        case 401, 403: "the API key was rejected"
        case 400: "the provider could not process this audio"
        case 413: "the recording is too large for the provider"
        case 429: "the provider is rate limiting requests or the quota is used up"
        case 500 ... 599: "the provider had a server error"
        default: "the provider refused the request"
        }
    }
}

/// Transcribes through an OpenAI-compatible `/audio/transcriptions` endpoint.
/// A recording up to `pieceDuration` goes up in one request; a longer one is
/// cut into pieces (`CloudAudioSplitter`) sent one after another. Diarization
/// stays local.
@MainActor
final class CloudTranscriptionEngine: TranscribingEngine {
    /// Nothing to download or load: the model runs at the provider.
    let modelState: EngineModelState = .loaded
    let downloadProgress: Double = 0
    private(set) var transcriptionProgress: Double = 0

    private let configuration: @MainActor () -> CloudTranscriptionConfiguration
    private let preparation = CloudUploadPreparation()
    private let session: URLSession
    /// Idle timeout between received bytes; an upload of a long recording can
    /// take minutes but keeps bytes moving.
    private let timeoutSeconds: TimeInterval
    /// Waits before each retry of a transient failure; its count is the
    /// number of retries per request.
    private let retryDelays: [Duration]
    /// Longest `Retry-After` honoured, so a provider cannot park a job for an hour.
    static let maxRetryAfter: Duration = .seconds(60)
    /// Injected so tests do not wait; throws on cancellation.
    private let sleep: @MainActor (Duration) async throws -> Void
    /// Longest piece sent in one request; injectable so tests use seconds.
    private let pieceDuration: TimeInterval
    /// Largest single-piece file uploaded unchanged, below the 25 MB cap that
    /// OpenAI's endpoint sets once the multipart framing is added; injectable
    /// so tests need no large file.
    private let maxPassthroughBytes: Int
    /// How far before a piece boundary a quiet cut point is searched for.
    private let searchWindow: TimeInterval

    init(
        configuration: @escaping @MainActor () -> CloudTranscriptionConfiguration,
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 600,
        retryDelays: [Duration] = [.seconds(2), .seconds(8)],
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pieceDuration: TimeInterval = CloudAudioSplitter.defaultPieceDuration,
        searchWindow: TimeInterval = CloudAudioSplitter.defaultSearchWindow,
        maxPassthroughBytes: Int = 24_000_000,
    ) {
        self.configuration = configuration
        self.session = session
        self.timeoutSeconds = timeoutSeconds
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.pieceDuration = pieceDuration
        self.searchWindow = searchWindow
        self.maxPassthroughBytes = maxPassthroughBytes
    }

    func loadModel() async {} // swiftlint:disable:this async_without_await

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        let config = configuration()
        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmedBase), base.scheme != nil, base.host != nil else {
            throw CloudTranscriptionError.invalidBaseURL(trimmedBase)
        }
        let url = base.appendingPathComponent("audio").appendingPathComponent("transcriptions")

        transcriptionProgress = 0
        // A file AVAudioFile cannot read goes up whole, so the provider's
        // verdict (a 400, the track's own failure) decides as before.
        guard let (pieces, sampleRate, sendOriginal) = try await preparation.planPieces(
            of: audioPath, pieceDuration: pieceDuration, searchWindow: searchWindow, maxPassthroughBytes: maxPassthroughBytes,
        ) else {
            let segments = try await transcribeFile(audioPath, duration: nil, url: url, config: config)
            transcriptionProgress = 1
            return segments
        }
        // One piece goes up as it is unless its sample format makes it too large
        // (Float32 is twice 16-bit); then it is rewritten as 16-bit like any piece.
        if sendOriginal {
            let segments = try await transcribeFile(
                audioPath, duration: Double(pieces[0].count) / sampleRate, url: url, config: config,
            )
            transcriptionProgress = 1
            return segments
        }

        if pieces.count > 1 { logger.info("cloud_transcription_split pieces=\(pieces.count)") }
        let stem = audioPath.deletingPathExtension().lastPathComponent
        var result: [TimestampedSegment] = []
        for (index, range) in pieces.enumerated() {
            try Task.checkCancellation()
            let pieceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(stem)_part\(index + 1)_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: pieceURL) }
            try await preparation.writePiece(of: audioPath, range: range, to: pieceURL)
            let offset = Double(range.lowerBound) / sampleRate
            let duration = Double(range.count) / sampleRate
            for segment in try await transcribeFile(pieceURL, duration: duration, url: url, config: config) {
                var shifted = segment
                shifted.start += offset
                shifted.end += offset
                result.append(shifted)
            }
            transcriptionProgress = Double(index + 1) / Double(pieces.count)
        }
        return result
    }

    /// One file in one request, through the retry loop. `duration` bounds the
    /// timestamps the provider may return; nil when the file could not be read.
    private func transcribeFile(
        _ audioPath: URL, duration: TimeInterval?, url: URL, config: CloudTranscriptionConfiguration,
    ) async throws -> [TimestampedSegment] {
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud_transcription_\(UUID().uuidString).multipart")
        try await preparation.writeMultipartBody(
            to: bodyFile, boundary: boundary, audioPath: audioPath, model: config.model, fields: [],
        )
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        logger.info("cloud_transcription_upload host=\(url.host ?? "?", privacy: .public) model=\(config.model, privacy: .public)")
        var attempt = 0
        while true {
            try Task.checkCancellation()
            switch try await send(request, bodyFile: bodyFile, config: config, duration: duration) {
            case let .done(segments):
                return segments

            case let .transient(error, retryAfter):
                guard attempt < retryDelays.count else { throw error }
                let delay = min(retryAfter ?? retryDelays[attempt], Self.maxRetryAfter)
                attempt += 1
                logger.warning(
                    "cloud_transcription_retry attempt=\(attempt) delay=\(delay, privacy: .public) error=\(error.logSummary, privacy: .public) detail=\(error.localizedDescription, privacy: .private)",
                )
                try await sleep(delay)
            }
        }
    }

    private enum Attempt {
        case done([TimestampedSegment])
        /// Worth another try: a dropped connection, a 429 or a 5xx.
        case transient(CloudTranscriptionError, retryAfter: Duration?)
    }

    /// Transport failures worth retrying; anything else (a bad certificate,
    /// an unsupported URL) fails the same way the next time.
    private static let transientCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    /// One request. Throws what retrying cannot fix: auth, a rejected file,
    /// any other 4xx, an unreadable answer.
    private func send(
        _ request: URLRequest, bodyFile: URL, config: CloudTranscriptionConfiguration, duration: TimeInterval?,
    ) async throws -> Attempt {
        let data: Data
        let response: URLResponse
        do {
            // The refuser keeps a cross-origin 307/308 from replaying the recording
            // to a host the user did not configure.
            (data, response) = try await session.upload(
                for: request, fromFile: bodyFile, delegate: CrossOriginRedirectRefuser(),
            )
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            let failure = CloudTranscriptionError.network(error.localizedDescription)
            guard Self.transientCodes.contains(error.code) else { throw failure }
            return .transient(failure, retryAfter: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let detail = Self.errorDetail(data, redacting: config.apiKey)
            let failure = CloudTranscriptionError.httpError(
                status: http.statusCode, body: detail.message, param: detail.param,
            )
            guard http.statusCode == 429 || (500 ... 599).contains(http.statusCode) else { throw failure }
            return .transient(failure, retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }
        return try .done(Self.parseSegments(data, model: config.model, duration: duration))
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let message: String
            let param: String?
        }

        let error: Detail
    }

    static let errorMessageLimit = 500

    /// The provider's `{"error":{"message":…}}` when present, else the body,
    /// cut to `errorMessageLimit` characters. Some providers echo the key back;
    /// it is redacted before the cut, so no prefix of it survives at the edge.
    static func errorMessage(_ data: Data, redacting apiKey: String) -> String {
        errorDetail(data, redacting: apiKey).message
    }

    /// `errorMessage` plus the `param` the provider blamed. "None" is LiteLLM's
    /// spelling of no param.
    static func errorDetail(_ data: Data, redacting apiKey: String) -> (message: String, param: String?) {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let raw = envelope?.error.message ?? String(bytes: data, encoding: .utf8) ?? ""
        let redacted = apiKey.isEmpty ? raw : raw.replacingOccurrences(of: apiKey, with: "[redacted]")
        let message = String(redacted.trimmingCharacters(in: .whitespacesAndNewlines).prefix(errorMessageLimit))
        let param = envelope?.error.param.flatMap { $0.isEmpty || $0 == "None" ? nil : $0 }
        return (message, param)
    }

    /// `Retry-After` as delta-seconds or an HTTP-date; nil when absent or unreadable.
    static func retryAfter(_ value: String?, now: Date = Date()) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return .seconds(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(0, Int(date.timeIntervalSince(now).rounded(.up))))
    }

    private struct VerboseResponse: Decodable {
        struct Segment: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
        }

        let text: String?
        /// May be absent for a plain-JSON model, or empty for silence.
        let segments: [Segment]? // swiftlint:disable:this discouraged_optional_collection
    }

    /// Bound for timestamps of audio whose length is unknown: a day, far past
    /// any meeting yet small enough that every later `Int(time)` is safe.
    static let maxUnknownDuration: TimeInterval = 86400

    /// Segments with their times clamped to `duration`, the uploaded audio's
    /// length: Whisper can place a last segment past the end (its 30 s window),
    /// and an unbounded time traps where the transcript turns it into an `Int`.
    /// A negative or backwards segment fails the track.
    static func parseSegments(_ data: Data, model: String, duration: TimeInterval?) throws -> [TimestampedSegment] {
        let decoded: VerboseResponse
        do {
            decoded = try JSONDecoder().decode(VerboseResponse.self, from: data)
        } catch {
            throw CloudTranscriptionError.invalidResponse
        }
        guard let segments = decoded.segments,
              !segments.isEmpty || (decoded.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CloudTranscriptionError.missingSegments(model: model)
        }
        let limit = duration ?? maxUnknownDuration
        return try segments.compactMap { segment in
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start
            else { throw CloudTranscriptionError.invalidTimestamps }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimestampedSegment(start: min(segment.start, limit), end: min(segment.end, limit), text: text)
        }
    }
}
