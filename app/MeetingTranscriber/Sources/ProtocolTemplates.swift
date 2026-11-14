// swiftlint:disable:this file_name - one file for the four template types (ID, name rules,
// store, migration), which change together; none of them is the file's single subject.
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolTemplates")

/// Which meeting-notes template a job or the default setting names: the
/// built-in prompt, or a Markdown file in the templates folder, by name.
///
/// Persisted as one string, `""` for the built-in and the name otherwise, in
/// `AppSettings` and in the pipeline snapshot alike. A string rather than the
/// synthesized enum encoding because every string decodes: a value this build
/// does not know becomes a name that falls back to the built-in with a warning,
/// where an unknown enum case would throw and drop the whole restored queue.
enum ProtocolTemplateID: Hashable, Codable {
    case builtIn
    case file(name: String)

    init(storedValue: String) {
        self = storedValue.isEmpty ? .builtIn : .file(name: storedValue)
    }

    var storedValue: String {
        switch self {
        case .builtIn: ""
        case let .file(name): name
        }
    }

    init(from decoder: any Decoder) throws {
        try self.init(storedValue: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedValue)
    }
}

/// The rules for naming a new template. The name becomes the file name, so it
/// must be one visible path component the store will list.
enum ProtocolTemplateName {
    static let maxLength = 80

    enum Refusal: LocalizedError, Equatable {
        case empty
        case tooLong
        case forbiddenCharacter
        case leadingDot
        case duplicate

        var errorDescription: String? {
            switch self {
            case .empty: "Enter a name for the template."
            case .tooLong: "Use at most \(ProtocolTemplateName.maxLength) characters."
            case .forbiddenCharacter: "A template name cannot contain “/” or “:”."
            case .leadingDot: "A template name cannot start with a dot."
            case .duplicate: "A template with this name already exists."
            }
        }
    }

    /// `raw` trimmed, when it can name a new template beside `existing`.
    static func validate(_ raw: String, existing: [String]) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw Refusal.empty }
        if name.count > maxLength { throw Refusal.tooLong }
        if name.contains("/") || name.contains(":") { throw Refusal.forbiddenCharacter }
        if name.hasPrefix(".") { throw Refusal.leadingDot }
        if isTaken(name, in: existing) { throw Refusal.duplicate }
        return name
    }

    /// Case-insensitive, because the default macOS volume treats `Board.md`
    /// and `board.md` as one file.
    static func isTaken(_ name: String, in existing: [String]) -> Bool {
        existing.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// The templates folder: every `*.md` file directly inside it is a template
/// named after the file. Every call reads the folder anew, so files added,
/// renamed or removed in Finder show up without a restart.
struct ProtocolTemplateStore {
    let directory: URL

    static let production = Self(directory: AppPaths.protocolTemplatesDir)

    private static let fileExtension = "md"

    /// What a template resolves to when meeting notes are made.
    struct Resolution: Equatable {
        let text: String
        /// The template the text came from: the one asked for, or `.builtIn`
        /// after a fallback.
        let used: ProtocolTemplateID
        /// Set when the asked-for template could not be used and the built-in
        /// one stood in.
        let warning: String?
    }

    /// Template names, in Finder's order. Hidden files, other extensions and
    /// folders are not templates.
    func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles,
        )) ?? []
        return entries
            .filter { $0.pathExtension == Self.fileExtension && Self.isFile($0) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Where the template called `name` lives, whether or not it exists.
    func fileURL(named name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension(Self.fileExtension)
    }

    /// The built-in prompt, or the file's UTF-8 text. Nil for a file that is
    /// missing, unreadable or blank.
    func text(for id: ProtocolTemplateID) -> String? {
        guard case let .file(name) = id else { return ProtocolGenerator.protocolPrompt }
        guard let url = existingFile(named: name),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// `id`, or the built-in when it names a file that is not there. The
    /// setting itself is left alone, so restoring the file restores the default.
    func effectiveDefault(_ id: ProtocolTemplateID) -> ProtocolTemplateID {
        if case let .file(name) = id, existingFile(named: name) == nil { return .builtIn }
        return id
    }

    /// The template's text, falling back to the built-in with a warning that
    /// names the template when its file is missing, unreadable or blank.
    func resolve(_ id: ProtocolTemplateID) -> Resolution {
        if let text = text(for: id) {
            return Resolution(text: text, used: id, warning: nil)
        }
        return Resolution(
            text: ProtocolGenerator.protocolPrompt,
            used: .builtIn,
            // Matched by /v1 clients and persisted jobs; keep the text stable.
            warning: "Meeting notes template \"\(id.storedValue)\" was not found or is empty, so the built-in template was used",
        )
    }

    /// The instructions a run sends for a template, the template they came
    /// from (`.builtIn` after a fallback), and the warning to add to the job
    /// when the template fell back. The one place a job's choice becomes what
    /// the provider is asked.
    func instructions(
        for id: ProtocolTemplateID,
    ) -> (instructions: ProtocolInstructions, used: ProtocolTemplateID, warning: String?) {
        let resolution = resolve(id)
        return (ProtocolInstructions(template: resolution.text), resolution.used, resolution.warning)
    }

    /// Creates a template under a name `ProtocolTemplateName.validate` accepts,
    /// holding the built-in text, and returns its file. Never overwrites a file
    /// that appeared since the folder was listed.
    @discardableResult
    func create(name raw: String) throws -> URL {
        let name = try ProtocolTemplateName.validate(raw, existing: names())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(named: name)
        try Data(ProtocolGenerator.protocolPrompt.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Moves a template's file to the Trash. `trashItem` is a parameter so a
    /// test never touches the real Trash.
    func trash(
        name: String,
        trashItem: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
    ) throws {
        guard let url = existingFile(named: name) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fileURL(named: name).path])
        }
        try trashItem(url)
    }

    /// The template's file, when `name` is one visible path component and a
    /// file (not a folder) is there. Names also come from the settings and the
    /// pipeline snapshot, so one that would leave the folder is never followed.
    private func existingFile(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let url = fileURL(named: name)
        return Self.isFile(url) ? url : nil
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

/// Carries the single custom prompt of earlier builds into the templates folder
/// and makes it the default template.
///
/// Completion is a marker file in the templates folder, never the folder's
/// existence, because Settings may create the folder first. The two steps run
/// separately because the dev and release builds share the folder but not
/// their UserDefaults: whichever build runs first copies the prompt, and each
/// build adopts the default the marker names once. The legacy file is never
/// modified or deleted, since an older build still reads it.
enum ProtocolTemplateMigration {
    /// Hidden, so the store never lists it. Holds the migrated template's name,
    /// empty when there was nothing to copy.
    static let markerFilename = ".legacy-prompt-migrated"

    static let templateName = "Custom Prompt"

    /// Runs on every launch, before `AppSettings` reads the default. Never
    /// throws: a failure is logged, leaves the default at the built-in for this
    /// launch, and the next launch tries again.
    static func run(defaults: UserDefaults, legacyPrompt: URL, store: ProtocolTemplateStore) {
        let marker = store.directory.appendingPathComponent(markerFilename)
        if !FileManager.default.fileExists(atPath: marker.path) {
            do {
                try copyLegacyPrompt(legacyPrompt, into: store, marker: marker)
            } catch {
                // No default is written here: an absent key reads as the
                // built-in now and still lets the retry make the copy the default.
                logger.error("protocol_template_migration_failed error=\(error.localizedDescription, privacy: .public)")
                return
            }
        }
        adoptDefault(marker: marker, defaults: defaults, store: store)
    }

    /// Step 1: copy a usable legacy prompt under the first free name, then
    /// write the marker. The marker comes last, so a failed copy leaves none.
    private static func copyLegacyPrompt(_ legacyPrompt: URL, into store: ProtocolTemplateStore, marker: URL) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        var migratedName = ""
        if let prompt = try usablePrompt(at: legacyPrompt) {
            let name = freeName(in: store)
            try prompt.write(to: store.fileURL(named: name), options: .atomic)
            migratedName = name
            logger.info("protocol_template_migrated")
        }
        try Data(migratedName.utf8).write(to: marker, options: .atomic)
    }

    /// The legacy prompt's bytes when the code before templates would have used
    /// them: the file exists, is UTF-8 and is not blank. A file that exists but
    /// cannot be read throws, so the next launch tries again.
    private static func usablePrompt(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return data
    }

    /// "Custom Prompt", else "Custom Prompt 2", "Custom Prompt 3", …
    private static func freeName(in store: ProtocolTemplateStore) -> String {
        let existing = store.names()
        var number = 1
        while true {
            let candidate = number == 1 ? templateName : "\(templateName) \(number)"
            let path = store.fileURL(named: candidate).path
            if !ProtocolTemplateName.isTaken(candidate, in: existing), !FileManager.default.fileExists(atPath: path) {
                return candidate
            }
            number += 1
        }
    }

    /// Step 2: when this build has no default yet, take the template the
    /// marker names if its file is still there, else the built-in.
    private static func adoptDefault(marker: URL, defaults: UserDefaults, store: ProtocolTemplateStore) {
        guard defaults.object(forKey: AppSettings.defaultProtocolTemplateKey) == nil else { return }
        guard let migratedName = try? String(contentsOf: marker, encoding: .utf8) else {
            logger.error("protocol_template_marker_unreadable")
            return
        }
        let name = migratedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = store.effectiveDefault(ProtocolTemplateID(storedValue: name))
        defaults.set(template.storedValue, forKey: AppSettings.defaultProtocolTemplateKey)
    }
}
