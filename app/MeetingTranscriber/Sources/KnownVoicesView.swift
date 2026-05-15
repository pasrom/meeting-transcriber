import SwiftUI

/// Date / display formatters for the Known-Voices Table columns. Owns its
/// own `RelativeDateTimeFormatter` instance and lives outside the view so
/// the formatting concern stays orthogonal to view state and lifecycle.
@MainActor
enum KnownVoicesFormatting {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func lastUsedLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Filters `speakers` by case-insensitive substring match on `name`.
    /// Empty filter returns the input unchanged so callers don't have to
    /// branch on it. Extracted for unit-testability.
    static func filterSpeakers(_ speakers: [StoredSpeaker], by filter: String) -> [StoredSpeaker] {
        guard !filter.isEmpty else { return speakers }
        return speakers.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// Names of speakers that are valid merge destinations from `source` —
    /// every known speaker except `source` itself. Preserves input order
    /// so the picker's natural ordering survives.
    static func mergeCandidateNames(in speakers: [StoredSpeaker], excluding source: String) -> [String] {
        speakers.map(\.name).filter { $0 != source }
    }

    /// Trims the user-entered rename value. Returns `nil` when the result
    /// would be empty — the view treats that as a no-op (dismiss the modal
    /// without performing the rename).
    static func trimmedRenameValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Manage the persisted speaker DB: rename, delete, merge entries. Backs onto
/// `SpeakerMatcher` mutators; saves on every action.
struct KnownVoicesView: View {
    @State private var speakers: [StoredSpeaker] = []
    @State private var selection: String?
    @State private var filter = ""
    @State private var modal: ActiveModal?
    @State private var showingEnrollment = false

    private let matcher: SpeakerMatcher
    private let diarizerFactory: (() -> any DiarizationProvider)?
    /// Set by the parent when a meeting is currently waiting on a naming
    /// dialog — we then disable the enroll button to avoid two
    /// SpeakerNamingViews fighting for the user's attention.
    private let namingDialogActive: Bool
    /// Soft hint when the pipeline is busy (transcribing / diarizing).
    /// Doesn't block enrollment; just shows a caption.
    private let pipelineBusy: Bool
    @Environment(\.dismiss)
    private var dismiss

    /// Fires after every successful rename / delete / merge mutation so the
    /// caller can invalidate caches that mirror the speakers DB. Without this,
    /// `PipelineQueue.knownSpeakerNames` (issue #155) goes stale until the
    /// next pipeline event.
    private let onMutate: (() -> Void)?

    init(
        matcher: SpeakerMatcher,
        diarizerFactory: (() -> any DiarizationProvider)? = nil,
        namingDialogActive: Bool = false,
        pipelineBusy: Bool = false,
        onMutate: (() -> Void)? = nil,
    ) {
        self.matcher = matcher
        self.diarizerFactory = diarizerFactory
        self.namingDialogActive = namingDialogActive
        self.pipelineBusy = pipelineBusy
        self.onMutate = onMutate
        // Seed `speakers` synchronously from the matcher so the Table renders
        // its rows on first body evaluation. `.onAppear → reload()` re-runs
        // the same query for in-place refresh after mutations.
        _speakers = State(initialValue: SpeakerMatcher.rankByRecency(speakers: matcher.loadDB()))
    }

    enum ActiveModal: Identifiable {
        case rename(name: String, value: String)
        case merge(from: String, destination: String)
        case delete(name: String)

        var id: String {
            switch self {
            case let .rename(name, _): "rename:\(name)"
            case let .merge(from, _): "merge:\(from)"
            case let .delete(name): "delete:\(name)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Known Voices").font(.title2).bold()
                Spacer()
                Text("\(speakers.count) total").foregroundStyle(.secondary)
            }
            TextField("Filter…", text: $filter)
                .textFieldStyle(.roundedBorder)

            speakerTable
                .frame(minHeight: 280)

            actionButtonsRow
            if pipelineBusy, diarizerFactory != nil {
                Text("Pipeline busy — diarization may be slower.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 420)
        .alert("Rename speaker", isPresented: isRename) {
            TextField("Name", text: renameText)
            Button("Cancel", role: .cancel) { modal = nil }
            Button("Save") { applyRename() }
        } message: {
            Text("If a speaker with the new name already exists, the two will be merged.")
        }
        .alert("Delete speaker?", isPresented: isDelete) {
            Button("Cancel", role: .cancel) { modal = nil }
            Button("Delete", role: .destructive) { applyDelete() }
        } message: {
            Text("\(deletingName) will be removed. This cannot be undone.")
        }
        .sheet(isPresented: isMerge) { mergeSheet }
        .sheet(isPresented: $showingEnrollment) {
            if let diarizerFactory {
                VoiceEnrollmentView(
                    matcher: matcher,
                    diarizerFactory: diarizerFactory,
                ) {
                    showingEnrollment = false
                    reload()
                }
            }
        }
    }

    // MARK: - Modal bindings

    private var isRename: Binding<Bool> {
        Binding(
            get: { if case .rename = modal { true } else { false } },
            set: { if !$0 { modal = nil } },
        )
    }

    private var isDelete: Binding<Bool> {
        Binding(
            get: { if case .delete = modal { true } else { false } },
            set: { if !$0 { modal = nil } },
        )
    }

    private var isMerge: Binding<Bool> {
        Binding(
            get: { if case .merge = modal { true } else { false } },
            set: { if !$0 { modal = nil } },
        )
    }

    private var renameText: Binding<String> {
        Binding(
            get: { if case let .rename(_, value) = modal { value } else { "" } },
            set: { newValue in
                if case let .rename(name, _) = modal {
                    modal = .rename(name: name, value: newValue)
                }
            },
        )
    }

    private var mergeDestination: Binding<String> {
        Binding(
            get: { if case let .merge(_, dst) = modal { dst } else { "" } },
            set: { newValue in
                if case let .merge(from, _) = modal {
                    modal = .merge(from: from, destination: newValue)
                }
            },
        )
    }

    private var deletingName: String {
        if case let .delete(name) = modal { return name }
        return ""
    }

    private var mergingFrom: String {
        if case let .merge(from, _) = modal { return from }
        return ""
    }

    private var mergeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(mergingFrom) into…").font(.headline)
            Picker("Destination", selection: mergeDestination) {
                Text("(choose)").tag("")
                ForEach(mergeCandidates, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            Text(
                "Embeddings, centroid, last-used and use count of both speakers will be combined; "
                    + "\(mergingFrom) is removed.",
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { modal = nil }
                Button("Merge") { applyMerge() }
                    .disabled(mergeDestination.wrappedValue.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private var speakerTable: some View {
        Table(filteredSpeakers, selection: $selection) {
            TableColumn("Name") { speaker in
                HStack(spacing: 6) {
                    Text(speaker.name)
                    if speaker.isSynthetic {
                        syntheticTag
                    }
                }
            }
            TableColumn("Last used") { Text(KnownVoicesFormatting.lastUsedLabel($0.lastUsed)) }
            TableColumn("Uses") { Text("\($0.useCount)") }
            TableColumn("Samples") { Text("\($0.embeddings.count)") }
        }
    }

    private var syntheticTag: some View {
        Text("synthetic")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(.secondary.opacity(0.5), lineWidth: 1))
            .help(
                "Seeded via debug RPC with a random embedding."
                    + " Excluded from auto-naming. Delete to remove.",
            )
    }

    // MARK: - Derived

    private var filteredSpeakers: [StoredSpeaker] {
        KnownVoicesFormatting.filterSpeakers(speakers, by: filter)
    }

    private var mergeCandidates: [String] {
        KnownVoicesFormatting.mergeCandidateNames(in: speakers, excluding: mergingFrom)
    }

    // MARK: - Actions

    private var actionButtonsRow: some View {
        HStack {
            if diarizerFactory != nil {
                Button("Add from Recording…") { showingEnrollment = true }
                    .disabled(namingDialogActive)
                    .help(
                        namingDialogActive
                            ? "Finish the open naming dialog before enrolling new voices."
                            : "Diarize an existing audio file and seed speaker DB entries.",
                    )
            }
            Button("Rename") { startRename() }
                .disabled(selection == nil)
            Button("Merge into…") { startMerge() }
                .disabled(selection == nil || speakers.count < 2)
            Button("Delete", role: .destructive) {
                if let selection { modal = .delete(name: selection) }
            }
            .disabled(selection == nil)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func reload() {
        speakers = SpeakerMatcher.rankByRecency(speakers: matcher.loadDB())
    }

    private func startRename() {
        guard let selection else { return }
        modal = .rename(name: selection, value: selection)
    }

    private func applyRename() {
        guard case let .rename(from, value) = modal else { return }
        modal = nil
        guard let trimmed = KnownVoicesFormatting.trimmedRenameValue(value) else { return }
        performRename(from: from, to: trimmed)
        selection = trimmed
    }

    func performRename(from: String, to: String) {
        matcher.renameSpeaker(from: from, to: to)
        reload()
        onMutate?()
    }

    private func startMerge() {
        guard let selection else { return }
        modal = .merge(from: selection, destination: "")
    }

    private func applyMerge() {
        guard case let .merge(from, dst) = modal, !dst.isEmpty else { return }
        modal = nil
        performMerge(from: from, into: dst)
        selection = dst
    }

    func performMerge(from: String, into: String) {
        matcher.mergeSpeakers(from: from, into: into)
        reload()
        onMutate?()
    }

    private func applyDelete() {
        guard case let .delete(name) = modal else { return }
        modal = nil
        performDelete(name: name)
        if selection == name { selection = nil }
    }

    func performDelete(name: String) {
        matcher.deleteSpeaker(name: name)
        reload()
        onMutate?()
    }
}
