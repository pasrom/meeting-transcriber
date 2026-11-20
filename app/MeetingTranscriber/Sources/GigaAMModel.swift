import Accelerate
import CoreML
import Foundation

/// The input and output contract of the pinned GigaAM v3 E2E-CTC Core ML conversion.
actor GigaAMModel {
    nonisolated static let sampleRate = 16000
    nonisolated static let windowSize = 320
    nonisolated static let hopSize = 160
    nonisolated static let maxSamples = 25 * sampleRate
    nonisolated static let secondsPerToken = Double(4 * hopSize) / Double(sampleRate)

    private static let melCount = 64
    private static let spectrumSize = windowSize / 2 + 1
    private static let maxFrames = (maxSamples - windowSize) / hopSize + 1
    private static let blank = 256

    private let model: MLModel
    private let melBank: [Float]
    private let window: [Float]
    private let vocabulary: [String]

    struct Piece: Sendable, Equatable {
        let text: String
        let firstFrame: Int
        var endFrame: Int
    }

    enum ModelError: LocalizedError {
        case invalidAsset(String)
        case invalidOutput
        case notLoaded(String?)

        var errorDescription: String? {
            switch self {
            case let .invalidAsset(name): "Invalid GigaAM model asset: \(name)"
            case .invalidOutput: "Unexpected GigaAM model output."
            case let .notLoaded(reason): reason ?? "GigaAM model is not loaded."
            }
        }
    }

    init(compiledURL: URL, assets: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: compiledURL, configuration: config)
        let rawMel = try Self.floats("gigaam-melfb.f32", count: Self.melCount * Self.spectrumSize, in: assets)
        // The checkpoint serializes the torchaudio bank as [bin, mel].
        var transposed = [Float](repeating: 0, count: rawMel.count)
        vDSP_mtrans(rawMel, 1, &transposed, 1, vDSP_Length(Self.melCount), vDSP_Length(Self.spectrumSize))
        melBank = transposed
        window = try Self.floats("gigaam-window.f32", count: Self.windowSize, in: assets)
        let words = try String(contentsOf: assets.appendingPathComponent("gigaam-vocab.txt"), encoding: .utf8)
        vocabulary = words.split(whereSeparator: \.isNewline).map(String.init)
        guard vocabulary.count == Self.blank else { throw ModelError.invalidAsset("gigaam-vocab.txt") }
    }

    private static func floats(_ name: String, count: Int, in directory: URL) throws -> [Float] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        guard data.count == count * MemoryLayout<UInt32>.size else { throw ModelError.invalidAsset(name) }
        return data.withUnsafeBytes { bytes in
            (0 ..< count).map { index in
                let bits = bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<UInt32>.size, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }

    func decode(_ samples: [Float]) throws -> [Piece] {
        try Task.checkCancellation()
        guard samples.count >= Self.windowSize, samples.count <= Self.maxSamples else { return [] }
        let frameCount = (samples.count - Self.windowSize) / Self.hopSize + 1
        let features = try melFeatures(samples, frameCount: frameCount)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        // swiftlint:disable:next legacy_objc_type
        length[0] = NSNumber(value: frameCount)

        let input = try MLDictionaryFeatureProvider(dictionary: ["features": features, "feature_lengths": length])
        let output = try model.prediction(from: input)
        try Task.checkCancellation()
        guard let logits = output.featureValue(for: "log_softmax")?.multiArrayValue,
              let encodedLength = output.featureValue(for: "_to_copy_6")?.multiArrayValue,
              logits.shape.count == 3, logits.shape[2].intValue == Self.blank + 1
        else { throw ModelError.invalidOutput }

        let validFrames = min(encodedLength[0].intValue, logits.shape[1].intValue)
        guard validFrames > 0 else { return [] }
        let tokens: [Int]
        switch logits.dataType {
        case .float16:
            tokens = Self.argmax(logits, frames: validFrames, as: Float16.self)

        case .float32:
            tokens = Self.argmax(logits, frames: validFrames, as: Float.self)

        default:
            throw ModelError.invalidOutput
        }
        return Self.collapse(tokens, vocabulary: vocabulary)
    }

    private static func argmax<Scalar: FloatingPoint>(
        _ logits: MLMultiArray, frames: Int, as _: Scalar.Type,
    ) -> [Int] {
        let rowStride = logits.strides[1].intValue
        let tokenStride = logits.strides[2].intValue
        let scores = logits.dataPointer.assumingMemoryBound(to: Scalar.self)
        return (0 ..< frames).map { frame in
            let row = scores + frame * rowStride
            var best = 0
            for token in 1 ... Self.blank where row[token * tokenStride] > row[best * tokenStride] {
                best = token
            }
            return best
        }
    }

    nonisolated static func collapse(_ tokens: [Int], vocabulary: [String]) -> [Piece] {
        var pieces: [Piece] = []
        var previous: Int?
        for (frame, token) in tokens.enumerated() {
            if token == previous, vocabulary.indices.contains(token), token != 0 {
                pieces[pieces.count - 1].endFrame = frame + 1
                continue
            }
            previous = token
            guard vocabulary.indices.contains(token), token != 0 else { continue }
            pieces.append(Piece(text: vocabulary[token], firstFrame: frame, endFrame: frame + 1))
        }
        return pieces
    }

    private func melFeatures(_ samples: [Float], frameCount: Int) throws -> MLMultiArray {
        // swiftlint:disable:next legacy_objc_type
        let shape = [1, NSNumber(value: Self.melCount), NSNumber(value: Self.maxFrames)]
        let features = try MLMultiArray(shape: shape, dataType: .float32)
        let output = features.dataPointer.assumingMemoryBound(to: Float.self)
        output.initialize(repeating: 0, count: features.count)
        let powers = try Self.powerSpectrum(samples, window: window, frameCount: frameCount)
        // [mel, bin] × [bin, frame] → [mel, frame].
        var mel = [Float](repeating: 0, count: Self.melCount * frameCount)
        vDSP_mmul(
            melBank, 1, powers, 1, &mel, 1,
            vDSP_Length(Self.melCount), vDSP_Length(frameCount), vDSP_Length(Self.spectrumSize),
        )
        for band in 0 ..< Self.melCount {
            let row = output + band * Self.maxFrames
            for frame in 0 ..< frameCount {
                row[frame] = logf(min(max(mel[band * frameCount + frame], 1e-9), 1e9))
            }
        }
        return features
    }

    private static func powerSpectrum(_ samples: [Float], window: [Float], frameCount: Int) throws -> [Float] {
        guard let transform = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(windowSize), .FORWARD) else {
            throw ModelError.invalidAsset("320-point DFT")
        }
        defer { vDSP_DFT_DestroySetup(transform) }
        var powers = [Float](repeating: 0, count: frameCount * Self.spectrumSize)
        var frame = [Float](repeating: 0, count: Self.windowSize)
        let zeros = frame
        var real = frame
        var imaginary = frame
        samples.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            for index in 0 ..< frameCount {
                vDSP_vmul(base + index * Self.hopSize, 1, window, 1, &frame, 1, vDSP_Length(Self.windowSize))
                vDSP_DFT_Execute(transform, frame, zeros, &real, &imaginary)
                for bin in 0 ..< Self.spectrumSize {
                    powers[bin * frameCount + index] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                }
            }
        }
        return powers
    }
}
