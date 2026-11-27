import AVFoundation
import Foundation

/// Cuts a long recording into WAV pieces for cloud transcription, whose
/// providers cap an upload at 25 MB. Each cut lands at the quietest short
/// frame in a search window before the piece boundary, so a word is not split;
/// with no quiet frame there it falls on the boundary itself.
enum CloudAudioSplitter {
    /// Ten minutes of 16 kHz 16-bit mono is about 19 MB.
    static let defaultPieceDuration: TimeInterval = 600
    static let defaultSearchWindow: TimeInterval = 60
    /// Long enough that a dip inside a word does not qualify as a pause.
    static let frameDuration: TimeInterval = 0.2
    /// A frame at or below this RMS counts as a pause.
    static let quietThresholdDB: Float = -40

    /// Sample offset into `window` at the centre of its quietest frame, or nil
    /// when no frame is quiet. Ties go to the later frame, keeping pieces long.
    static func quietCut(in window: [Float], sampleRate: Double) -> Int? {
        let frameLength = max(1, Int(frameDuration * sampleRate))
        var best: (offset: Int, level: Float)?
        var start = 0
        while start + frameLength <= window.count {
            let level = AudioMixer.rmsDecibels(samples: window[start ..< start + frameLength])
            if level <= quietThresholdDB, level <= best?.level ?? .infinity {
                best = (start + frameLength / 2, level)
            }
            start += frameLength
        }
        return best?.offset
    }

    /// Frame ranges covering `totalFrames`, each at most `pieceFrames` long.
    /// `readWindow` returns the samples of the given range, so only the search
    /// windows are ever in memory.
    static func planPieces(
        totalFrames: Int,
        pieceFrames: Int,
        windowFrames: Int,
        sampleRate: Double,
        readWindow: (Range<Int>) throws -> [Float],
    ) rethrows -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = 0
        while totalFrames - start > pieceFrames {
            let boundary = start + pieceFrames
            let windowStart = max(start + 1, boundary - windowFrames)
            let window = try readWindow(windowStart ..< boundary)
            let cut = quietCut(in: window, sampleRate: sampleRate).map { windowStart + $0 } ?? boundary
            pieces.append(start ..< cut)
            start = cut
        }
        pieces.append(start ..< totalFrames)
        return pieces
    }
}
