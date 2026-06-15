import SwiftUI

/// Identifiable wrapper letting the Known Voices sheet use `.sheet(item:)`.
/// A fresh `id` per presentation means each open carries its own matcher.
private struct KnownVoicesSheetItem: Identifiable {
    let id = UUID()
    let matcher: SpeakerMatcher
}

struct SpeakersSettingsView: View {
    @Bindable var settings: AppSettings
    var recognitionStatsLog: RecognitionStatsLog
    var stageTimingLog: StageTimingLog
    var enrollmentDiarizerFactory: (() -> any DiarizationProvider)?
    var namingDialogActive: Bool
    var pipelineBusy: Bool
    /// Called whenever the user mutates the speakers DB from the Known
    /// Voices sheet (rename / delete / merge). Used to refresh
    /// `PipelineQueue.knownSpeakerNames` so the next naming dialog sees
    /// up-to-date chips. Optional — tests and the parent that doesn't
    /// own a PipelineQueue can omit.
    var onSpeakerMutate: (() -> Void)?
    var matcherFactory: () -> SpeakerMatcher = { SpeakerMatcher() }

    /// Holds the lazily-created matcher while the Known Voices sheet is up.
    /// `SpeakerMatcher.init` reads + decodes speakers.json, so it must not run
    /// per body re-evaluation — it's built on tap. Drives the sheet via
    /// `.sheet(item:)` rather than `isPresented` + `if let`: item-presentation
    /// fires only once the matcher exists and hands it in unwrapped, avoiding
    /// the SwiftUI race where the first present snapshots a still-nil matcher
    /// and shows an empty window (worked only on the second tap).
    @State private var knownVoicesSheet: KnownVoicesSheetItem?
    @State private var experimentalTuningExpanded = false

    /// Stepper range for `numSpeakers` given the active diarizer mode.
    /// Upper bound from `DiarizerMode.speakerCap` (single source of truth
    /// shared with the SpeakerNamingView re-run UI). 0 = Auto.
    static func speakerCountRange(for mode: DiarizerMode) -> ClosedRange<Int> {
        0 ... mode.speakerCap
    }

    /// Clamp a desired `numSpeakers` to the cap that applies for the given
    /// mode. 0 = Auto stays 0. Pure so unit tests can pin behaviour.
    static func clampSpeakerCount(_ count: Int, for mode: DiarizerMode) -> Int {
        guard count > 0 else { return 0 }
        return min(count, mode.speakerCap)
    }

    var body: some View {
        Form {
            diarizationSection
                .accessibilityIdentifier("diarizationSection")
                .recordOnlyDisabled(settings.recordOnly)

            if !settings.noMic {
                Section("Speaker Identity") {
                    HStack {
                        Text("Mic Speaker Name")
                        Spacer()
                        TextField("Me", text: $settings.micName)
                            .frame(width: 160)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Your name for dual-source mode. Leave empty to diarize mic track (multi-person room).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .recordOnlyDisabled(settings.recordOnly)
            }

            Section("Known Voices") {
                Button("Manage\u{2026}") {
                    knownVoicesSheet = KnownVoicesSheetItem(matcher: matcherFactory())
                }
                Text("Rename, delete, or merge entries in your speaker DB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RecognitionStatsView(log: recognitionStatsLog)

            ProcessingStatsView(log: stageTimingLog)
        }
        .formStyle(.grouped)
        .sheet(item: $knownVoicesSheet) { item in
            KnownVoicesView(
                matcher: item.matcher,
                diarizerFactory: enrollmentDiarizerFactory,
                namingDialogActive: namingDialogActive,
                pipelineBusy: pipelineBusy,
                onMutate: onSpeakerMutate,
            )
        }
    }

    // MARK: - Diarization Section

    private var diarizationSection: some View {
        Section("Diarization") {
            Toggle("Speaker Diarization", isOn: $settings.diarize)
            if settings.diarize {
                diarizationModePicker
                if settings.diarizerMode == .sortformer {
                    Label(
                        "Sortformer supports up to \(DiarizerMode.sortformer.speakerCap) speakers per meeting. Switch to Offline mode for meetings with more participants.",
                        systemImage: "info.circle",
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
                expectedSpeakersRow
                Label(
                    "Auto detects the count; a fixed value forces exactly that many speakers (and over-splits a smaller meeting).",
                    systemImage: "info.circle",
                )
                .foregroundStyle(.secondary)
                .font(.caption)
                if settings.diarizerMode == .offline {
                    experimentalTuningDisclosure
                }
            }
        }
    }

    private var diarizationModePicker: some View {
        Picker("Diarizer", selection: $settings.diarizerMode) {
            ForEach(DiarizerMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: settings.diarizerMode) { _, newMode in
            // Clamp K to the new mode's cap so the value visible in the
            // Stepper agrees with what the diarizer will actually honour.
            settings.numSpeakers = Self.clampSpeakerCount(settings.numSpeakers, for: newMode)
        }
    }

    private var expectedSpeakersRow: some View {
        HStack {
            Text("Expected Speakers")
            Spacer()
            Text(settings.numSpeakers == 0 ? "Auto" : "\(settings.numSpeakers)")
                .frame(width: 40)
                .multilineTextAlignment(.trailing)
            Stepper(
                "",
                value: $settings.numSpeakers,
                in: Self.speakerCountRange(for: settings.diarizerMode),
            )
            .labelsHidden()
        }
    }

    // MARK: - Experimental Tuning

    private var experimentalTuningDisclosure: some View {
        DisclosureGroup(isExpanded: $experimentalTuningExpanded) {
            tuningDisclosureBody
        } label: {
            tuningDisclosureLabel
        }
        .accessibilityIdentifier("experimentalTuningDisclosure")
    }

    private var tuningDisclosureLabel: some View {
        HStack(spacing: 4) {
            Text("Experimental: Diarization Tuning")
            if !settings.diarizerTuningIsAllDefaults {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Non-default tuning active")
            }
        }
    }

    private var tuningDisclosureBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            tuningWarningBanner
            TuningSliderRow(knob: .clusterThreshold, value: $settings.clusterThreshold)
            TuningSliderRow(knob: .warmStartFa, value: $settings.warmStartFa)
            TuningSliderRow(knob: .warmStartFb, value: $settings.warmStartFb)
            TuningSliderRow(knob: .minSegmentDuration, value: $settings.minSegmentDurationSeconds)
            HStack {
                Toggle("Exclude overlap", isOn: $settings.excludeOverlap)
                TuningHelpIcon(
                    tooltip: "When enabled, frames with multiple active speakers are masked out during embedding extraction.",
                )
                Spacer()
            }
            Button("Reset to defaults") {
                settings.resetDiarizerTuning()
            }
            .disabled(settings.diarizerTuningIsAllDefaults)
        }
        .padding(.top, 4)
    }

    private var tuningWarningBanner: some View {
        Label(
            "Changing these values may degrade diarization quality. Use with caution and reset if unsure.",
            systemImage: "exclamationmark.triangle.fill",
        )
        .foregroundColor(.red)
        .font(.caption)
        .padding(.vertical, 4)
    }
}

// MARK: - Tuning slider helpers

/// Static description of a single experimental tuning knob — keeps the
/// per-knob configuration (range, step, format, label, help text) out of
/// the SwiftUI body so it stays easy to read and lint-friendly.
private struct TuningKnob {
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    let suffix: String
    let help: String

    static let clusterThreshold = Self(
        title: "Cluster threshold",
        range: 0.0 ... 1.0,
        step: 0.05,
        format: "%.2f",
        suffix: "",
        help: "Cosine-similarity threshold for merging speaker embeddings. Higher values split speakers more aggressively (more speakers detected).",
    )

    static let warmStartFa = Self(
        title: "Warm-start Fa",
        range: 0.0 ... 1.0,
        step: 0.01,
        format: "%.2f",
        suffix: "",
        help: "VBx warm-start Fa controls clustering precision. Increasing it tightens speaker boundaries.",
    )

    static let warmStartFb = Self(
        title: "Warm-start Fb",
        range: 0.0 ... 2.0,
        step: 0.05,
        format: "%.2f",
        suffix: "",
        help: "VBx warm-start Fb controls clustering recall. Increasing it merges similar speakers more readily.",
    )

    static let minSegmentDuration = Self(
        title: "Min segment duration",
        range: 0.0 ... 5.0,
        step: 0.1,
        format: "%.1f",
        suffix: "s",
        help: "Skip embedding extraction for segments shorter than this duration. Larger values trade recall for stability.",
    )
}

private struct TuningSliderRow: View {
    let knob: TuningKnob
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(knob.title)
                TuningHelpIcon(tooltip: knob.help)
                Spacer()
                Text("\(String(format: knob.format, value))\(knob.suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: knob.range, step: knob.step)
        }
    }
}

private struct TuningHelpIcon: View {
    let tooltip: String

    var body: some View {
        Image(systemName: "questionmark.circle")
            .foregroundStyle(.secondary)
            .help(tooltip)
    }
}
