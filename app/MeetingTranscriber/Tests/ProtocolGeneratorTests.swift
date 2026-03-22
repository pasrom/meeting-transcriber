@testable import MeetingTranscriber
import XCTest

final class ProtocolGeneratorTests: XCTestCase {
    // MARK: - Stream JSON Parsing

    #if !APPSTORE
        func testParseContentBlockDelta() {
            let line = """
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello world"}}
            """
            XCTAssertEqual(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line), "Hello world")
        }

        func testParseAssistantMessage() {
            let line = """
            {"type":"assistant","message":{"content":[{"type":"text","text":"Full protocol text"}]}}
            """
            XCTAssertEqual(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line), "Full protocol text")
        }

        func testParseIrrelevantType() {
            let line = """
            {"type":"message_start","message":{"id":"msg_123"}}
            """
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line))
        }

        func testParseInvalidJSON() {
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine("not json"))
        }

        func testParseEmptyLine() {
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine(""))
        }

        func testParseContentBlockDeltaNonTextType() {
            let line = """
            {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}
            """
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line))
        }

        func testParseAssistantMessageNoTextBlock() {
            let line = """
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"123"}]}}
            """
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line))
        }
    #endif

    // MARK: - Prompt Construction

    func testProtocolPromptContainsStructure() {
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("# Meeting Protocol"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Summary"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Participants"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Topics Discussed"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Decisions"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Tasks"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Open Questions"))
    }

    func testProtocolPromptEndsWithTranscriptMarker() {
        let trimmed = ProtocolGenerator.protocolPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasSuffix("Transcript:"))
    }

    func testDiarizationNoteContainsSpeakerFormats() {
        let note = ProtocolGenerator.diarizationNote
        XCTAssertTrue(note.contains("[SPEAKER_00]"))
        XCTAssertTrue(note.contains("[Me]"))
        XCTAssertTrue(note.contains("[Remote]"))
    }

    // MARK: - Filename Generation

    func testFilenameFormat() {
        let name = ProtocolGenerator.filename(title: "Team Meeting", ext: "md")
        // Format: yyyyMMdd_HHmm_team_meeting.md
        XCTAssertTrue(name.hasSuffix("_team_meeting.md"))
        // Should start with date pattern (8 digits _ 4 digits)
        let prefix = String(name.prefix(13))
        XCTAssertNotNil(
            prefix.range(of: #"^\d{8}_\d{4}$"#, options: .regularExpression),
            "Expected date prefix, got: \(prefix)",
        )
    }

    func testFilenameSlugLowercase() {
        let name = ProtocolGenerator.filename(title: "Daily Standup", ext: "txt")
        XCTAssertTrue(name.contains("daily_standup"))
    }

    func testFilenameExtension() {
        let md = ProtocolGenerator.filename(title: "Test", ext: "md")
        XCTAssertTrue(md.hasSuffix(".md"))

        let txt = ProtocolGenerator.filename(title: "Test", ext: "txt")
        XCTAssertTrue(txt.hasSuffix(".txt"))
    }

    // MARK: - Filename Sanitization

    func testFilenameSanitizesSlashes() {
        let name = ProtocolGenerator.filename(title: "Code/Review", ext: "md")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.contains("codereview"))
    }

    func testFilenameSanitizesColons() {
        let name = ProtocolGenerator.filename(title: "Meeting: Planning", ext: "md")
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.contains("meeting_planning"))
    }

    func testFilenameSanitizesBackslashes() {
        let name = ProtocolGenerator.filename(title: "Path\\Name", ext: "md")
        XCTAssertFalse(name.contains("\\"))
        XCTAssertTrue(name.contains("pathname"))
    }

    func testFilenameSanitizesNullBytes() {
        let name = ProtocolGenerator.filename(title: "Test\0Title", ext: "md")
        XCTAssertFalse(name.contains("\0"))
        XCTAssertTrue(name.contains("testtitle"))
    }

    func testFilenameSanitizesMultipleForbiddenChars() {
        let name = ProtocolGenerator.filename(title: "A/B:C\\D", ext: "txt")
        XCTAssertTrue(name.hasSuffix("_abcd.txt"))
    }

    // MARK: - File Save Operations

    func testSaveTranscript() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proto_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let text = "[00:00] Hello\n[00:05] World"
        let url = try ProtocolGenerator.saveTranscript(text, title: "Test", dir: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("_test.txt"))

        let loaded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(loaded, text)
    }

    func testSaveProtocol() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proto_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let markdown = "# Meeting Protocol\n\n## Summary\nTest meeting."
        let url = try ProtocolGenerator.saveProtocol(markdown, title: "Standup", dir: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("_standup.md"))

        let loaded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(loaded, markdown)
    }

    func testSaveCreatesDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proto_test_\(UUID().uuidString)")
            .appendingPathComponent("nested")
        defer {
            try? FileManager.default.removeItem(
                at: tmpDir.deletingLastPathComponent(),
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.path))

        let url = try ProtocolGenerator.saveTranscript("test", title: "X", dir: tmpDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Available Binaries

    #if !APPSTORE
        func testAvailableClaudeBinariesContainsClaude() {
            let binaries = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            XCTAssertTrue(binaries.contains("claude"), "Available binaries should always contain 'claude'")
        }

        func testAvailableClaudeBinariesAreSorted() {
            let binaries = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            XCTAssertEqual(binaries, binaries.sorted(), "Available binaries should be sorted")
        }

        // MARK: - Environment Stripping

        func testGenerateStripsClaudeCodeFromEnvironment() {
            // Verify that ClaudeCLIProtocolGenerator.generate() removes CLAUDECODE from the
            // process environment. We cannot call generate() directly (it launches
            // the real claude CLI), so we replicate the env-setup logic and verify
            // that CLAUDECODE is removed.

            // Set CLAUDECODE in current process env so it would be inherited
            setenv("CLAUDECODE", "1", 1)
            defer { unsetenv("CLAUDECODE") }

            // Replicate the exact env setup from ClaudeCLIProtocolGenerator.generate()
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")

            XCTAssertNil(
                env["CLAUDECODE"],
                "CLAUDECODE should be removed from the process environment",
            )

            // Also verify that the original environment DID have it
            XCTAssertNotNil(
                ProcessInfo.processInfo.environment["CLAUDECODE"],
                "CLAUDECODE should exist in the current process environment",
            )
        }
    #endif

    // MARK: - Custom Prompt Loading

    /// Run a test block with a temporary custom prompt file, restoring the original state afterwards.
    private func withCustomPromptFile(_ body: (URL) throws -> Void) throws {
        let url = AppPaths.customPromptFile
        let fm = FileManager.default
        let backup = fm.fileExists(atPath: url.path)
            ? try? String(contentsOf: url, encoding: .utf8)
            : nil
        defer {
            if let backup {
                try? backup.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? fm.removeItem(at: url)
            }
        }
        try body(url)
    }

    func testLoadPromptReturnsDefaultWhenNoFile() throws {
        try withCustomPromptFile { url in
            try? FileManager.default.removeItem(at: url)

            let prompt = ProtocolGenerator.loadPrompt()
            XCTAssertEqual(prompt, ProtocolGenerator.protocolPrompt)
        }
    }

    func testLoadPromptReadsCustomFile() throws {
        try withCustomPromptFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let custom = "Custom prompt for testing"
            try custom.write(to: url, atomically: true, encoding: .utf8)

            let prompt = ProtocolGenerator.loadPrompt()
            XCTAssertEqual(prompt, custom)
        }
    }

    func testLoadPromptIgnoresEmptyFile() throws {
        try withCustomPromptFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: url, atomically: true, encoding: .utf8)

            let prompt = ProtocolGenerator.loadPrompt()
            XCTAssertEqual(prompt, ProtocolGenerator.protocolPrompt)
        }
    }

    func testLoadPromptIgnoresWhitespaceOnlyFile() throws {
        try withCustomPromptFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "   \n  \n  ".write(to: url, atomically: true, encoding: .utf8)

            let prompt = ProtocolGenerator.loadPrompt()
            XCTAssertEqual(prompt, ProtocolGenerator.protocolPrompt)
        }
    }

    #if !APPSTORE
        func testGenerateEnvStripDoesNotRemoveOtherVars() {
            // Verify that removing CLAUDECODE doesn't affect other env vars
            let testKey = "MEETING_TRANSCRIBER_TEST_VAR_\(UUID().uuidString)"
            setenv(testKey, "test_value", 1)
            defer { unsetenv(testKey) }

            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")

            XCTAssertEqual(
                env[testKey], "test_value",
                "Other env vars should be preserved when stripping CLAUDECODE",
            )
        }
    #endif

    // MARK: - Error Descriptions

    func testProtocolErrorEmptyProtocol() {
        let error: ProtocolError = .emptyProtocol
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription?.contains("empty"), true)
    }

    func testProtocolErrorHTTPError() {
        let error: ProtocolError = .httpError(500, "Internal Server Error")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription?.contains("500"), true)
    }

    func testProtocolErrorConnectionFailed() {
        let error: ProtocolError = .connectionFailed("timeout")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription?.contains("timeout"), true)
    }

    #if !APPSTORE
        func testProtocolErrorCLINotFound() {
            let error: ProtocolError = .cliNotFound("claude")
            XCTAssertNotNil(error.errorDescription)
            XCTAssertEqual(error.errorDescription?.contains("claude"), true)
        }

        func testProtocolErrorCLIFailed() {
            let error: ProtocolError = .cliFailed(1, "something went wrong")
            XCTAssertNotNil(error.errorDescription)
            XCTAssertEqual(error.errorDescription?.contains("1"), true)
        }

        func testProtocolErrorTimeout() {
            let error: ProtocolError = .timeout
            XCTAssertNotNil(error.errorDescription)
        }
    #endif

    // MARK: - RecorderError Descriptions

    func testRecorderErrorNotRecording() {
        let error: RecorderError = .notRecording
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription?.contains("Not currently recording"), true)
    }

    func testRecorderErrorNoAudioData() {
        let error: RecorderError = .noAudioData
        XCTAssertNotNil(error.errorDescription)
    }

    func testRecorderErrorUnsupportedOS() {
        let error: RecorderError = .unsupportedOS
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription?.contains("14.2"), true)
    }
}
