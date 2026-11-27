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

    typealias Decode = @Sendable ([Float]) async throws -> [GigaAMModel.Piece]

    private let directory: URL
    private let modelLoad = SingleFlight<Int>()
    private var model: Decode?
    #if DEBUG
        private var modelInstallOverride: (isInstalled: () -> Bool, install: () async throws -> Void)?
        private var modelLoadOverride: (@MainActor () async throws -> Decode)?

        func installModelDownloadForTesting(
            isInstalled: @escaping () -> Bool, install: @escaping () async throws -> Void,
        ) {
            modelInstallOverride = (isInstalled, install)
        }

        func installModelLoadForTesting(_ load: @escaping @MainActor () async throws -> Decode) {
            modelLoadOverride = load
        }
    #endif
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
        guard !isModelInstalled else { return }
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
            if !isModelInstalled {
                markDownloading()
                try await installModel()
            }
            guard requested == generation else { return }
            markLoading()
            let loaded = try await loadDecoder()
            if requested == generation { model = loaded }
        } catch {
            if let requested, requested != generation { return }
            loadFailureReason = error.localizedDescription
            logger.error("GigaAM could not be prepared: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var isModelInstalled: Bool {
        #if DEBUG
            if let modelInstallOverride { return modelInstallOverride.isInstalled() }
            if modelLoadOverride != nil { return true }
        #endif
        return GigaAMModelAssets.isInstalled(in: directory)
    }

    private func installModel() async throws {
        #if DEBUG
            if let modelInstallOverride {
                try await modelInstallOverride.install()
                return
            }
        #endif
        try await GigaAMModelAssets.install(in: directory) { [weak self] in
            await self?.markLoading()
        }
    }

    private func loadDecoder() async throws -> Decode {
        #if DEBUG
            if let modelLoadOverride { return try await modelLoadOverride() }
        #endif
        let model = try await GigaAMModelAssets.load(
            from: directory,
            onRepairing: { [weak self] in await self?.markDownloading() },
            onCompiling: { [weak self] in await self?.markLoading() },
        )
        return { try await model.decode($0) }
    }

    private func markDownloading() {
        modelState = .downloading
        downloadProgress = 0
    }

    private func markLoading() {
        modelState = .loading
        downloadProgress = 1
    }

    private func requireModel() async throws -> Decode {
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
        return try await Self.decodeFile(audioPath, decode: loaded) { [weak self] progress in
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
            let pieces = try await loaded(Array(chunk.prefix(length)))
            let decoded = GigaAMSegmentation.text(pieces)
            if !decoded.isEmpty { text.append(decoded) }
            offset += length
        }
        return text.joined(separator: " ")
    }

    @concurrent
    private static func decodeFile(
        _ audioPath: URL, decode: Decode, mayResample: Bool = true, progress: @Sendable (Double) async -> Void,
    ) async throws -> [TimestampedSegment] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioPath, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioFileError(underlying: error)
        }
        let rate = GigaAMModel.sampleRate
        guard file.processingFormat.sampleRate == Double(rate), file.processingFormat.channelCount == 1 else {
            guard mayResample else { throw AudioMixerError.formatCreationFailed }
            let normalized = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: normalized) }
            try await AudioMixer.resampleFile(from: audioPath, to: normalized, targetRate: rate)
            return try await decodeFile(normalized, decode: decode, mayResample: false, progress: progress)
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(GigaAMModel.maxSamples),
        ) else { throw AudioMixerError.bufferCreationFailed }

        var segments: [TimestampedSegment] = []
        let totalFrames = file.length
        while file.framePosition < totalFrames {
            try Task.checkCancellation()
            let start = file.framePosition
            let count = Int(min(Int64(buffer.frameCapacity), totalFrames - start))
            let chunk = try readWindow(from: file, into: buffer, count: count)
            guard !chunk.isEmpty else { break }
            let length = GigaAMSegmentation.chunkLength(chunk, hasMore: file.framePosition < totalFrames)
            if length < chunk.count { file.framePosition = start + Int64(length) }
            let pieces = try await decode(Array(chunk.prefix(length)))
            segments += GigaAMSegmentation.segments(pieces, offset: Int(start), length: length)
            await progress(Double(file.framePosition) / Double(totalFrames))
        }
        return segments
    }

    // AVAudioFile can return fewer frames than requested before EOF.
    nonisolated private static func readWindow(
        from file: AVAudioFile, into buffer: AVAudioPCMBuffer, count: Int,
    ) throws -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(count)
        while samples.count < count {
            try Task.checkCancellation()
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(count - samples.count))
            } catch {
                throw AudioFileError(underlying: error)
            }
            guard buffer.frameLength > 0, let audio = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: audio, count: Int(buffer.frameLength)))
        }
        return samples
    }
}
