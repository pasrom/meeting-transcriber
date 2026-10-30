import Foundation

/// Byte-level access to the box tree of an ISO-BMFF (MP4/M4A) file, for tests
/// that need a container whose header lies about the audio it holds.
///
/// Boxes are found by walking real box boundaries, never by searching for a
/// four-character code, so the same bytes inside compressed audio or a
/// metadata string cannot be mistaken for a header. Every read and write is
/// checked against the box it belongs to and throws rather than touching a
/// neighbour.
struct MP4File {
    struct Box {
        let type: String
        /// The box's content after its size/type header.
        let payload: Range<Int>
    }

    struct FormatError: Error, CustomStringConvertible {
        let description: String
    }

    private(set) var data: Data

    init(contentsOf url: URL) throws {
        // `Data(contentsOf:)` starts at index 0, so indices below are file offsets.
        data = try Data(contentsOf: url)
    }

    /// The box at `path` from the top level, e.g. `"moov", "trak", "tkhd"`.
    /// Every level must hold exactly one box of that type, so a caller that
    /// patches "the" box cannot silently leave a second one untouched.
    func box(at path: String...) throws -> Box {
        var range = 0 ..< data.count
        var found: Box?
        for type in path {
            let matches = try boxes(in: range).filter { $0.type == type }
            guard matches.count == 1, let box = matches.first else {
                throw FormatError(description: "expected exactly one \(type) box, found \(matches.count)")
            }
            found = box
            range = box.payload
        }
        guard let found else { throw FormatError(description: "empty box path") }
        return found
    }

    func uint32(atPayloadOffset offset: Int, in box: Box) throws -> UInt32 {
        try read(fieldRange(offset, in: box))
    }

    mutating func put(_ value: UInt32, atPayloadOffset offset: Int, in box: Box) throws {
        let field = try fieldRange(offset, in: box)
        withUnsafeBytes(of: value.bigEndian) { data.replaceSubrange(field, with: $0) }
    }

    /// A 4-byte field inside `box`'s payload.
    private func fieldRange(_ offset: Int, in box: Box) throws -> Range<Int> {
        let start = box.payload.lowerBound + offset
        guard offset >= 0, start + 4 <= box.payload.upperBound else {
            throw FormatError(description: "field at \(offset) overruns \(box.type) (\(box.payload.count) bytes)")
        }
        return start ..< start + 4
    }

    private func read<T: FixedWidthInteger>(_ range: Range<Int>) -> T {
        data[range].reduce(0) { $0 << 8 | T($1) }
    }

    private func boxes(in range: Range<Int>) throws -> [Box] {
        var result: [Box] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor + 8 <= range.upperBound else {
                throw FormatError(description: "truncated box header at \(cursor)")
            }
            let type = String(bytes: data[cursor + 4 ..< cursor + 8], encoding: .ascii) ?? "????"
            var size = Int(read(cursor ..< cursor + 4) as UInt32)
            var headerLength = 8
            if size == 0 {
                // Extends to the end of the enclosing range.
                size = range.upperBound - cursor
            } else if size == 1 {
                // A 64-bit `largesize` follows the type.
                guard cursor + 16 <= range.upperBound else {
                    throw FormatError(description: "truncated largesize for \(type) at \(cursor)")
                }
                size = Int(clamping: read(cursor + 8 ..< cursor + 16) as UInt64)
                headerLength = 16
            }
            guard size >= headerLength, size <= range.upperBound - cursor else {
                throw FormatError(description: "\(type) at \(cursor) claims \(size) bytes, overruns its parent")
            }
            result.append(Box(type: type, payload: cursor + headerLength ..< cursor + size))
            cursor += size
        }
        return result
    }
}
