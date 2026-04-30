import AVFoundation
import SwiftUI

/// NSTextField subclass that forwards accessibility `set value` (AppleScript)
/// to the delegate so the SwiftUI Binding stays in sync.
private final class AutomationTextField: NSTextField {
    override func setAccessibilityValue(_ value: Any?) {
        if let str = value as? String {
            self.stringValue = str
            // Post the same notification that user typing would trigger
            NotificationCenter.default.post(
                name: NSControl.textDidChangeNotification,
                object: self,
            )
        }
    }
}

/// NSTextField wrapper that syncs accessibility `set value` to the Binding.
/// Standard SwiftUI TextField ignores programmatic accessibility value changes
/// (e.g. from AppleScript `set value of text field`), which breaks UI automation.
struct AccessibleTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var identifier: String

    func makeNSView(context: Context) -> NSTextField {
        let field = AutomationTextField()
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(identifier)
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context _: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Format seconds as "Xs" or "M:SS".
func formattedTime(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return m > 0 ? "\(m):\(String(format: "%02d", s))" : "\(s)s"
}

/// Window that lets the user name speakers after diarization.
struct SpeakerNamingView: View {
    let data: PipelineQueue.SpeakerNamingData
    /// Names of speakers known from previous meetings, surfaced as quick-pick chips
    /// in addition to the current meeting's participants. Empty array hides the row.
    let knownSpeakerNames: [String]
    let onComplete: (PipelineQueue.SpeakerNamingResult) -> Void

    init(
        data: PipelineQueue.SpeakerNamingData,
        knownSpeakerNames: [String] = [],
        onComplete: @escaping (PipelineQueue.SpeakerNamingResult) -> Void,
    ) {
        self.data = data
        self.knownSpeakerNames = knownSpeakerNames
        self.onComplete = onComplete
    }

    @State private var names: [String] = []
    @State private var completed = false
    @State private var player: AVAudioPlayer?
    @State private var playingLabel: String?
    @State private var rerunCount: Int = 2
    /// Indices of speaker rows where the user clicked "Mehr…" to reveal the full
    /// known-names list instead of the top-N ranked subset.
    @State private var knownExpanded: Set<Int> = []
    /// Number of "Known:" chips shown by default before "Mehr…" appears.
    private static let knownChipsCollapsedLimit = 8

    private var speakers: [(label: String, autoName: String?, speakingTime: Double)] {
        data.mapping.keys.sorted().map { label in
            let autoName = data.mapping[label]
            let isAutoNamed = autoName != nil && autoName != label
            return (
                label: label,
                autoName: isAutoNamed ? autoName : nil,
                speakingTime: data.speakingTimes[label] ?? 0,
            )
        }
    }

    var body: some View {
        // swiftlint:disable:next closure_body_length
        VStack(spacing: 16) {
            Text("Name Speakers — \"\(data.meetingTitle)\"")
                .font(.headline)
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Array(speakers.enumerated()), id: \.element.label) { index, speaker in
                        speakerRow(index: index, speaker: speaker)
                    }
                }
            }
            .frame(height: min(CGFloat(speakers.count) * 120, 500))

            Divider()

            HStack(spacing: 8) {
                Text("Wrong count?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("\(rerunCount) speakers", value: $rerunCount, in: 1 ... 10)
                    .font(.caption)
                    .accessibilityIdentifier("rerun-stepper")
                Button("Re-run") {
                    guard !completed else { return }
                    completed = true
                    player?.stop()
                    onComplete(.rerun(rerunCount))
                }
                .font(.caption)
                .accessibilityIdentifier("rerun-button")
            }

            HStack(spacing: 12) {
                Button("Skip") {
                    guard !completed else { return }
                    completed = true
                    onComplete(.skipped)
                }
                .keyboardShortcut(.escape)
                .accessibilityIdentifier("skip-button")

                Button("Confirm") {
                    guard !completed else { return }
                    completed = true
                    confirm()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("confirm-button")
            }
            .padding(.bottom, 8)
        }
        .padding()
        .frame(minWidth: 400, maxHeight: 700)
        .id(data.meetingTitle)
        .onAppear {
            names = Self.computeInitialNames(speakers: speakers)
            rerunCount = max(2, speakers.count + 1)
        }
        .onDisappear {
            if !completed {
                completed = true
                onComplete(.skipped)
            }
        }
    }

    private func speakerRow(
        index: Int,
        speaker: (label: String, autoName: String?, speakingTime: Double),
    ) -> some View {
        // swiftlint:disable:next closure_body_length
        GroupBox {
            // swiftlint:disable:next closure_body_length
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(speaker.label)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if data.audioPath != nil {
                        Button {
                            playSpeakerSnippet(label: speaker.label)
                        } label: {
                            Image(systemName: playingLabel == speaker.label
                                ? "stop.circle.fill" : "play.circle.fill")
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("play-\(speaker.label)")
                    }

                    Spacer()
                    Text("(\(formattedTime(speaker.speakingTime)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let autoName = speaker.autoName {
                    Text("Auto: \(autoName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if index < names.count {
                    AccessibleTextField(
                        text: $names[index],
                        placeholder: "Name",
                        identifier: "speaker-name-\(speaker.label)",
                    )
                    suggestionChips(for: index)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func suggestionChips(for index: Int) -> some View {
        let participants = unusedParticipants(currentIndex: index)
        if !participants.isEmpty {
            chipRow(names: participants, idPrefix: "participant-name-") { names[index] = $0 }
        }

        let known = unusedKnownNames(currentIndex: index)
        if !known.isEmpty {
            let autoName = index < speakers.count ? speakers[index].autoName : nil
            let ranked = Self.rankedKnownNames(
                known: known, autoName: autoName, participants: data.participants,
            )
            let expanded = knownExpanded.contains(index)
            let visible = expanded ? ranked : Array(ranked.prefix(Self.knownChipsCollapsedLimit))
            let hidden = ranked.count - visible.count
            let speakerLabel = index < speakers.count ? speakers[index].label : "\(index)"

            VStack(alignment: .leading, spacing: 2) {
                Text("Known:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ChipFlowLayout(spacing: 4) {
                    ForEach(visible, id: \.self) { name in
                        chipButton(label: name, identifier: "known-name-\(name)") {
                            names[index] = name
                        }
                    }
                    if hidden > 0 {
                        chipMoreButton(
                            label: "More (\(hidden))…",
                            identifier: "known-more-\(speakerLabel)",
                        ) { knownExpanded.insert(index) }
                    } else if expanded, ranked.count > Self.knownChipsCollapsedLimit {
                        chipMoreButton(
                            label: "Less",
                            identifier: "known-less-\(speakerLabel)",
                        ) { knownExpanded.remove(index) }
                    }
                }
            }
        }
    }

    private func chipRow(
        names: [String], idPrefix: String, onSelect: @escaping (String) -> Void,
    ) -> some View {
        ChipFlowLayout(spacing: 4) {
            ForEach(names, id: \.self) { name in
                chipButton(label: name, identifier: "\(idPrefix)\(name)") { onSelect(name) }
            }
        }
    }

    private func chipButton(
        label: String, identifier: String, action: @escaping () -> Void,
    ) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
            .accessibilityIdentifier(identifier)
    }

    private func chipMoreButton(
        label: String, identifier: String, action: @escaping () -> Void,
    ) -> some View {
        Button(label, action: action)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)
            .accessibilityIdentifier(identifier)
    }

    /// Play the longest segment of a speaker from the audio file.
    private func playSpeakerSnippet(label: String) {
        // Stop if already playing this speaker
        if playingLabel == label {
            player?.stop()
            player = nil
            playingLabel = nil
            return
        }

        guard let audioPath = data.audioPath else { return }

        // Find the longest segment for this speaker
        let speakerSegments = data.segments.filter { $0.speaker == label }
        guard let longest = speakerSegments.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return }

        // Perform file I/O off the main thread
        Task.detached { [audioPath, longest] in
            do {
                let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: audioPath)
                let startSample = max(0, Int(longest.start) * sampleRate)
                let endSample = min(samples.count, Int(longest.end) * sampleRate)
                guard startSample < endSample else { return }

                let snippet = Array(samples[startSample ..< endSample])
                let tmpPath = FileManager.default.temporaryDirectory
                    .appendingPathComponent("speaker_\(label).wav")
                try AudioMixer.saveWAV(samples: snippet, sampleRate: sampleRate, url: tmpPath)

                let newPlayer = try AVAudioPlayer(contentsOf: tmpPath)
                let duration = newPlayer.duration

                await MainActor.run {
                    player?.stop()
                    player = newPlayer
                    player?.play()
                    playingLabel = label
                }

                // Reset icon when done
                try? await Task.sleep(for: .seconds(duration + 0.1))
                await MainActor.run {
                    if playingLabel == label {
                        playingLabel = nil
                    }
                }
            } catch {
                // Silently fail — playback is best-effort
            }
        }
    }

    /// Participant names not yet assigned to any other speaker.
    private func unusedParticipants(currentIndex: Int) -> [String] {
        Self.unusedParticipants(currentIndex: currentIndex, names: names, participants: data.participants)
    }

    /// Known speaker names (from `speakers.json`) not in the meeting participant list
    /// and not already assigned to another row in this dialog.
    private func unusedKnownNames(currentIndex: Int) -> [String] {
        Self.unusedKnownNames(
            currentIndex: currentIndex,
            names: names,
            knownNames: knownSpeakerNames,
            participants: data.participants,
        )
    }

    private func confirm() {
        player?.stop()
        let mapping = Self.buildSpeakerMapping(speakers: speakers, names: names)
        onComplete(.confirmed(mapping))
    }

    // MARK: - Pure Functions (testable without UI)

    /// Computes initial text field names from speaker auto-name mappings.
    static func computeInitialNames(
        speakers: [(label: String, autoName: String?, speakingTime: Double)],
    ) -> [String] {
        speakers.map { $0.autoName ?? "" }
    }

    /// Names assigned to other rows (i.e. excluding `currentIndex`'s own value).
    /// Empty strings are ignored. Used to avoid suggesting a chip that's already
    /// in another row.
    private static func usedNamesExcluding(currentIndex: Int, names: [String]) -> Set<String> {
        Set(
            names.enumerated()
                .filter { $0.offset != currentIndex && !$0.element.isEmpty }
                .map(\.element),
        )
    }

    /// Returns participant names not yet assigned to any other speaker.
    static func unusedParticipants(
        currentIndex: Int, names: [String], participants: [String],
    ) -> [String] {
        let used = usedNamesExcluding(currentIndex: currentIndex, names: names)
        return participants.filter { !used.contains($0) }
    }

    /// Returns known names that are not already in the participant list (avoiding
    /// duplicate chips) and not yet assigned to another row.
    static func unusedKnownNames(
        currentIndex: Int, names: [String], knownNames: [String], participants: [String],
    ) -> [String] {
        let participantSet = Set(participants)
        let used = usedNamesExcluding(currentIndex: currentIndex, names: names)
        return knownNames.filter { !participantSet.contains($0) && !used.contains($0) }
    }

    private enum NameRelevance: Int, Comparable {
        case autoNameMatch = 0
        case participantMatch = 1
        case other = 2
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Sort known names by relevance for this row's "Known:" chips.
    /// Order:
    /// 1. Names whose first token matches the auto-name (case-insensitive).
    ///    e.g. autoName "Marwin" → "Marwin Schmidt", "Marwin Müller" first.
    /// 2. Names sharing a first token with any meeting participant.
    ///    e.g. participant "Anna Berger" → "Anna Klein" ranks up.
    /// 3. Remaining names in input order (caller already sorts alphabetically).
    /// Stable within each tier so the alphabetical input order from
    /// `SpeakerMatcher.allSpeakerNames()` is preserved.
    static func rankedKnownNames(
        known: [String], autoName: String?, participants: [String],
    ) -> [String] {
        let autoToken = (autoName.map(firstToken) ?? "").lowercased()
        let participantTokens = Set(participants.map { firstToken($0).lowercased() }.filter { !$0.isEmpty })

        func relevance(of name: String) -> NameRelevance {
            let token = firstToken(name).lowercased()
            if !autoToken.isEmpty, token == autoToken { return .autoNameMatch }
            if participantTokens.contains(token) { return .participantMatch }
            return .other
        }

        return known.enumerated()
            .map { (offset: $0.offset, relevance: relevance(of: $0.element), name: $0.element) }
            .sorted { lhs, rhs in
                if lhs.relevance != rhs.relevance { return lhs.relevance < rhs.relevance }
                return lhs.offset < rhs.offset
            }
            .map(\.name)
    }

    /// First space-separated token of a name (e.g. "Anna Berger" → "Anna").
    private static func firstToken(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Builds the speaker label → user-entered name mapping, skipping empty names.
    static func buildSpeakerMapping(
        speakers: [(label: String, autoName: String?, speakingTime: Double)],
        names: [String],
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        for (index, speaker) in speakers.enumerated() {
            let name = index < names.count
                ? names[index].trimmingCharacters(in: .whitespaces) : ""
            if !name.isEmpty {
                mapping[speaker.label] = name
            }
        }
        return mapping
    }
}

/// Layout that arranges its children left-to-right and wraps to a new row when
/// the row width is exhausted. Used for the suggestion-chip rows in
/// `SpeakerNamingView`, where a fixed-width HStack would either overflow or
/// truncate button labels when the speaker DB grows large.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0, x + size.width > containerWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        // Report the actual content width (capped at the container) so unconstrained
        // parents (proposal == .infinity) don't get an infinite frame.
        return CGSize(width: min(maxWidth, containerWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
