@testable import MeetingTranscriber
import os
import XCTest

final class NemotronAsrManagerTests: XCTestCase {
    private let prompts = NemotronPromptFixture.load().promptDictionary

    /// Every picker language against the shipped model's `prompt_dictionary`: nil means
    /// the gate keeps it off Nemotron. `es` and `pt` keep the model's own bare prompts
    /// (ids 3 and 13, shared with `es-US` and `pt-PT`).
    func testEveryPickerLanguageRoutesToItsExpectedStrategyAndPromptKey() {
        let expected: [String: String?] = [
            "de": "de", "fr": "fr", "es": "es", "it": "it", "nl": "nl", "pt": "pt",
            "ja": "ja-JP", "zh": "zh-CN", "ko": "ko", "ru": "ru", "uk": "uk", "ar": "ar",
            "tr": "tr", "hi": "hi", "th": "th-TH", "vi": "vi-VN", "sv": "sv", "da": "da",
            "fi": "fi", "pl": "pl", "cs": "cs", "el": "el", "hu": "hu", "ro": "ro",
            "sk": "sk", "sl": "sl", "hr": "hr", "bg": "bg",
            "id": nil, "ms": nil, "fa": nil, "fil": nil, "mk": nil, "yue": nil,
            "bs": nil, "be": nil, "sr": nil,
        ]
        let codes = Set((PickerLanguages.whisperKit + PickerLanguages.parakeet).map(\.code)).subtracting(["", "en"])
        XCTAssertEqual(codes, Set(expected.keys), "a picker language has no expected caption route")
        for (code, key) in expected {
            let strategy = LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: code, engineSupportsLive: true)
            XCTAssertEqual(strategy, key == nil ? .reTranscribe : .nemotronStreaming, code)
            XCTAssertEqual(NemotronAsrManager.resolvedLanguageCode(code, promptDictionary: prompts), key, code)
        }
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: "en", engineSupportsLive: true),
            .englishStreaming,
        )
        XCTAssertEqual(prompts["es"], 3)
        XCTAssertEqual(prompts["pt"], 13)
    }

    func testRegionalAndHandSetCodesResolveAgainstTheShippedDictionary() {
        for (code, expected) in [
            ("pt-BR", "pt-BR"), ("PT_br", "pt-BR"), ("pt-PT", "pt-PT"), ("es-ES", "es-ES"), ("es-US", "es-US"),
            ("fr-CA", "fr-CA"), ("DE", "de"), ("he", "he-IL"), ("nb", "nb"),
            // The model's bare `no` key is `no-NO` (27), which has no tokenizer tag.
            ("no", "nb"),
        ] {
            XCTAssertEqual(NemotronAsrManager.resolvedLanguageCode(code, promptDictionary: prompts), expected, code)
        }
        for code in ["id-ID", "ms-MY", "xx", "ja-JP", "zh-TW"] {
            XCTAssertNil(NemotronAsrManager.resolvedLanguageCode(code, promptDictionary: prompts), code)
        }
    }

    func testTrainedLanguageWithoutPromptKeyResolvesToNil() {
        XCTAssertNil(NemotronAsrManager.resolvedLanguageCode("ja", promptDictionary: ["auto": 101, "ja-JA": 10]))
        XCTAssertNil(NemotronAsrManager.resolvedLanguageCode("pt-BR", promptDictionary: ["pt": 13, "pt-PT": 13]))
    }

    func testConfigureLanguageHandsResolvedCodeToManagerWithoutWarning() async {
        let received = OSAllocatedUnfairLock(initialState: [String?]())
        let warnings = OSAllocatedUnfairLock(initialState: [String]())

        do {
            try await NemotronAsrManager.configureLanguage(
                "ja", promptDictionary: prompts,
                warn: { code in warnings.withLock { $0.append(code) } },
                setLanguage: { code in received.withLock { $0.append(code) } },
            )
        } catch {
            XCTFail("Trained language with a prompt must configure: \(error)")
        }

        XCTAssertEqual(received.withLock { $0 }, ["ja-JP"])
        XCTAssertTrue(warnings.withLock { $0.isEmpty })
    }

    func testUnsupportedOrMissingPromptFailsClosedAndWarnsWithCodeOnly() async {
        let received = OSAllocatedUnfairLock(initialState: [String?]())
        let warnings = OSAllocatedUnfairLock(initialState: [String]())

        for (code, dictionary) in [("id-ID", prompts), ("ja", ["auto": 1, "ja-JA": 2])] {
            do {
                try await NemotronAsrManager.configureLanguage(
                    code, promptDictionary: dictionary,
                    warn: { rejected in warnings.withLock { $0.append(rejected) } },
                    setLanguage: { value in received.withLock { $0.append(value) } },
                )
                XCTFail("\(code) must fail without a compatible trained prompt")
            } catch {
                XCTAssertTrue(error is NemotronAsrManager.LanguageError, "\(error)")
            }
        }

        XCTAssertTrue(received.withLock { $0.isEmpty })
        XCTAssertEqual(warnings.withLock { $0 }, ["id-ID", "ja"])
    }

    func testPrepareSetsCompatiblePromptLanguageAfterLoading() async {
        let steps = OSAllocatedUnfairLock(initialState: [String]())

        do {
            try await NemotronAsrManager.prepare(
                "ja", promptDictionary: ["id-ID": 1, "ja-JP": 2],
                load: { steps.withLock { $0.append("load") } },
                setLanguage: { code in steps.withLock { $0.append(code ?? "nil") } },
                setPartialCallback: { steps.withLock { $0.append("callback") } },
            )
        } catch {
            XCTFail("Trained language with a compatible prompt must prepare: \(error)")
        }

        XCTAssertEqual(steps.withLock { $0 }, ["load", "ja-JP", "callback"])
    }

    func testPrepareRejectsUntrainedLanguageBeforeSettingLanguage() async {
        let steps = OSAllocatedUnfairLock(initialState: [String]())

        do {
            try await NemotronAsrManager.prepare(
                "id", promptDictionary: ["id-ID": 1, "ja-JP": 2],
                load: { steps.withLock { $0.append("load") } },
                setLanguage: { _ in steps.withLock { $0.append("language") } },
                setPartialCallback: { steps.withLock { $0.append("callback") } },
            )
            XCTFail("Untrained language must fail preparation")
        } catch let NemotronAsrManager.LanguageError.missingPrompt(code) {
            XCTAssertEqual(code, "id")
        } catch {
            XCTFail("Expected missingPrompt for id, got \(error)")
        }

        XCTAssertEqual(steps.withLock { $0 }, ["load"])
    }

    func testPreparePropagatesLoadErrorBeforeSettingLanguageOrCallback() async {
        enum LoadError: Error, Equatable { case failed(Int) }
        let steps = OSAllocatedUnfairLock(initialState: [String]())

        do {
            try await NemotronAsrManager.prepare(
                "ja", promptDictionary: ["ja-JP": 2],
                load: {
                    steps.withLock { $0.append("load") }
                    throw LoadError.failed(42)
                },
                setLanguage: { _ in steps.withLock { $0.append("language") } },
                setPartialCallback: { steps.withLock { $0.append("callback") } },
            )
            XCTFail("Load failure must fail preparation")
        } catch {
            XCTAssertEqual(error as? LoadError, .failed(42))
        }

        XCTAssertEqual(steps.withLock { $0 }, ["load"])
    }

    /// A pin on the declaration, not runtime proof: these unit tests cannot construct
    /// the shared models without loading real CoreML models.
    func testInstancePrepareForwardsModelPromptsAndResolvedLanguage() throws {
        let text = try String(contentsOf: Self.managerSource(), encoding: .utf8)
            .filter { !$0.isWhitespace }
        let declaration = try XCTUnwrap(
            text.range(of: "funcprepare()asyncthrows{"),
            "no instance prepare() in the manager source",
        )
        var depth = 1
        var body = ""
        for character in text[declaration.upperBound...] {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth == 0 { break }
            body.append(character)
        }
        XCTAssertEqual(depth, 0, "the instance prepare() body must have balanced braces")
        XCTAssertTrue(body.contains("tryawaitSelf.prepare("), "instance prepare() must call Self.prepare")
        XCTAssertTrue(
            body.contains("promptDictionary:shared.config.promptDictionary"),
            "instance prepare() must forward the shared model's prompt dictionary",
        )
        XCTAssertTrue(
            body.contains("manager.setLanguage($0)"),
            "instance prepare() must forward the resolved language to the manager",
        )
    }

    private static func managerSource(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NemotronAsrManager.swift")
    }
}
