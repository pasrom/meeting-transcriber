import Foundation
import XCTest

/// Fraction of `expected` content words present in `transcript`, compared
/// case-insensitively and punctuation-insensitively. Pure + free so it's
/// unit-testable here without the gated `EouStreamingE2ETests`, which reuses it
/// to score the real-model transcript.
func wordRecall(transcript: String, expected: [String]) -> Double {
    guard !expected.isEmpty else { return 1.0 }
    let normalized = transcript
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    let present = Set(normalized)
    let hits = expected.reduce(into: 0) { count, word in
        if present.contains(word.lowercased()) { count += 1 }
    }
    return Double(hits) / Double(expected.count)
}

/// Unit coverage for `wordRecall` — runs in every `swift test` (no E2E gate),
/// red→green TDD anchor for the recall computation the E2E asserts on.
final class EouStreamingRecallTests: XCTestCase {
    func testAllWordsPresentIsPerfectRecall() {
        XCTAssertEqual(wordRecall(transcript: "alpha beta gamma", expected: ["alpha", "beta", "gamma"]), 1.0)
    }

    func testCaseAndPunctuationInsensitive() {
        XCTAssertEqual(
            wordRecall(transcript: "Alpha, BETA! gamma.", expected: ["alpha", "beta", "gamma"]),
            1.0,
        )
    }

    func testMissingWordsReduceRecall() {
        XCTAssertEqual(wordRecall(transcript: "alpha beta", expected: ["alpha", "beta", "gamma", "delta"]), 0.5)
    }

    func testEmptyExpectedIsPerfect() {
        XCTAssertEqual(wordRecall(transcript: "", expected: []), 1.0)
    }

    func testNoMatchesIsZero() {
        XCTAssertEqual(wordRecall(transcript: "x y z", expected: ["alpha", "beta"]), 0.0)
    }
}
