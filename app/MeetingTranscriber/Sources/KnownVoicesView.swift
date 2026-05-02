import SwiftUI

/// Manage the persisted speaker DB: rename, delete, merge entries. Backs onto
/// `SpeakerMatcher` mutators; saves on every action.
struct KnownVoicesView: View {
    @State private var speakers: [StoredSpeaker] = []
    @State private var selection: String?
    @State private var filter = ""
    @State private var modal: ActiveModal?
    @State private var showingEnrollment = false

    private let matcher: SpeakerMatcher
    private let diarizerFactory: (() -> DiarizationProvider)?
    /// Set by the parent when a meeting is currently waiting on a naming
    /// dialog — we then disable the enroll button to avoid two
    /// SpeakerNamingViews fighting for the user's attention.
    private let namingDialogActive: Bool
    /// Soft hint when the pipeline is busy (transcribing / diarizing).
    /// Doesn't block enrollment; just shows a caption.
    private let pipelineBusy: Bool
    @Environment(\.dismiss)
    private var dismiss

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init(
        matcher: SpeakerMatcher,
        diarizerFactory: (() -> DiarizationProvider)? = nil,
        namingDialogActive: Bool = false,
        pipelineBusy: Bool = false,
    ) {
        self.matcher = matcher
        self.diarizerFactory = diarizerFactory
        self.namingDialogActive = namingDialogActive
        self.pipelineBusy = pipelineBusy
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

            Table(filteredSpeakers, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Last used") { Text(Self.lastUsedLabel($0.lastUsed)) }
                TableColumn("Uses") { Text("\($0.useCount)") }
                TableColumn("Samples") { Text("\($0.embeddings.count)") }
            }
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
        .onAppear { reload() }
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

    // MARK: - Derived

    private var filteredSpeakers: [StoredSpeaker] {
        guard !filter.isEmpty else { return speakers }
        return speakers.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var mergeCandidates: [String] {
        let from = mergingFrom
        return speakers.map(\.name).filter { $0 != from }
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        modal = nil
        guard !trimmed.isEmpty else { return }
        matcher.renameSpeaker(from: from, to: trimmed)
        selection = trimmed
        reload()
    }

    private func startMerge() {
        guard let selection else { return }
        modal = .merge(from: selection, destination: "")
    }

    private func applyMerge() {
        guard case let .merge(from, dst) = modal, !dst.isEmpty else { return }
        modal = nil
        matcher.mergeSpeakers(from: from, into: dst)
        selection = dst
        reload()
    }

    private func applyDelete() {
        guard case let .delete(name) = modal else { return }
        modal = nil
        matcher.deleteSpeaker(name: name)
        if selection == name { selection = nil }
        reload()
    }

    private static func lastUsedLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
