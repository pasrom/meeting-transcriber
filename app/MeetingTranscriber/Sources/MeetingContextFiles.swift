import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

enum MeetingContextFiles {
    static let suffix = ".context.json"

    enum ExistingNotes: Equatable {
        case absent, version(String)

        static func capture(_ url: URL) throws -> Self {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) } catch let error as CocoaError
                where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return .absent
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int, size <= 32 * 1024 * 1024 else {
                throw ContextFailure.limit
            }
            return try .version(ContextDigest.hash(Data(contentsOf: url)))
        }
    }

    static func save(_ record: MeetingContextRecord, beside notes: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try writePrivate(encoder.encode(record), to: sidecar(beside: notes))
    }

    static func sidecar(beside notes: URL) -> URL {
        let stem = notes.deletingPathExtension()
        return stem.deletingLastPathComponent().appendingPathComponent(stem.lastPathComponent + suffix)
    }

    static func replaceNotes(_ notes: String, at url: URL, expected: ExistingNotes) throws {
        guard try ExistingNotes.capture(url) == expected else { throw ContextFailure.revoked }
        try writePrivate(Data(notes.utf8), to: url)
    }

    /// Stage in the same directory with owner-only permissions before the
    /// rename. A failed staging write leaves the previous file intact.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let files = FileManager.default
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { try? files.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
