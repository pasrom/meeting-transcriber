@testable import MeetingTranscriber
import os
import XCTest

final class NotificationRingBufferTests: XCTestCase {
    // MARK: - Records title / body / timestamp

    func testRecordCapturesTitleBodyAndTimestamp() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let buffer = NotificationRingBuffer { fixed }

        buffer.record(title: "Meeting Detected", body: "Recording: Standup (Teams)")

        XCTAssertEqual(buffer.entries.count, 1)
        let entry = buffer.entries[0]
        XCTAssertEqual(entry.title, "Meeting Detected")
        XCTAssertEqual(entry.body, "Recording: Standup (Teams)")
        XCTAssertEqual(entry.postedAt, fixed)
    }

    func testTimestampAdvancesWithClock() {
        let times = [
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 20),
        ]
        // `now` is @Sendable, so drive the tick through a lock rather than a
        // captured mutable var.
        let tick = OSAllocatedUnfairLock<Int>(initialState: 0)
        let buffer = NotificationRingBuffer {
            tick.withLock { i in
                defer { i += 1 }
                return times[i]
            }
        }

        buffer.record(title: "a", body: "1")
        buffer.record(title: "b", body: "2")

        XCTAssertEqual(buffer.entries.map(\.postedAt), times)
    }

    // MARK: - Ordering (chronological, newest last)

    func testEntriesAreChronologicalNewestLast() {
        let buffer = NotificationRingBuffer()

        buffer.record(title: "first", body: "1")
        buffer.record(title: "second", body: "2")
        buffer.record(title: "third", body: "3")

        XCTAssertEqual(buffer.entries.map(\.title), ["first", "second", "third"])
    }

    // MARK: - Cap + oldest-first eviction

    func testCapsAtCapacityEvictingOldestFirst() {
        let buffer = NotificationRingBuffer(capacity: 3)

        for i in 1 ... 5 {
            buffer.record(title: "n\(i)", body: "b\(i)")
        }

        // Oldest two (n1, n2) dropped; newest three retained in order.
        XCTAssertEqual(buffer.entries.map(\.title), ["n3", "n4", "n5"])
    }

    func testStaysAtCapacityAcrossManyRecords() {
        let buffer = NotificationRingBuffer(capacity: 2)

        for i in 0 ..< 100 {
            buffer.record(title: "n\(i)", body: "")
        }

        XCTAssertEqual(buffer.entries.count, 2)
        XCTAssertEqual(buffer.entries.map(\.title), ["n98", "n99"])
    }

    // MARK: - Default capacity is 50

    func testDefaultCapacityIsFifty() {
        XCTAssertEqual(NotificationRingBuffer.defaultCapacity, 50)

        let buffer = NotificationRingBuffer()
        for i in 0 ..< 60 {
            buffer.record(title: "n\(i)", body: "")
        }

        XCTAssertEqual(buffer.entries.count, 50)
        XCTAssertEqual(buffer.entries.first?.title, "n10")
        XCTAssertEqual(buffer.entries.last?.title, "n59")
    }

    // MARK: - Empty by default

    func testStartsEmpty() {
        XCTAssertTrue(NotificationRingBuffer().entries.isEmpty)
    }
}
