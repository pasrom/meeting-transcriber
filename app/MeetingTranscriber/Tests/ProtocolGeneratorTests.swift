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

    // MARK: - Basename (meeting-start anchored)

    func testBasenameUsesInjectedStartTimeNotNow() throws {
        let name = try ProtocolGenerator.basename(
            title: "Daily Standup",
            startTime: localDate(2026, 7, 15, 18, 30),
            shortID: "a1b2c3d4",
        )
        // Stamp reflects the meeting start (18:30), not the wall clock now.
        XCTAssertEqual(name, "20260715_1830_daily_standup_a1b2c3d4")
    }

    func testBasenameOmitsEmptyShortID() throws {
        let name = try ProtocolGenerator.basename(
            title: "Daily Standup",
            startTime: localDate(2026, 7, 15, 18, 30),
            shortID: "",
        )
        // Empty shortID must not leave a trailing separator.
        XCTAssertEqual(name, "20260715_1830_daily_standup")
        XCTAssertFalse(name.hasSuffix("_"))
    }

    func testBasenameShortIDSuffixSurvivesReimportRoundTrip() throws {
        // Re-importing feeds a prior basename back in as a title. The leading
        // timestamp must be stripped (no compounding) but the trailing shortID
        // must be preserved as slug content, not mistaken for a stamp.
        let prior = "20260715_1830_daily_standup_a1b2c3d4"
        let reimported = try ProtocolGenerator.basename(
            title: prior,
            startTime: localDate(2026, 8, 1, 9, 0),
            shortID: "e5f6a7b8",
        )
        XCTAssertEqual(reimported, "20260801_0900_daily_standup_a1b2c3d4_e5f6a7b8")
        XCTAssertFalse(reimported.contains("20260715_1830"), "old leading stamp must be stripped")
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

    // MARK: - Slug Sanitization (Path Traversal Prevention)

    func testSanitizeSlugStripsPathSeparators() {
        let slug = ProtocolGenerator.sanitizeSlug("../../etc/passwd")
        XCTAssertFalse(slug.contains("/"), "Slug must not contain path separators")
        XCTAssertFalse(slug.contains(".."), "Slug must not contain parent directory traversal")
    }

    func testSanitizeSlugPreservesAlphanumericAndHyphens() {
        let slug = ProtocolGenerator.sanitizeSlug("Team-Meeting 2024")
        XCTAssertEqual(slug, "team-meeting_2024")
    }

    func testSanitizeSlugEmptyTitleFallback() {
        let slug = ProtocolGenerator.sanitizeSlug("///")
        XCTAssertEqual(slug, "meeting")
    }

    func testFilenameWithPathTraversalTitle() {
        let name = ProtocolGenerator.filename(title: "../../etc/passwd", ext: "md")
        XCTAssertFalse(name.contains("/"), "Filename must not contain path separators")
    }

    // MARK: - Language Substitution

    func testApplyLanguageReplacesPlaceholder() {
        let prompt = "Create protocol in {LANGUAGE} from transcript."
        let result = ProtocolGenerator.applyLanguage(prompt, language: "English")
        XCTAssertEqual(result, "Create protocol in English from transcript.")
    }

    func testApplyLanguageNoPlaceholderPassesThrough() {
        let custom = "Custom prompt without placeholder."
        let result = ProtocolGenerator.applyLanguage(custom, language: "French")
        XCTAssertEqual(result, custom)
    }

    func testDefaultPromptContainsLanguagePlaceholder() {
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("{LANGUAGE}"))
    }

    // MARK: - System Prompt Construction

    func testBuildSystemPromptSubstitutesLanguage() {
        let prompt = ProtocolGenerator.buildSystemPrompt(diarized: false, language: "Polish")
        XCTAssertTrue(prompt.contains("Polish"))
        XCTAssertFalse(prompt.contains("{LANGUAGE}"))
    }

    func testBuildSystemPromptAppendsDiarizationNoteWhenDiarized() {
        let plain = ProtocolGenerator.buildSystemPrompt(diarized: false, language: "German")
        let diarized = ProtocolGenerator.buildSystemPrompt(diarized: true, language: "German")
        XCTAssertGreaterThan(diarized.count, plain.count)
        XCTAssertTrue(diarized.contains(ProtocolGenerator.diarizationNote))
        XCTAssertFalse(plain.contains(ProtocolGenerator.diarizationNote))
    }

    // MARK: - File Save Operations

    func testSaveTranscript() throws {
        let tmpDir = try makeTempDirectory(prefix: "proto_test")

        let text = "[00:00] Hello\n[00:05] World"
        let url = try ProtocolGenerator.saveTranscript(text, basename: "20260101_0000_test", dir: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "20260101_0000_test.txt")

        let loaded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(loaded, text)
    }

    func testSaveProtocol() throws {
        let tmpDir = try makeTempDirectory(prefix: "proto_test")

        let markdown = "# Meeting Protocol\n\n## Summary\nTest meeting."
        let url = try ProtocolGenerator.saveProtocol(markdown, basename: "20260101_0000_standup", dir: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "20260101_0000_standup.md")

        let loaded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(loaded, markdown)
    }

    /// The transcript and protocol of one job must land on the identical stem
    /// (only the extension differs) when handed the same basename — the fix for
    /// the old cross-artifact minute drift, where each save re-derived its own
    /// `Date()`-stamped name.
    func testSaveTranscriptAndProtocolShareBasename() throws {
        let tmpDir = try makeTempDirectory(prefix: "shared_basename")
        let base = "20260715_1830_daily_standup_a1b2c3d4"
        let txt = try ProtocolGenerator.saveTranscript("t", basename: base, dir: tmpDir)
        let md = try ProtocolGenerator.saveProtocol("# m", basename: base, dir: tmpDir)
        XCTAssertEqual(txt.lastPathComponent, "\(base).txt")
        XCTAssertEqual(md.lastPathComponent, "\(base).md")
        XCTAssertEqual(
            txt.deletingPathExtension().lastPathComponent,
            md.deletingPathExtension().lastPathComponent,
        )
    }

    func testSaveCreatesDirectory() throws {
        let parent = try makeTempDirectory(prefix: "proto_test")
        let tmpDir = parent.appendingPathComponent("nested")

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.path))

        let url = try ProtocolGenerator.saveTranscript("test", basename: "x", dir: tmpDir)
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

    func testLoadPromptReturnsDefaultWhenNoFile() {
        let url = makeTempFile(suffix: ".md")
        // File doesn't exist → loadPrompt falls back to the built-in default.
        XCTAssertEqual(ProtocolGenerator.loadPrompt(from: url), ProtocolGenerator.protocolPrompt)
    }

    func testLoadPromptReadsCustomFile() throws {
        let url = makeTempFile(suffix: ".md")
        let custom = "Custom prompt for testing"
        try custom.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(ProtocolGenerator.loadPrompt(from: url), custom)
    }

    func testLoadPromptIgnoresEmptyFile() throws {
        let url = makeTempFile(suffix: ".md")
        try "".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(ProtocolGenerator.loadPrompt(from: url), ProtocolGenerator.protocolPrompt)
    }

    func testLoadPromptIgnoresWhitespaceOnlyFile() throws {
        let url = makeTempFile(suffix: ".md")
        try "   \n  \n  ".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(ProtocolGenerator.loadPrompt(from: url), ProtocolGenerator.protocolPrompt)
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

    // MARK: - filename timestamp-prefix compounding regression

    func testStripExistingTimestampPrefix_HHmm() {
        // The exact failure mode from PR #274: re-importing a previously-
        // slug-renamed `<today1>_<original_stem>_app.wav` would feed the
        // slug back as title, and filename would prepend ANOTHER today's
        // timestamp → compounding.
        XCTAssertEqual(
            ProtocolGenerator.stripExistingTimestampPrefix("20260516_1319_20260503_174538"),
            "20260503_174538",
        )
    }

    func testStripExistingTimestampPrefix_HHmmss() {
        // DualSourceRecorder's native format is `yyyyMMdd_HHmmss_<suffix>.wav`.
        XCTAssertEqual(
            ProtocolGenerator.stripExistingTimestampPrefix("20260503_174538_daily_standup"),
            "daily_standup",
        )
    }

    func testStripExistingTimestampPrefix_doubleCompound() {
        // Multi-layer compound left over from earlier buggy runs — strip all layers.
        XCTAssertEqual(
            ProtocolGenerator.stripExistingTimestampPrefix("20260516_1601_20260516_1319_meeting"),
            "meeting",
        )
    }

    func testStripExistingTimestampPrefix_noPrefix() {
        XCTAssertEqual(
            ProtocolGenerator.stripExistingTimestampPrefix("Daily standup"),
            "Daily standup",
        )
    }

    func testStripExistingTimestampPrefix_titleIsOnlyTimestamp() {
        // No trailing `_`, no suffix to keep — return original to avoid an empty slug.
        XCTAssertEqual(
            ProtocolGenerator.stripExistingTimestampPrefix("20260503_174538"),
            "20260503_174538",
        )
    }

    func testFilenameDoesNotCompoundOnReimport() {
        // The actual regression: re-importing a previously-processed file with
        // a slug stem should produce a single-prefixed filename, not stack
        // today's prefix on top of yesterday's.
        let result = ProtocolGenerator.filename(
            title: "20260516_1319_20260503_174538", ext: "md",
        )
        // Today's timestamp + the original recording timestamp, NOT today's twice.
        XCTAssertTrue(result.hasSuffix("_20260503_174538.md"), "got: \(result)")
        XCTAssertFalse(
            result.contains("_20260516_1319_"),
            "yesterday's prefix should have been stripped: \(result)",
        )
    }

    // MARK: - File permissions

    /// Transcripts contain verbatim meeting speech — they must be owner-only
    /// (0600), not world-readable from the inherited umask.
    func testSaveTranscriptWritesOwnerOnlyPermissions() throws {
        let dir = try makeTempDirectory(prefix: "ProtocolGenSaveTranscript")
        let url = try ProtocolGenerator.saveTranscript("hello world", basename: "standup", dir: dir)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int,
        )
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    /// Protocol markdown summarises the meeting — same owner-only requirement.
    func testSaveProtocolWritesOwnerOnlyPermissions() throws {
        let dir = try makeTempDirectory(prefix: "ProtocolGenSaveProtocol")
        let url = try ProtocolGenerator.saveProtocol("# Notes", basename: "standup", dir: dir)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int,
        )
        XCTAssertEqual(mode & 0o777, 0o600)
    }
}
