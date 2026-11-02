import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "TerminologyRules")

/// What Settings reports about the terminology rules the next job will apply.
enum TerminologyRulesStatus: Equatable {
    /// Rules parsed from the text area or from a readable rules file.
    case rules(TerminologyNormalizer.Diagnostics)
    /// A rules file is selected but cannot be read or is not UTF-8. No rules
    /// apply: falling back to the text area would produce transcripts nobody
    /// can explain afterwards.
    case fileUnavailable

    var message: String {
        switch self {
        case let .rules(diagnostics): diagnostics.message
        case .fileUnavailable: "Terminology rules file cannot be read. No rules are applied."
        }
    }
}

/// Outcome of one read of the rules file.
enum TerminologyRulesFileLoad: Equatable {
    case loaded(String)
    case tooLarge
    case unavailable
}

/// Optional terminology rules file, an alternative to the Settings text area
/// for rules maintained outside the app. Selection, bookmark and repair mirror
/// the custom vocabulary file; the text area stays the source while no file is
/// selected.
extension AppSettings {
    var usesTerminologyRulesFile: Bool {
        !terminologyRulesFilePath.isEmpty
    }

    var terminologyRulesFile: URL? {
        var isStale = false
        guard let url = resolveTerminologyRulesFile(isStale: &isStale) else { return nil }
        if isStale,
           let refreshed = VocabularyFileAccess.withAccess(to: url, VocabularyFileAccess.makeBookmark) {
            updateTerminologyRulesFileSelection(path: url.path, bookmark: refreshed)
        }
        return url
    }

    func setTerminologyRulesFile(_ url: URL) {
        let bookmark = VocabularyFileAccess.withAccess(to: url, VocabularyFileAccess.makeBookmark)
        updateTerminologyRulesFileSelection(path: url.path, bookmark: bookmark)
        refreshTerminologyRulesValidation()
    }

    /// Handles manual path edits from the Settings text field. A bookmark is
    /// tied to its original URL, so it is dropped when a different path is
    /// typed. An empty path returns to the text area.
    func setTerminologyRulesFilePath(_ path: String) {
        guard path != terminologyRulesFilePath else { return }
        updateTerminologyRulesFileSelection(path: path, bookmark: nil)
        refreshTerminologyRulesValidation()
    }

    func clearTerminologyRulesFile() {
        setTerminologyRulesFilePath("")
    }

    func repairStaleTerminologyRulesFileBookmark() {
        guard let bookmark = terminologyRulesFileBookmark,
              let repaired = VocabularyFileAccess.refreshedStaleBookmark(bookmark)
        else { return }
        updateTerminologyRulesFileSelection(path: repaired.url.path, bookmark: repaired.bookmark)
        refreshTerminologyRulesValidation()
    }

    /// The rules one job applies, called once at its start by the per-job
    /// snapshot in `PipelineQueue`. With a file selected, the file is read
    /// afresh, so an edit affects the next job and never half of a running one.
    func terminologyNormalizerForJob() -> TerminologyNormalizer {
        guard usesTerminologyRulesFile else { return TerminologyNormalizer(rulesText: terminologyRulesText) }
        let (normalizer, load) = loadTerminologyRulesFile()
        // No path in the line: os_log output can leave the machine.
        switch load {
        case .loaded: break

        case .tooLarge:
            logger.error("Terminology rules file is too large; no terminology rules applied to this job")

        case .unavailable:
            logger.error("Terminology rules file cannot be read; no terminology rules applied to this job")
        }
        return normalizer
    }

    func refreshTerminologyRulesValidation() {
        guard usesTerminologyRulesFile else {
            terminologyRulesFileContents = ""
            terminologyRulesValidation = .rules(TerminologyNormalizer(rulesText: terminologyRulesText).diagnostics)
            return
        }
        _ = loadTerminologyRulesFile()
    }

    /// Reads the file without caching: it is bounded by the normalizer's own
    /// size limit and read once per job, so a revision cache would save
    /// nothing measurable and add a way to apply stale rules.
    static func readTerminologyRulesFile(at url: URL) -> TerminologyRulesFileLoad {
        guard let revision = WhisperVocabularyPrompt.fileRevision(at: url.path) else { return .unavailable }
        guard revision.fileSize <= UInt64(TerminologyNormalizer.maximumRulesTextBytes) else { return .tooLarge }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return .unavailable }
        return .loaded(contents)
    }

    /// Reads the selected file and updates the Settings status and preview
    /// from the same read the caller applies, so the two cannot disagree.
    private func loadTerminologyRulesFile() -> (TerminologyNormalizer, TerminologyRulesFileLoad) {
        let load = terminologyRulesFile.map { url in
            VocabularyFileAccess.withAccess(to: url, Self.readTerminologyRulesFile)
        } ?? .unavailable
        switch load {
        case let .loaded(contents):
            let normalizer = TerminologyNormalizer(rulesText: contents)
            terminologyRulesFileContents = contents
            terminologyRulesValidation = .rules(normalizer.diagnostics)
            return (normalizer, load)

        case .tooLarge:
            terminologyRulesFileContents = ""
            terminologyRulesValidation = .rules(
                TerminologyNormalizer.Diagnostics(activeRuleCount: 0, ignoredLineCount: 0, isTooLarge: true),
            )
            return (TerminologyNormalizer(), load)

        case .unavailable:
            terminologyRulesFileContents = ""
            terminologyRulesValidation = .fileUnavailable
            return (TerminologyNormalizer(), load)
        }
    }

    private func resolveTerminologyRulesFile(isStale: inout Bool) -> URL? {
        if let bookmark = terminologyRulesFileBookmark,
           let url = try? URL(
               resolvingBookmarkData: bookmark,
               options: .withSecurityScope,
               relativeTo: nil,
               bookmarkDataIsStale: &isStale,
           ) {
            return url
        }
        guard !terminologyRulesFilePath.isEmpty else { return nil }
        return URL(fileURLWithPath: terminologyRulesFilePath)
    }
}
