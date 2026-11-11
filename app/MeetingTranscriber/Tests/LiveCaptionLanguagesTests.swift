@testable import MeetingTranscriber
import XCTest

final class LiveCaptionLanguagesTests: XCTestCase {
    /// The tokenizer tags are all region-qualified; the trained set keeps the region
    /// only where the tokenizer has more than one dialect of a language.
    func testTrainedTagsAreExactlyTheTokenizerLanguages() {
        let tokenizerTags = NemotronPromptFixture.load().langTags
        XCTAssertEqual(tokenizerTags.count, 39)
        let derived = tokenizerTags.map { tag in
            LiveCaptionLanguages.trainedTags.contains(tag) ? tag : String(tag.prefix { $0 != "-" })
        }
        XCTAssertEqual(Set(derived), LiveCaptionLanguages.trainedTags)
        XCTAssertEqual(LiveCaptionLanguages.trainedTags.count, tokenizerTags.count)
    }

    func testBareAliasesAndCaseUnderscoreNormalization() {
        for (input, expected) in [
            ("en", "en-US"), ("es", "es-ES"), ("pt", "pt-BR"), ("zh", "zh-CN"), ("no", "nb"),
            ("EN_us", "en-US"), ("PT_br", "pt-BR"), ("Fr_ca", "fr-CA"), ("DE", "de"),
        ] {
            XCTAssertEqual(LiveCaptionLanguages.canonicalTag(for: input), expected, input)
        }
    }

    func testUntrainedLanguagesAndUnlistedRegionsAreRejected() {
        for input in ["id", "id-ID", "ms", "pt-AO", "ja-JP"] {
            XCTAssertNil(LiveCaptionLanguages.canonicalTag(for: input), input)
        }
    }
}

/// The shipped Nemotron model's `prompt_dictionary` and tokenizer language tags
/// (identical for the latin and multilingual 2240 ms variants).
struct NemotronPromptFixture: Decodable {
    let promptDictionary: [String: Int]
    let langTags: [String]

    static func load() -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // swiftlint:disable:next force_try
        return try! decoder.decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().appendingPathComponent("Fixtures/nemotron_prompt_metadata.json")))
    }
}
