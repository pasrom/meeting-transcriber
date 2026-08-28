import Foundation

// swiftlint:disable discouraged_optional_collection

/// Converts the shared one-term-per-line vocabulary file into a bounded Whisper
/// decoder prompt. The individual terms stay in file order, so earlier entries
/// retain priority when the prompt budget is exhausted.
enum WhisperVocabularyPrompt {
    /// WhisperKit 1.1.0 shares its 224-token decoder context between the
    /// prefill prompt and generated tokens. Keep the vocabulary hint small so
    /// dense 30-second windows retain enough room to reach their timestamps.
    static let defaultTokenBudget = 32
    /// Bounds synchronous file loading and parsing on the main actor.
    static let maximumFileBytes = 256 * 1024
    static let maximumTermCount = 256
    static let maximumTermBytes = 512

    /// The values that identify cached tokens for a loaded Whisper model.
    struct CacheKey: Equatable {
        let vocabularyPath: String
        let modelVariant: String
        let vocabularyRevision: FileRevision
    }

    /// Compact metadata checked on every decode before consulting cached tokens.
    /// File identity distinguishes replacements; timestamp and size distinguish
    /// ordinary edits without reading the file contents again.
    struct FileRevision: Equatable {
        let fileID: UInt64?
        let modificationTime: Date
        let fileSize: UInt64
    }

    enum VocabularyTermsLoadResult {
        case loaded([String])
        case unavailable
    }

    /// A single-entry cache for tokens prepared by the currently loaded model.
    /// A non-matching key is a cache miss, so a path or model switch can never
    /// reuse tokens produced by an earlier configuration.
    struct TokenCache {
        enum Value: Equatable {
            case prompt([Int])
            case noPrompt
        }

        private var entry: (key: CacheKey, value: Value)?

        init() {}

        mutating func invalidate() {
            entry = nil
        }

        func value(for key: CacheKey) -> Value? {
            guard let entry, entry.key == key else { return nil }
            return entry.value
        }

        mutating func store(_ tokens: [Int], for key: CacheKey) {
            entry = (key, .prompt(tokens))
        }

        mutating func storeNoPrompt(for key: CacheKey) {
            entry = (key, .noPrompt)
        }
    }

    /// Parses the established custom-vocabulary format: one term per line.
    /// Blank lines and later duplicate entries are ignored without changing the
    /// priority of the first matching term.
    static func terms(from contents: String) -> [String] {
        var seen = Set<String>()
        return contents
            .components(separatedBy: .newlines)
            .map { term in term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { term in
                let key = term.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                return !term.isEmpty && seen.insert(key).inserted
            }
    }

    /// Reads a vocabulary file, returning `nil` when the path is absent or
    /// unreadable. Callers treat `nil` as no prompt, preserving baseline decode
    /// behaviour rather than retaining an earlier vocabulary.
    static func terms(fromFileAt path: String) -> [String]? {
        guard let revision = fileRevision(at: path) else { return nil }
        return terms(fromFileAt: path, revision: revision)
    }

    /// Reads compact metadata only. This is deliberately separate from content
    /// loading so cache hits do no string decoding or parsing.
    static func fileRevision(at path: String) -> FileRevision? {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modificationTime = attributes[.modificationDate] as? Date,
              let fileSize = attributes[.size] as? UInt64
        else { return nil }

        let fileID = attributes[.systemFileNumber] as? UInt64
        return FileRevision(
            fileID: fileID,
            modificationTime: modificationTime,
            fileSize: fileSize,
        )
    }

    /// Loads and parses file contents only after a metadata revision changes.
    /// Oversized files and files with too many terms are deliberately rejected
    /// rather than blocking the main actor or expanding a decoder prompt list.
    static func terms(fromFileAt path: String, revision: FileRevision) -> [String]? {
        switch loadTerms(fromFileAt: path, revision: revision) {
        case let .loaded(terms): terms
        case .unavailable: nil
        }
    }

    static func loadTerms(fromFileAt path: String, revision: FileRevision) -> VocabularyTermsLoadResult {
        guard revision.fileSize <= UInt64(maximumFileBytes),
              let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else { return .unavailable }

        let parsedTerms = terms(from: contents)
        guard parsedTerms.count <= maximumTermCount,
              parsedTerms.allSatisfy({ $0.utf8.count <= maximumTermBytes })
        else { return .unavailable }
        return .loaded(parsedTerms)
    }

    /// Encodes complete vocabulary terms until the supplied prompt-token budget
    /// is used. Each term is encoded with leading whitespace, as WhisperKit's
    /// tokenizer expects ordinary prompt text. WhisperKit's encoder wraps text
    /// in control tokens, so those are removed before budget accounting; a term
    /// is never truncated to fit.
    static func tokens(
        for terms: [String],
        tokenize: (String) -> [Int],
        specialTokenBegin: Int,
        tokenBudget: Int = defaultTokenBudget,
    ) -> [Int] {
        guard tokenBudget > 0 else { return [] }

        var promptTokens: [Int] = []
        for term in terms.prefix(maximumTermCount) {
            if promptTokens.count == tokenBudget { break }

            let termTokens = tokenize(" " + term).filter { $0 < specialTokenBegin }
            guard !termTokens.isEmpty,
                  promptTokens.count + termTokens.count <= tokenBudget
            else {
                continue
            }
            promptTokens.append(contentsOf: termTokens)
        }
        return promptTokens
    }
}

// swiftlint:enable discouraged_optional_collection
