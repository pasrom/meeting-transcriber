@testable import AudioTapLib
import CoreAudio
import Darwin
import XCTest

final class HelpersTests: XCTestCase {
    // MARK: - mach time conversions

    func testMachTicksToSecondsZero() {
        XCTAssertEqual(machTicksToSeconds(0), 0.0)
    }

    func testMachTicksToSecondsPositive() {
        let ticks: UInt64 = 1_000_000_000
        let seconds = machTicksToSeconds(ticks)
        XCTAssertGreaterThan(seconds, 0)
        // On Apple Silicon mach ticks == nanoseconds, so ~1.0s
        // On Intel ratio differs. Just check plausible range.
        XCTAssertGreaterThan(seconds, 0.01)
        XCTAssertLessThan(seconds, 100)
    }

    func testMachTicksToSecondsMonotonic() {
        let s1 = machTicksToSeconds(1000)
        let s2 = machTicksToSeconds(2000)
        XCTAssertGreaterThan(s2, s1)
    }

    func testSecondsToMachTicksZero() {
        XCTAssertEqual(secondsToMachTicks(0), 0)
    }

    func testSecondsToMachTicksRoundTrip() {
        for seconds in [0.001, 0.5, 1.0, 1.5, 60.0] {
            let ticks = secondsToMachTicks(seconds)
            let back = machTicksToSeconds(ticks)
            // Integer ticks → tiny rounding; 1µs tolerance is comfortable.
            XCTAssertEqual(back, seconds, accuracy: 1e-6, "round-trip drift at \(seconds)s")
        }
    }

    func testSecondsToMachTicksIsMonotonic() {
        XCTAssertLessThan(secondsToMachTicks(0.1), secondsToMachTicks(0.2))
    }

    func testSpeechSampleRateConstant() {
        XCTAssertEqual(speechSampleRate, 16000)
    }

    // MARK: - writeAllToFileHandle

    func testWriteAllToFileHandleWritesAllBytes() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { XCTFail("pipe() failed: \(errno)"); return }
        defer {
            close(fds[0])
            close(fds[1])
        }
        let payload = "Hello, world! \u{1F4DD}"
        let bytes = Array(payload.utf8)
        try bytes.withUnsafeBufferPointer { buf in
            let base = try XCTUnwrap(buf.baseAddress)
            writeAllToFileHandle(fds[1], UnsafeRawPointer(base), count: buf.count)
        }
        var readBuf = [UInt8](repeating: 0, count: bytes.count)
        let n = read(fds[0], &readBuf, readBuf.count)
        XCTAssertEqual(n, bytes.count)
        XCTAssertEqual(readBuf, bytes)
    }

    func testWriteAllToFileHandleZeroCountIsNoop() {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { XCTFail("pipe() failed: \(errno)"); return }
        defer {
            close(fds[0])
            close(fds[1])
        }
        // Set read end non-blocking so we can confirm "no data" via EAGAIN.
        let flags = fcntl(fds[0], F_GETFL)
        XCTAssertNotEqual(flags, -1)
        XCTAssertEqual(fcntl(fds[0], F_SETFL, flags | O_NONBLOCK), 0)

        var dummy: UInt8 = 0
        withUnsafePointer(to: &dummy) { ptr in
            writeAllToFileHandle(fds[1], UnsafeRawPointer(ptr), count: 0)
        }

        var byte: UInt8 = 0
        let n = read(fds[0], &byte, 1)
        XCTAssertEqual(n, -1)
        XCTAssertEqual(errno, EAGAIN)
    }

    func testWriteAllToFileHandleBrokenPipeDoesNotHang() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { XCTFail("pipe() failed: \(errno)"); return }
        // Per-fd SIGPIPE suppression — `signal(SIGPIPE, SIG_IGN)` would be
        // process-global and race with concurrent xctest classes under
        // `swift test --parallel`. F_SETNOSIGPIPE turns the EPIPE into a
        // returned -1 only for this fd.
        XCTAssertEqual(fcntl(fds[1], F_SETNOSIGPIPE, 1), 0)
        // Close the read end so writes get EPIPE; the loop's `written < 0`
        // branch must `break` rather than spin.
        close(fds[0])
        defer { close(fds[1]) }

        let bytes: [UInt8] = Array(repeating: 0x41, count: 16)
        try bytes.withUnsafeBufferPointer { buf in
            let base = try XCTUnwrap(buf.baseAddress)
            writeAllToFileHandle(fds[1], UnsafeRawPointer(base), count: buf.count)
        }
        // Reaching this line without hanging is the assertion — the loop's
        // `break` branch fires when write() returns -1 with errno != EINTR.
    }

    // MARK: - getExecutableName

    func testGetExecutableNameForCurrentProcessReturnsRealName() {
        let name = getExecutableName(pid: getpid())
        XCTAssertNotEqual(name, "?")
        XCTAssertFalse(name.isEmpty)
    }

    func testGetExecutableNameForUnknownPIDReturnsQuestionMark() {
        // Pick a PID well above any plausibly running process.
        let name = getExecutableName(pid: 999_999)
        XCTAssertEqual(name, "?")
    }

    // MARK: - CoreAudio default-device queries (tolerant smoke tests)

    //
    // Each test exercises the property-read code path. On CI runners the
    // device set varies (BlackHole-only, headless, etc.), so we tolerate
    // nil but verify shape when a value is returned. Together they cover
    // the resolveDefaultDevice + readCFStringAudioProperty branches.

    func testGetDefaultOutputDeviceUIDShape() {
        if let uid = getDefaultOutputDeviceUID() {
            XCTAssertFalse(uid.isEmpty)
        }
    }

    func testGetDefaultOutputDeviceNameShape() {
        if let name = getDefaultOutputDeviceName() {
            XCTAssertFalse(name.isEmpty)
        }
    }

    func testGetDefaultOutputDeviceSampleRateShape() {
        if let rate = getDefaultOutputDeviceSampleRate() {
            XCTAssertGreaterThan(rate, 0)
            // Anything from 8 kHz (telephony) up to 768 kHz (pro audio) is plausible.
            XCTAssertGreaterThanOrEqual(rate, 8000)
            XCTAssertLessThanOrEqual(rate, 768_000)
        }
    }

    func testGetDefaultOutputDeviceTransportTypeShape() {
        if let transport = getDefaultOutputDeviceTransportType() {
            XCTAssertFalse(transport.isEmpty)
        }
    }

    func testGetDefaultInputDeviceUIDShape() {
        if let uid = getDefaultInputDeviceUID() {
            XCTAssertFalse(uid.isEmpty)
        }
    }

    func testGetDefaultInputDeviceNameShape() {
        if let name = getDefaultInputDeviceName() {
            XCTAssertFalse(name.isEmpty)
        }
    }

    // MARK: - readCFStringAudioProperty / getProcessBundleID

    func testReadCFStringAudioPropertyReturnsNilForUnsupportedProperty() {
        // The system object doesn't expose kAudioObjectPropertyName, so the
        // status-not-noErr branch returns nil.
        let result = readCFStringAudioProperty(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioObjectPropertyName,
        )
        XCTAssertNil(result)
    }

    func testGetProcessBundleIDReturnsNilForUnknownObject() {
        // An out-of-range AudioObjectID should not have a bundle ID.
        let result = getProcessBundleID(AudioObjectID.max)
        XCTAssertNil(result)
    }
}
