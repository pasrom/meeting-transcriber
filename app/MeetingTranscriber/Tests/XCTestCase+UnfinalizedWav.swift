import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// What a recording whose writer was killed mid-stream leaves on disk, built
/// from a real WAV the app itself wrote rather than from hand-assembled bytes.
///
/// The shape matters: `WavHeaderRepair` reads what `AVAudioFile` produces,
/// including its JUNK chunk, so a fixture that invents its own chunk layout
/// pins the repair against a file the app never writes.
extension XCTestCase {
    /// A valid 16 kHz mono WAV, then its `data` size zeroed the way a killed
    /// writer leaves it, then aged past the in-progress guard.
    @discardableResult
    func writeUnfinalizedWav(at url: URL, seconds: Double = 0.1) throws -> URL {
        let samples = [Float](repeating: 0.05, count: Int(16000 * seconds))
        try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: url)
        try zeroDataChunkSize(at: url)
        try backdate([url])
        return url
    }

    /// Zero the `data` size the way a writer killed mid-stream does.
    func zeroDataChunkSize(at url: URL) throws {
        var data = try Data(contentsOf: url)
        let marker = try XCTUnwrap(data.range(of: Data("data".utf8)), "no data chunk")
        data.replaceSubrange(marker.upperBound ..< marker.upperBound + 4, with: [0, 0, 0, 0])
        data.replaceSubrange(4 ..< 8, with: [4, 0, 0, 0])
        try data.write(to: url)
    }

    /// Age every file past the in-progress guard, the way a crash does.
    func backdate(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path,
            )
        }
    }

    /// The `data` chunk size a repair is expected to have written back.
    func dataChunkSize(at url: URL) throws -> UInt32 {
        let data = try Data(contentsOf: url)
        let marker = try XCTUnwrap(data.range(of: Data("data".utf8)), "no data chunk")
        return data.subdata(in: marker.upperBound ..< marker.upperBound + 4)
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }
}
