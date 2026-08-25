// Pure-logic tests for EchoFrameChunking: the hop arithmetic that slices a
// signal into fixed-size frames for the LocalVQE streaming API, including the
// zero-padded trailing partial hop. No model, no C library — runs everywhere.
@testable import MeetingTranscriber
import XCTest

final class EchoFrameChunkingTests: XCTestCase {
    // MARK: - Hop count

    func testEmptySignalHasNoHops() {
        let chunking = EchoFrameChunking(totalSamples: 0, hopLength: 256)
        XCTAssertEqual(chunking.hopCount, 0)
    }

    func testExactMultipleSplitsIntoFullHops() {
        let chunking = EchoFrameChunking(totalSamples: 1024, hopLength: 256)
        XCTAssertEqual(chunking.hopCount, 4)
        for index in 0 ..< 4 {
            XCTAssertEqual(chunking.hop(index).start, index * 256)
            XCTAssertEqual(chunking.hop(index).validSamples, 256)
        }
    }

    func testRemainderAddsOnePartialTrailingHop() {
        let chunking = EchoFrameChunking(totalSamples: 1000, hopLength: 256)
        XCTAssertEqual(chunking.hopCount, 4)
        XCTAssertEqual(chunking.hop(3).start, 768)
        XCTAssertEqual(chunking.hop(3).validSamples, 1000 - 768)
    }

    func testSignalShorterThanOneHopIsASinglePartialHop() {
        let chunking = EchoFrameChunking(totalSamples: 100, hopLength: 256)
        XCTAssertEqual(chunking.hopCount, 1)
        XCTAssertEqual(chunking.hop(0).start, 0)
        XCTAssertEqual(chunking.hop(0).validSamples, 100)
    }

    func testSingleSampleIsAPartialHop() {
        let chunking = EchoFrameChunking(totalSamples: 1, hopLength: 256)
        XCTAssertEqual(chunking.hopCount, 1)
        XCTAssertEqual(chunking.hop(0).validSamples, 1)
    }

    func testOneSampleOverAMultipleYieldsPartialTrailingHop() {
        let chunking = EchoFrameChunking(totalSamples: 257, hopLength: 256)
        XCTAssertEqual(chunking.hopCount, 2)
        XCTAssertEqual(chunking.hop(1).start, 256)
        XCTAssertEqual(chunking.hop(1).validSamples, 1)
    }

    // MARK: - Hop buffer filling

    func testFillHopCopiesFullWindow() {
        let signal: [Float] = (0 ..< 8).map(Float.init)
        var buffer = [Float](repeating: -1, count: 4)
        EchoFrameChunking.fillHop(from: signal, start: 4, into: &buffer)
        XCTAssertEqual(buffer, [4, 5, 6, 7])
    }

    func testFillHopZeroPadsPastEndOfSignal() {
        let signal: [Float] = [1, 2, 3]
        var buffer = [Float](repeating: -1, count: 4)
        EchoFrameChunking.fillHop(from: signal, start: 2, into: &buffer)
        XCTAssertEqual(buffer, [3, 0, 0, 0])
    }

    func testFillHopEntirelyPastEndIsAllZeros() {
        // The reference track may be shorter than the mic track; hops beyond
        // its end must read as silence, not stale buffer contents.
        let signal: [Float] = [1, 2]
        var buffer = [Float](repeating: -1, count: 4)
        EchoFrameChunking.fillHop(from: signal, start: 8, into: &buffer)
        XCTAssertEqual(buffer, [0, 0, 0, 0])
    }

    func testFillHopFromEmptySignalIsAllZeros() {
        var buffer = [Float](repeating: -1, count: 4)
        EchoFrameChunking.fillHop(from: [], start: 0, into: &buffer)
        XCTAssertEqual(buffer, [0, 0, 0, 0])
    }
}
