@testable import AudioTapLib
import CoreAudio
import Darwin
import XCTest

/// Issue #673: the capture rate is measured once, on the first IOProc callback,
/// and re-measured only when a restart happens, which only a default-output
/// device change triggers. A device that renegotiates its rate *in place* keeps
/// its UID, so no listener fires and `actualSampleRate` stays stale for the rest
/// of the session.
///
/// These drive `writeCapturedBuffer`, the production write path, because that is
/// where the stale field is read. `resampleForwardAndWrite` one frame down takes
/// the rate as a parameter and therefore cannot exhibit the bug at all.
///
/// The two directions produce different artefacts, so they need different
/// assertions. Dropping (48 published, 24 delivered) keeps the track's
/// real-time length, because `TimelineAnchor` pads the frames the stale
/// converter did not produce: the damage is an alternating pattern of real
/// audio and exact zeros. Rising (24 published, 48 delivered) makes the track
/// too long, because the anchor pads but never removes. Hence: zeros for the
/// drop, length for the rise.
@available(macOS 14.2, *)
final class AppAudioCaptureRateChangeTests: XCTestCase {
    /// Frames per IOProc callback. Every log in the repo shows the HAL keeping
    /// the buffer frame size across a nominal-rate change, so a rate change
    /// shows up as a change in *callback period*, not in frames per callback.
    private static let framesPerBuffer = 480

    // MARK: - The bug

    /// 48 kHz published, 24 kHz delivered. Each callback carries half the frames
    /// the stale converter is asked for, so the anchor pads the rest: roughly
    /// half the track is exact zeros while its length still looks right.
    func testInPlaceRateDropIsAdoptedAndStopsTheZeroSlivers() throws {
        let capture = makeCapture()
        publish(rate: 48000, on: capture)
        let file = try TempFile()
        defer { file.close() }

        let t0 = mach_absolute_time()
        // 1 s at the published rate: 480 frames every 10 ms is 48 kHz.
        feed(capture, fd: file.fd, buffers: 100, periodSeconds: 0.01, startTicks: t0)
        // The device drops to 24 kHz in place. Same buffers, half as often.
        // Nothing in the system announces it; only the delivered frames do.
        feed(
            capture, fd: file.fd, buffers: 200, periodSeconds: 0.02,
            startTicks: t0 &+ secondsToMachTicks(1.0),
        )

        XCTAssertEqual(
            capture.actualSampleRate, 24000,
            "the delivered rate halved in place; the published rate must follow it",
        )

        let written = file.readFloats()
        // Sanity, true in both states: the anchor keeps the track's real-time
        // length either way, which is exactly why length cannot be the
        // discriminator in this direction.
        XCTAssertEqual(
            Double(written.count), 80000, accuracy: 1600,
            "about 5 s of 16 kHz mono regardless of the defect",
        )
        let tail = written.suffix(32000)
        let zeroFraction = Double(tail.filter { $0 == 0 }.count) / Double(tail.count)
        XCTAssertLessThan(
            zeroFraction, 0.05,
            "the last 2 s must be audio, not the alternating real/zero sliver pattern",
        )
    }

    /// 24 kHz published, 48 kHz delivered. Each callback carries twice the frames
    /// the stale converter expects, and the anchor never removes frames, so the
    /// track comes out about twice as long and an octave low.
    func testInPlaceRateRiseIsAdoptedAndStopsTheDoubling() throws {
        let capture = makeCapture()
        publish(rate: 24000, on: capture)
        let file = try TempFile()
        defer { file.close() }

        let t0 = mach_absolute_time()
        // 1 s at the published rate: 480 frames every 20 ms is 24 kHz.
        feed(capture, fd: file.fd, buffers: 50, periodSeconds: 0.02, startTicks: t0)
        // The last mic client closed and the device went back to 48 kHz.
        feed(
            capture, fd: file.fd, buffers: 400, periodSeconds: 0.01,
            startTicks: t0 &+ secondsToMachTicks(1.0),
        )

        XCTAssertEqual(
            capture.actualSampleRate, 48000,
            "the delivered rate doubled in place; the published rate must follow it",
        )

        // 5 s of wall clock is 80000 frames at 16 kHz. Whatever is written
        // before the change is noticed is over-long and is never taken back, so
        // the bound allows for the detection latency but not for the defect,
        // which writes about 144000.
        let written = file.readFloats()
        XCTAssertLessThan(
            written.count, 120_000,
            "about 5 s of wall clock must not produce a 9 s track",
        )
        XCTAssertGreaterThan(
            written.count, 80000 - 1600,
            "and nothing may be dropped either",
        )
    }

    // MARK: - Control

    /// The case that must not change: a steady rate stays published, and the
    /// measurement never churns the converter on clock jitter. Green before and
    /// after the fix. Without it, the two tests above could pass by adopting
    /// any rate at all.
    func testSteadyRateIsLeftAloneAndProducesNoSlivers() throws {
        let capture = makeCapture()
        publish(rate: 48000, on: capture)
        let file = try TempFile()
        defer { file.close() }

        feed(
            capture, fd: file.fd, buffers: 300, periodSeconds: 0.01,
            startTicks: mach_absolute_time(),
        )

        XCTAssertEqual(capture.actualSampleRate, 48000, "a steady rate must not be re-published")
        let written = file.readFloats()
        XCTAssertEqual(
            Double(written.count), 48000, accuracy: 800,
            "3 s of wall clock is 3 s of 16 kHz mono",
        )
        let zeroFraction = Double(written.filter { $0 == 0 }.count) / Double(written.count)
        XCTAssertLessThan(zeroFraction, 0.01, "a steady rate must not pad anything")
    }

    // MARK: - Fixture

    private func makeCapture() -> AppAudioCapture {
        // `channels` is the requested count; `actualChannels` stays 0 until a
        // real first callback, and `writeCapturedBuffer` reads
        // `max(actualChannels, 1)`, so the fed buffers are interpreted as mono.
        // The capture's own descriptor is never written: every write in these
        // tests goes to the fd handed to `writeCapturedBuffer`.
        AppAudioCapture(
            pids: [], outputFileDescriptor: -1,
            sampleRate: 48000, channels: 1, debugLogging: false, liveSink: nil,
        )
    }

    /// Publish a rate the way production does: through the restart adoption,
    /// which is the only writer besides the first-callback correction. Building
    /// the session on a no-op HAL keeps this off any audio hardware.
    private func publish(rate: Int, on capture: AppAudioCapture) {
        let noop = AppTapSessionHAL(
            stopDevice: { _, _ in }, destroyIOProc: { _, _ in },
            destroyAggregate: { _ in }, destroyTap: { _ in },
        )
        let session = AppTapSession(tapID: 1, hal: noop) {}
        session.attach(aggregateID: 101, resolvedSampleRate: rate)
        capture.install(session)
        XCTAssertEqual(capture.actualSampleRate, rate, "preconditional: the rate was published")
    }

    /// Feed `buffers` callbacks of `framesPerBuffer` mono frames, spaced
    /// `periodSeconds` apart in presentation time. The stamps are computed from
    /// the index rather than accumulated so the span is exact.
    private func feed(
        _ capture: AppAudioCapture,
        fd: Int32,
        buffers: Int,
        periodSeconds: Double,
        startTicks: UInt64,
    ) {
        var samples = [Float](repeating: 0.5, count: Self.framesPerBuffer)
        let byteCount = Self.framesPerBuffer * MemoryLayout<Float>.size
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for index in 0 ..< buffers {
                capture.writeCapturedBuffer(
                    fd: fd,
                    data: UnsafeMutableRawPointer(base),
                    byteCount: byteCount,
                    hostTicks: startTicks &+ secondsToMachTicks(Double(index) * periodSeconds),
                )
            }
        }
    }

    /// A real file, because the assertions are about what reached the fd.
    private struct TempFile {
        let fd: Int32
        let path: String

        init() throws {
            path = NSTemporaryDirectory() + "ratechange_\(UUID().uuidString).f32"
            fd = open(path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else {
                throw NSError(domain: "AppAudioCaptureRateChangeTests", code: 1)
            }
        }

        func readFloats() -> [Float] {
            let byteCount = Int(lseek(fd, 0, SEEK_END))
            guard byteCount > 0 else { return [] }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            lseek(fd, 0, SEEK_SET)
            let got = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, byteCount) }
            guard got > 0 else { return [] }
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(got / 4)) }
        }

        func close() {
            Darwin.close(fd)
            unlink(path)
        }
    }
}
