import Foundation
import Observation

/// What the Settings row about leftover WhisperKit models in `Documents` shows,
/// and the two things it does: look, and move the variants the user picked to
/// the Trash after they confirmed. Nothing is picked up front: a folder name
/// cannot tell this app's copy from another WhisperKit tool's. The disk work runs off the main actor; the listing and the text
/// live in `LegacyWhisperModelInventory`.
@MainActor
@Observable
final class LegacyWhisperModelsState {
    private(set) var models: [LegacyWhisperModel] = []
    private(set) var syncedToICloud = false
    /// What the last removal could not move, so the row can say why a model is
    /// still listed. Cleared only when the pane appears again, not by a rescan
    /// a settings change triggers, so a reason is not lost before it is read.
    private(set) var failures: [LegacyWhisperModelInventory.Failure] = []
    private(set) var isRemoving = false
    /// Why the old folder could not be read at all (no permission, a privacy
    /// prompt declined). Shown instead of hiding the row as if nothing were left.
    private(set) var scanProblem: String?
    /// The variants the user ticked. Only listed ones; a rescan drops the rest.
    private(set) var selection: Set<String> = []
    /// Bound to the confirmation dialog.
    var isConfirming = false

    /// Read on the main actor at every scan and removal, so both see the
    /// settings as they are then. Nil when there is no old location at all.
    private let scope: @MainActor () -> LegacyWhisperModelInventory.Scope?
    private let trash: @Sendable (URL) throws -> Void
    /// Bumped by every scan, so an older one finishing late cannot overwrite a
    /// newer result.
    private var scanGeneration = 0

    init(
        scope: @escaping @MainActor () -> LegacyWhisperModelInventory.Scope?,
        trash: @escaping @Sendable (URL) throws -> Void = LegacyWhisperModelInventory.systemTrash,
    ) {
        self.scope = scope
        self.trash = trash
    }

    /// Bound to the real `Documents` and the real Trash unless told otherwise.
    convenience init(
        settings: AppSettings,
        legacyBase: URL? = WhisperKitModelMigration.legacyDownloadBase,
        currentBase: URL = WhisperKitLocalSnapshot.downloadBaseLocation,
        currentRepoRoot: URL? = nil,
        trash: @escaping @Sendable (URL) throws -> Void = LegacyWhisperModelInventory.systemTrash,
    ) {
        self.init(
            scope: {
                Self.scope(for: settings, legacyBase: legacyBase, currentBase: currentBase, currentRepoRoot: currentRepoRoot)
            },
            trash: trash,
        )
    }

    /// Every setting the scope depends on, and nothing else: `scope(from:)`
    /// reads only these, and the view rescans whenever they change, so the two
    /// cannot drift apart.
    struct ScopeInputs: Equatable {
        let engine: TranscriptionEngineSetting
        let stockModel: String
        let customRepo: String
        let customVariant: String
        let selection: WhisperKitModelSelection
        let folderPath: String
        let folderBookmark: Data?

        init(_ settings: AppSettings) {
            engine = settings.transcriptionEngine
            stockModel = settings.whisperKitModel
            customRepo = settings.whisperKitCustomRepo.trimmingCharacters(in: .whitespaces)
            customVariant = settings.whisperKitCustomVariant.trimmingCharacters(in: .whitespaces)
            selection = settings.whisperKitModelSelection
            folderPath = settings.whisperKitCustomModelFolderPath
            folderBookmark = settings.whisperKitCustomModelFolderBookmark
        }
    }

    static func scope(
        for settings: AppSettings,
        legacyBase: URL? = WhisperKitModelMigration.legacyDownloadBase,
        currentBase: URL = WhisperKitLocalSnapshot.downloadBaseLocation,
        currentRepoRoot: URL? = nil,
    ) -> LegacyWhisperModelInventory.Scope? {
        scope(from: ScopeInputs(settings), legacyBase: legacyBase, currentBase: currentBase, currentRepoRoot: currentRepoRoot)
    }

    /// What may go: the stock variants the picker has always offered, plus a
    /// custom variant of the stock repository. The selected variant and a picked
    /// model folder are protected (see `Scope`). The folder is taken from its
    /// bookmark, which is what a load reads, and from the shown path as well, so
    /// a stale path or bookmark protects too much, never less. Repository names
    /// are compared ignoring case, like the volume the migration's paths land on.
    ///
    /// Nil, so nothing is read in `Documents`, unless WhisperKit is the engine or
    /// has been used since models moved out of `Documents` (its new folder
    /// exists). Otherwise opening the pane would be this app's first access to
    /// `Documents` for a Parakeet-only user or a fresh install, and macOS would
    /// ask for it with no context. An install that last ran WhisperKit before
    /// the move and then switched engines sees the row once it picks WhisperKit.
    static func scope(
        from inputs: ScopeInputs,
        legacyBase: URL?,
        currentBase: URL,
        currentRepoRoot: URL?,
    ) -> LegacyWhisperModelInventory.Scope? {
        guard let legacyBase,
              inputs.engine == .whisperKit || FileManager.default.fileExists(atPath: currentBase.path)
        else { return nil }
        var known = Set(TranscriptionSettingsView.whisperKitModels.map(\.variant))
        known.insert(inputs.stockModel)
        if isStockRepository(inputs.customRepo) {
            known.insert(inputs.customVariant)
        }
        var selectedVariant: String?
        if case let .hub(repoID) = inputs.selection.origin, isStockRepository(repoID) {
            selectedVariant = inputs.selection.variant
        }
        let path = inputs.folderPath
        let bookmarked = inputs.folderBookmark.flatMap { bookmark in
            VocabularyFileAccess.resolve(path: path, bookmark: bookmark, options: VocabularyFileAccess.failFastScopedResolution)
        }
        let picked = [bookmarked, path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)].compactMap(\.self)
        return LegacyWhisperModelInventory.Scope(
            legacyBase: legacyBase,
            knownVariants: known,
            currentBase: currentBase,
            currentRepoRoot: currentRepoRoot,
            pickedFolders: picked,
            selectedVariant: selectedVariant,
        )
    }

    private static func isStockRepository(_ repoID: String) -> Bool {
        repoID.caseInsensitiveCompare(WhisperKitLocalSnapshot.repoID) == .orderedSame
    }

    /// The row exists only while there is something to remove or to explain.
    var isVisible: Bool {
        !models.isEmpty || !failures.isEmpty || scanProblem != nil
    }

    var summary: String {
        LegacyWhisperModelInventory.summary(models, syncedToICloud: syncedToICloud)
    }

    /// The ticked variants, in list order.
    var selectedModels: [LegacyWhisperModel] {
        models.filter { selection.contains($0.variant) }
    }

    var confirmationMessage: String {
        LegacyWhisperModelInventory.confirmationMessage(selectedModels, syncedToICloud: syncedToICloud)
    }

    func isSelected(_ variant: String) -> Bool {
        selection.contains(variant)
    }

    func setSelected(_ variant: String, _ selected: Bool) {
        if selected, models.contains(where: { $0.variant == variant }) {
            selection.insert(variant)
        } else {
            selection.remove(variant)
        }
    }

    var failureMessage: String? {
        LegacyWhisperModelInventory.failureMessage(failures)
    }

    /// Called when the pane appears and whenever a setting the scope reads
    /// changes: a fresh look, without ticks on variants no longer listed (one
    /// that just became the selected model, for instance). Skipped while a
    /// removal runs: the transcription controls are disabled then, and the
    /// removal looks again itself once its failures are recorded.
    func refresh() async {
        guard !isRemoving else { return }
        await rescan()
    }

    /// The pane appeared: the last removal's failures may no longer apply.
    func paneAppeared() {
        guard !isRemoving else { return }
        failures = []
    }

    /// Move the ticked variants to the Trash, one at a time, each against the
    /// settings as they are right before it goes. The transcription controls are
    /// disabled meanwhile; closing the window can still commit a typed custom
    /// variant, and the variant lock keeps that load's migration from running
    /// during the trash, though not from then finding nothing to move. Then look
    /// again, so the row shows what is actually left next to what failed.
    func moveSelectedToTrash() async {
        let chosen = selectedModels
        guard !isRemoving, !chosen.isEmpty else { return }
        isRemoving = true
        defer { isRemoving = false }
        let trash = trash
        var failures: [LegacyWhisperModelInventory.Failure] = []
        for model in chosen {
            guard let scope = scope() else {
                failures.append(.init(item: model.variant, reason: "The old folder is no longer available."))
                continue
            }
            failures += await Task.detached(priority: .utility) {
                LegacyWhisperModelInventory.moveToTrash([model], scope: scope, trash: trash)
            }.value
        }
        self.failures = failures
        selection = []
        await rescan()
    }

    private func rescan() async {
        scanGeneration += 1
        let generation = scanGeneration
        guard let scope = scope() else {
            models = []
            selection = []
            return
        }
        let (result, synced) = await Task.detached(priority: .utility) {
            (
                Result { try LegacyWhisperModelInventory.scan(scope) },
                LegacyWhisperModelInventory.isSyncedToICloud(scope.repoRoot),
            )
        }.value
        guard generation == scanGeneration else { return }
        switch result {
        case let .success(found):
            models = found
            scanProblem = nil

        case let .failure(error):
            models = []
            scanProblem = "Could not look for old models in Documents: \(LegacyWhisperModelInventory.reason(for: error))"
        }
        syncedToICloud = synced
        selection.formIntersection(models.map(\.variant))
    }
}
