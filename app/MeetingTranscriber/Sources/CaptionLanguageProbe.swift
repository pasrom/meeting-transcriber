import AudioTapLib
import Foundation

/// A bounded recording-level decision, independent of caption text or ASR finals.
struct CaptionLanguageProbeDecision {
    enum Outcome: Equatable {
        case englishStreaming
        case reTranscribe
    }

    /// Not swept: the decisions observed live were 0.987 to 0.9999.
    static let minimumProbability: Float = 0.8
    /// One English window can be a greeting or a clip in another-language meeting.
    static let englishWindowsRequired = 2
    static let maxAttempts = 4

    private(set) var attempts = 0
    private var englishStreak = 0
    private var decided = false

    mutating func resolve(_ result: CaptionLanguageDetection?) -> Outcome? {
        guard !decided else { return nil }
        attempts += 1
        // Require a clear winner before choosing an English-only model. This is
        // a conservative routing threshold, not a calibrated accuracy guarantee.
        if let result, result.probability >= Self.minimumProbability {
            guard result.language.lowercased() == "en" else {
                decided = true
                return .reTranscribe
            }
            englishStreak += 1
            if englishStreak >= Self.englishWindowsRequired {
                decided = true
                return .englishStreaming
            }
        } else {
            englishStreak = 0
        }
        if result == nil || attempts >= Self.maxAttempts {
            decided = true
            return .reTranscribe
        }
        return nil
    }
}

/// Collects only VAD-active audio, in four-second windows. The two channel
/// consumers race to submit the first window; the controller owns the winner.
actor CaptionLanguageProbe: LiveCaptionPipeline {
    typealias SpeechDetector = @Sendable ([Float]) async throws -> [Float]
    /// An empty candidate reports a VAD failure and selects the fallback.
    typealias CandidateSink = @Sendable ([Float], Int) async -> Bool
    typealias AttemptProvider = @Sendable () async -> Int?

    private let detector: any UtteranceBoundaryDetecting
    private let speechDetector: SpeechDetector?
    private let onCandidate: CandidateSink
    private let attempt: AttemptProvider
    private var collectingAttempt: Int?
    private var pending: [Float] = []
    private var speech: [Float] = []
    private var speaking = false
    private var finished = false

    init(
        vad: FluidVAD,
        speechDetector: SpeechDetector?,
        attempt: @escaping AttemptProvider,
        onCandidate: @escaping CandidateSink,
    ) {
        detector = FluidVADBoundaryDetector(vad: vad)
        self.speechDetector = speechDetector
        self.onCandidate = onCandidate
        self.attempt = attempt
    }

    func ingest(_ buffer: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) async {
        guard !finished, buffer.sampleRate == 16000, buffer.channelCount == 1 else { return }
        pending.append(contentsOf: buffer.samples)
        while pending.count >= 4096, !finished, !Task.isCancelled {
            // While another channel is detecting, retain audio only in the
            // recording feed. Each retry collects fresh speech on either channel.
            guard let currentAttempt = await attempt() else {
                await reset()
                return
            }
            if collectingAttempt != currentAttempt {
                speech = []
                collectingAttempt = currentAttempt
            }
            let chunk = Array(pending.prefix(4096))
            pending.removeFirst(4096)
            do {
                if let speechDetector {
                    try await speech.append(contentsOf: speechDetector(chunk))
                } else {
                    switch try await detector.boundary(in: chunk) {
                    case .speechStart: speaking = true
                    case .speechEnd: speaking = false
                    case nil: break
                    }
                    if speaking { speech.append(contentsOf: chunk) }
                }
                if speech.count >= 64000 {
                    let candidate = Array(speech.prefix(64000))
                    speech.removeFirst(64000)
                    finished = await !onCandidate(candidate, currentAttempt)
                }
            } catch {
                if !Task.isCancelled { _ = await onCandidate([], currentAttempt) }
                finished = true
            }
        }
        if finished { pending = []; speech = [] }
    }

    func reset() async {
        pending = []
        speech = []
        speaking = false
        await detector.reset()
    }

    func flush() {}
}
