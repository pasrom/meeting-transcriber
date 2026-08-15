import Foundation

/// Counts calls to an injected seam, so a test can order two paths that share
/// one closure by giving each call a distinct index.
actor CallCounter {
    private var count = 0

    func next() -> Int {
        defer { count += 1 }
        return count
    }
}
