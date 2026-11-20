import AVFoundation
import Foundation
import Observation
import os.log

/// On-device Russian ASR. Decoding is serialized and runs off the main actor.
@MainActor
@Observable
final class GigaAMEngine: StreamingTranscribingEngine {
    private(set) var modelState: EngineModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    private(set) var transcriptionProgress: Double = 0
    private(set) var loadFailureReason: String?

    struct AudioFileError: LocalizedError {
        let underlying: any Error

        var errorDescription: String? {
            underlying.localizedDescription
        }
    }

    var minimumAudioFrames: Int {
        GigaAMModel.windowSize
    }

    private let directory: URL
    private let modelLoad = SingleFlight<Int>()
    private var model: GigaAMModel?
    private var generation = 0
    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "GigaAMEngine")

    init(directory: URL = GigaAMModelAssets.directory) {
        self.directory = directory
    }

    func loadModel() async {
        try? await loadModel(untilCancelled: false)
    }

    private func loadModel(untilCancelled: Bool) async throws {
        let requested = generation
        let load: @MainActor () async -> Int = { [self] in
            await prepareModel(generation: requested)
            return requested
        }
        while requested == generation, model == nil {
            let attempted = if untilCancelled {
                try await modelLoad.runUnlessCancelled(load)
            } else {
                await modelLoad.run(load)
            }
            // A newer request can join a download-only or superseded flight.
            if attempted == requested { return }
        }
    }

    func downloadModelIfMissing() async {
        guard !GigaAMModelAssets.isInstalled(in: directory) else { return }
        _ = await modelLoad.run { [self] in
            await prepareModel(generation: nil)
            return -1
        }
    }

    func releaseModel() {
        generation += 1
        model = nil
        if modelState == .loaded { modelState = .unloaded }
    }

    private func prepareModel(generation requested: Int?) async {
        guard model == nil else { return }
        loadFailureReason = nil
        defer { modelState = model == nil ? .unloaded : .loaded }
        do {
            if !GigaAMModelAssets.isInstalled(in: directory) {
                modelState = .downloading
                downloadProgress = 0
                try await GigaAMModelAssets.install(in: directory) { [weak self] in
                    await self?.markLoading()
                }
            }
            guard requested == generation else { return }
            markLoading()
            let loaded = try await GigaAMModelAssets.load(from: directory)
            if requested == generation { model = loaded }
        } catch {
            loadFailureReason = error.localizedDescription
            logger.error("GigaAM could not be prepared: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func markLoading() {
        modelState = .loading
        downloadProgress = 1
    }

    private func requireModel() async throws -> GigaAMModel {
        try Task.checkCancellation()
        if let model { return model }
        try await loadModel(untilCancelled: true)
        try Task.checkCancellation()
        guard let model else { throw GigaAMModel.ModelError.notLoaded(loadFailureReason) }
        return model
    }

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        let loaded = try await requireModel()
        transcriptionProgress = 0
        return try await Self.decodeFile(audioPath, with: loaded) { [weak self] progress in
            await self?.reportTranscription(progress)
        }
    }

    private func reportTranscription(_ progress: Double) {
        transcriptionProgress = progress
    }

    func transcribeSamples(_ samples: [Float]) async throws -> String {
        guard samples.count >= minimumAudioFrames else { return "" }
        let loaded = try await requireModel()
        var text: [String] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + GigaAMModel.maxSamples, samples.count)
            let chunk = Array(samples[offset ..< end])
            let length = GigaAMSegmentation.chunkLength(chunk, hasMore: end < samples.count)
            let pieces = try await loaded.decode(Array(chunk.prefix(length)))
            let decoded = GigaAMSegmentation.text(pieces)
            if !decoded.isEmpty { text.append(decoded) }
            offset += length
        }
        return text.joined(separator: " ")
    }

    @concurrent
    private static func decodeFile(
        _ audioPath: URL, with model: GigaAMModel, progress: @Sendable (Double) async -> Void,
    ) async throws -> [TimestampedSegment] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioPath, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioFileError(underlying: error)
        }
        let rate = GigaAMModel.sampleRate
        guard file.processingFormat.sampleRate == Double(rate), file.processingFormat.channelCount == 1 else {
            let normalized = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: normalized) }
            do {
                try await AudioMixer.resampleFile(from: audioPath, to: normalized, targetRate: rate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AudioFileError(underlying: error)
            }
            return try await decodeFile(normalized, with: model, progress: progress)
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(GigaAMModel.maxSamples),
        ) else { throw AudioMixerError.bufferCreationFailed }

        var segments: [TimestampedSegment] = []
        let totalFrames = file.length
        while file.framePosition < totalFrames {
            try Task.checkCancellation()
            let start = file.framePosition
            do {
                try file.read(into: buffer, frameCount: buffer.frameCapacity)
            } catch {
                throw AudioFileError(underlying: error)
            }
            let count = Int(buffer.frameLength)
            guard count > 0, let audio = buffer.floatChannelData?[0] else { break }
            let chunk = Array(UnsafeBufferPointer(start: audio, count: count))
            let length = GigaAMSegmentation.chunkLength(chunk, hasMore: file.framePosition < totalFrames)
            if length < count { file.framePosition = start + Int64(length) }
            let pieces = try await model.decode(Array(chunk.prefix(length)))
            segments += GigaAMSegmentation.segments(pieces, offset: Int(start), length: length)
            await progress(Double(file.framePosition) / Double(totalFrames))
        }
        return segments
    }
}
