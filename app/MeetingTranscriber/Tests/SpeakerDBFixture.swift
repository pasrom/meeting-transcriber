import Foundation
@testable import MeetingTranscriber

/// A `speakers.json` in a temp directory and the helpers the DB persistence
/// tests share, so the quarantine name and the write-blocking trick live in
/// one place.
struct SpeakerDBFixture {
    /// Problems a matcher reported, in order.
    final class ProblemLog {
        var problems: [SpeakerMatcher.DBProblem] = []
    }

    let dir: URL

    var dbPath: URL {
        dir.appendingPathComponent("speakers.json")
    }

    /// A matcher on the temp DB that records its problems and does not wait
    /// before re-reading, unless `settle` says otherwise.
    func makeMatcher(settle: @escaping () -> Void = {}) -> (SpeakerMatcher, ProblemLog) {
        let log = ProblemLog()
        let matcher = SpeakerMatcher(
            dbPath: dbPath,
            onDBProblem: { log.problems.append($0) },
            settleBeforeReread: settle,
        )
        return (matcher, log)
    }

    func quarantinedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("speakers.json.corrupt-") }
    }

    func setPermissions(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Make the next DB write fail while leaving the directory writable, so a
    /// quarantine copy still succeeds: the temp file the write goes through is
    /// occupied by a directory.
    func blockDBWrites() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("speakers.json.tmp"), withIntermediateDirectories: false,
        )
    }
}
