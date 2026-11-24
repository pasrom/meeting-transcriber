import AudioTapLib
import Darwin
@testable import MeetingTranscriber
import XCTest

/// How much memory the end of a dual-source recording holds at its peak,
/// counted in full-length tracks (about 230 MB per recorded hour each at
/// 16 kHz Float32). `buildRecording` kept the microphone track it had loaded
/// and the app track it had written alive through the mix, while the mixer
/// loaded both again from disk and kept them next to the mix and the write
/// buffer: six tracks at once, measured with this test on a ten-minute and a
/// three-minute recording. Now the peak is the mixer loading the second track
/// next to the first, three. Six minutes here, for a half track of headroom
/// below the limit (about 11 MB) against stray allocations by other work in
/// the same test process; how much those come to is not measured.
final class BuildRecordingPeakMemoryTests: XCTestCase {
    /// Samples the bytes the process has allocated, on a thread of its own
    /// until stopped, and keeps the highest value seen. Allocated bytes, not
    /// the footprint: freed pages the allocator keeps for reuse still count
    /// in the footprint, so a test that ran earlier in the same process
    /// would raise the baseline and hide part of the peak.
    private final class AllocationSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var peak: UInt64 = 0
        private let done = DispatchSemaphore(value: 0)

        func start() {
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let now = Self.bytesInUse()
                    lock.withLock { peak = max(peak, now) }
                    usleep(500)
                }
                done.signal()
            }
        }

        func stop() -> UInt64 {
            lock.withLock { running = false }
            done.wait()
            return lock.withLock { peak }
        }

        static func bytesInUse() -> UInt64 {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return UInt64(stats.size_in_use)
        }
    }

    /// A sanitizer replaces the allocator, and its counts mean something
    /// else: ASan keeps freed blocks in a quarantine that still reads as in
    /// use (38 tracks measured in CI for this mix), so the number says
    /// nothing about what the mix holds. TSan replaces it too; its counts
    /// were not measured.
    private static let sanitizerRuntimeLoaded: Bool = {
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        return dlsym(handle, "__asan_init") != nil || dlsym(handle, "__tsan_init") != nil
    }()

    func testTheDualTrackMixHoldsAtMostThreeTracksAtOnce() throws {
        try XCTSkipIf(Self.sanitizerRuntimeLoaded, "allocation counts are not comparable under a sanitizer")
        let dir = try makeTempDirectory(prefix: "build_peak")
        let rate = 16000
        let seconds = 6 * 60
        let trackBytes = Double(seconds * rate * MemoryLayout<Float>.size)
        let stem = "20260311_140000"
        let appTmp = dir.appendingPathComponent("\(stem)\(RecordingFileSuffix.appRaw)")
        let micWav = dir.appendingPathComponent("\(stem)\(RecordingFileSuffix.mic)")
        // In a scope of its own, so the fixture track is freed before the
        // baseline is read.
        do {
            let track = EchoTestAudio.gatedBursts(seconds: seconds, rate: rate, channels: 1, seed: 9)
            try writeRawFloat32(track, to: appTmp)
            try AudioMixer.saveWAV(samples: track, sampleRate: rate, url: micWav)
        }

        let baseline = AllocationSampler.bytesInUse()
        let sampler = AllocationSampler()
        sampler.start()
        // A positive delay, so the mixer's alignment step runs too.
        _ = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: rate, actualChannels: 1, micDelay: 0.5,
            ),
            recordingsDir: dir, timestamp: stem,
            recordingStartDate: Date(timeIntervalSince1970: 1000),
            format: CaptureFormat(requestedChannels: 1, requestedRate: rate, targetRate: rate),
        )
        let peak = sampler.stop()

        let tracksAtPeak = Double(Int64(peak) - Int64(baseline)) / trackBytes
        XCTAssertLessThanOrEqual(
            tracksAtPeak, 3.5,
            "the end of the recording held \(String(format: "%.2f", tracksAtPeak)) full-length tracks at once",
        )
    }
}
