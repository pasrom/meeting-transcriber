@testable import MeetingTranscriber
import XCTest

/// The templates folder, its naming rules and how a template resolves, against
/// a temp directory so no test reads or writes the real Application Support.
final class ProtocolTemplateStoreTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var store: ProtocolTemplateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "protocol-templates"))
    }

    private func write(_ text: String, as name: String) throws {
        try text.write(to: store.fileURL(named: name), atomically: true, encoding: .utf8)
    }

    // MARK: - Listing

    func testListsMarkdownFilesInFinderOrderAndNothingElse() throws {
        for name in ["b", "A", "a10", "a2"] {
            try write("Template \(name)", as: name)
        }
        let fm = FileManager.default
        try "hidden".write(to: store.directory.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        try "text".write(to: store.directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: store.directory.appendingPathComponent("Folder.md"), withIntermediateDirectories: false)
        let sub = store.directory.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try "nested".write(to: sub.appendingPathComponent("nested.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(store.names(), ["A", "a2", "a10", "b"])
    }

    func testAMissingFolderListsNoTemplates() {
        let missing = ProtocolTemplateStore(directory: store.directory.appendingPathComponent("never-created"))
        XCTAssertEqual(missing.names(), [])
    }

    // MARK: - Resolving

    /// A file that is missing, empty or only whitespace is no template: the
    /// built-in one stands in, with a warning naming the one asked for.
    func testResolvesTheFileTextOrFallsBackToTheBuiltInWithAWarning() throws {
        try write("Board template", as: "Board")
        try write("", as: "Empty")
        try write(" \n\t\n", as: "Blank")
        let fallback = { (name: String) in
            ProtocolTemplateStore.Resolution(
                text: ProtocolGenerator.protocolPrompt,
                used: .builtIn,
                warning: "Meeting notes template \"\(name)\" was not found or is empty, so the built-in template was used",
            )
        }

        XCTAssertEqual(store.resolve(.builtIn), .init(text: ProtocolGenerator.protocolPrompt, used: .builtIn, warning: nil))
        XCTAssertEqual(
            store.resolve(.file(name: "Board")), .init(text: "Board template", used: .file(name: "Board"), warning: nil),
        )
        for name in ["Empty", "Blank", "Gone"] {
            XCTAssertEqual(store.resolve(.file(name: name)), fallback(name), name)
        }
    }

    /// Names also come from the settings and the snapshot, not only from the
    /// listing; one that climbs out of the folder is never read.
    func testANameThatLeavesTheFolderIsNotATemplate() throws {
        let outside = store.directory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try "outside the folder".write(to: outside.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside.appendingPathExtension("md")) }

        XCTAssertNil(store.text(for: .file(name: "../\(outside.lastPathComponent)")))
    }

    func testEffectiveDefaultFallsBackOnlyForAMissingFile() throws {
        try write("Board template", as: "Board")

        XCTAssertEqual(store.effectiveDefault(.builtIn), .builtIn)
        XCTAssertEqual(store.effectiveDefault(.file(name: "Board")), .file(name: "Board"))
        XCTAssertEqual(store.effectiveDefault(.file(name: "Gone")), .builtIn)
    }

    /// The template the instructions came from is what decides whether the
    /// notes' first heading is a meeting title: after a fallback, the built-in.
    func testInstructionsCarryTheTemplateTextAndTheTemplateUsed() throws {
        try write("Board template", as: "Board")

        let found = store.instructions(for: .file(name: "Board"))
        let missing = store.instructions(for: .file(name: "Gone"))

        XCTAssertEqual(found.instructions, ProtocolInstructions(template: "Board template"))
        XCTAssertEqual(found.used, .file(name: "Board"))
        XCTAssertNil(found.warning)
        XCTAssertEqual(missing.instructions, ProtocolInstructions(template: ProtocolGenerator.protocolPrompt))
        XCTAssertEqual(missing.used, .builtIn)
        XCTAssertNotNil(missing.warning)
    }

    // MARK: - Creating and trashing

    func testCreateWritesTheBuiltInTextUnderTheTrimmedName() throws {
        let folder = ProtocolTemplateStore(directory: store.directory.appendingPathComponent("created-on-demand"))

        let url = try folder.create(name: "  Board  ")

        XCTAssertEqual(url, folder.fileURL(named: "Board"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ProtocolGenerator.protocolPrompt)
        XCTAssertEqual(folder.names(), ["Board"])
    }

    func testCreateRefusesATakenNameAndWritesNothing() throws {
        try write("Board template", as: "Board")

        XCTAssertThrowsError(try store.create(name: "board")) { error in
            XCTAssertEqual(error as? ProtocolTemplateName.Refusal, .duplicate)
        }
        XCTAssertEqual(store.names(), ["Board"])
        XCTAssertEqual(store.text(for: .file(name: "Board")), "Board template")
    }

    func testTrashHandsTheTemplateFileToTheTrash() throws {
        try write("Board template", as: "Board")
        var trashed: [URL] = []

        try store.trash(name: "Board") { trashed.append($0) }
        XCTAssertThrowsError(try store.trash(name: "Gone") { trashed.append($0) }) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
        }

        XCTAssertEqual(trashed, [store.fileURL(named: "Board")])
    }

    // MARK: - Names

    func testValidateTrimsAndRefusesUnusableNames() {
        typealias Refusal = ProtocolTemplateName.Refusal
        let cases: [(raw: String, name: String?, refusal: Refusal?)] = [
            ("  Board meeting  ", "Board meeting", nil),
            (String(repeating: "x", count: 80), String(repeating: "x", count: 80), nil),
            (" \n ", nil, .empty),
            (String(repeating: "x", count: 81), nil, .tooLong),
            ("Board/Staff", nil, .forbiddenCharacter),
            ("Board:Staff", nil, .forbiddenCharacter),
            (".Board", nil, .leadingDot),
            ("one-to-one", nil, .duplicate),
        ]
        for (raw, name, refusal) in cases {
            do {
                let validated = try ProtocolTemplateName.validate(raw, existing: ["Workshop", "One-to-One"])
                XCTAssertEqual(validated, name, raw)
            } catch {
                XCTAssertEqual(error as? Refusal, refusal, raw)
            }
        }
    }

    /// One string per template, so a value this build does not know still
    /// decodes rather than dropping the restored queue.
    func testTemplateIDIsStoredAsItsName() throws {
        let ids: [ProtocolTemplateID] = [.builtIn, .file(name: "Board")]
        let data = try JSONEncoder().encode(ids)

        XCTAssertEqual(String(data: data, encoding: .utf8), #"["","Board"]"#)
        XCTAssertEqual(try JSONDecoder().decode([ProtocolTemplateID].self, from: data), ids)
    }
}
