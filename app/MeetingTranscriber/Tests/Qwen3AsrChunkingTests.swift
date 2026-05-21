@testable import MeetingTranscriber
import XCTest

final class Qwen3AsrChunkingTests: XCTestCase {
    func testChunkRangesZeroTotalReturnsEmpty() {
        XCTAssertTrue(Qwen3AsrChunking.chunkRanges(totalCount: 0, maxSamples: 100).isEmpty)
    }

    func testChunkRangesFitsInOneChunk() {
        let ranges = Qwen3AsrChunking.chunkRanges(totalCount: 50, maxSamples: 100)
        XCTAssertEqual(ranges, [0 ..< 50])
    }

    func testChunkRangesExactMultipleEmitsFullSizeChunks() {
        let ranges = Qwen3AsrChunking.chunkRanges(totalCount: 300, maxSamples: 100)
        XCTAssertEqual(ranges, [0 ..< 100, 100 ..< 200, 200 ..< 300])
    }

    func testChunkRangesUnevenTailIsShorter() {
        let ranges = Qwen3AsrChunking.chunkRanges(totalCount: 250, maxSamples: 100)
        XCTAssertEqual(ranges, [0 ..< 100, 100 ..< 200, 200 ..< 250])
        XCTAssertEqual(ranges.last?.count, 50)
    }

    func testChunkRangesSingleSampleTail() {
        let ranges = Qwen3AsrChunking.chunkRanges(totalCount: 101, maxSamples: 100)
        XCTAssertEqual(ranges, [0 ..< 100, 100 ..< 101])
    }

    func testChunkRangesBoundaryEqualsMaxSamples() {
        // totalCount == maxSamples → exactly one range, no off-by-one
        // emitting an empty trailing chunk.
        let ranges = Qwen3AsrChunking.chunkRanges(totalCount: 100, maxSamples: 100)
        XCTAssertEqual(ranges, [0 ..< 100])
    }

    func testChunkRangesAreContiguousAndCoverFullInput() {
        // Property check: concatenated ranges must cover [0, totalCount)
        // with no gaps or overlaps. This is the contract `transcribeSegments`
        // relies on to feed the manager.
        let total = 12345
        let max = 1000
        let ranges = Qwen3AsrChunking.chunkRanges(totalCount: total, maxSamples: max)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, total)
        for i in 1 ..< ranges.count {
            XCTAssertEqual(
                ranges[i].lowerBound,
                ranges[i - 1].upperBound,
                "Range \(i) must start where range \(i - 1) ended",
            )
        }
        let totalLength = ranges.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalLength, total)
    }

    func testChunkRangesRespectsMaxSamplesUpperBound() {
        let ranges = Qwen3AsrChunking.chunkRanges(totalCount: 12345, maxSamples: 1000)
        for range in ranges {
            XCTAssertLessThanOrEqual(range.count, 1000)
        }
    }

    func testChunkRangesProduction30SecondCap() {
        // Real-world sanity: 75 s of 16 kHz audio is 1_200_000 samples; with
        // the production 30 s cap (480_000 samples), expect three chunks
        // ending at 480k / 960k / 1_200k.
        let ranges = Qwen3AsrChunking.chunkRanges(totalCount: 1_200_000, maxSamples: 480_000)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0].upperBound, 480_000)
        XCTAssertEqual(ranges[1].upperBound, 960_000)
        XCTAssertEqual(ranges[2].upperBound, 1_200_000)
    }
}
