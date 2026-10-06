@testable import MeetingTranscriber
import XCTest

/// The per-slug naming sidecars `removeNamingData` owns, as a fixture any suite
/// can write and assert on.
///
/// Lived as three private helpers inside `PipelineQueueTests` until a second
/// suite needed them and copied a shorter suffix list instead, which left the
/// `_naming.json` unchecked in exactly the test written to cover its deletion.
/// Suffixes come from the production list, so adding one there fails these
/// tests rather than quietly stranding the new file.
enum SidecarFixture {
    static let suffixes = SpeakerNamingStore.sidecarSuffixes + [SpeakerNamingStore.namingJSONSuffix]

    static func urls(slug: String, in recordingsDir: URL) -> [URL] {
        suffixes.map { recordingsDir.appendingPathComponent("\(slug)\($0)") }
    }

    @discardableResult
    static func write(slug: String, in recordingsDir: URL) throws -> [URL] {
        let urls = urls(slug: slug, in: recordingsDir)
        for url in urls {
            try Data([0]).write(to: url)
        }
        return urls
    }
}

extension XCTestCase {
    /// The `recordings/` subfolder of an output directory, created. Spelled out
    /// inline in three suites before the third one needed it twice.
    func makeRecordingsDir(in outputDir: URL) throws -> URL {
        let recordings = outputDir.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        return recordings
    }

    func assertSidecars(
        _ sidecars: [URL], exist: Bool,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        for sidecar in sidecars {
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: sidecar.path), exist,
                "\(sidecar.lastPathComponent): expected exists=\(exist)",
                file: file, line: line,
            )
        }
    }
}
