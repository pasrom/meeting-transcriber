import SwiftUI

struct SpeakersSettingsView: View {
    @Bindable var settings: AppSettings
    var recognitionStatsLog: RecognitionStatsLog
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

    @State private var showKnownVoices = false
    /// SpeakerMatcher.init reads + decodes speakers.json — must not run
    /// per body re-evaluation, so the matcher is created lazily on tap.
    @State private var sheetMatcher: SpeakerMatcher?
    @State private var experimentalTuningExpanded = false

    var body: some View {
        // swiftlint:disable:next closure_body_length
        Form {
            Section("Diarization") {
                Toggle("Speaker Diarization", isOn: $settings.diarize)

                if settings.diarize {
                    Picker("Diarizer", selection: $settings.diarizerMode) {
                        ForEach(DiarizerMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if settings.diarizerMode == .sortformer {
                        Label(
                            "Sortformer supports up to 4 speakers per meeting. Switch to Offline mode for meetings with more participants.",
                            systemImage: "info.circle",
                        )
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }

                    HStack {
                        Text("Expected Speakers")
                        Spacer()
                        Text(settings.numSpeakers == 0 ? "Auto" : "\(settings.numSpeakers)")
                            .frame(width: 40)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $settings.numSpeakers, in: 0 ... 10)
                            .labelsHidden()
                    }

                    if settings.diarizerMode == .offline {
                        experimentalTuningDisclosure
                    }
                }
            }
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
                    sheetMatcher = matcherFactory()
                    showKnownVoices = true
                }
                Text("Rename, delete, or merge entries in your speaker DB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RecognitionStatsView(log: recognitionStatsLog)
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showKnownVoices) {
            if let matcher = sheetMatcher {
                KnownVoicesView(
                    matcher: matcher,
                    diarizerFactory: enrollmentDiarizerFactory,
                    namingDialogActive: namingDialogActive,
                    pipelineBusy: pipelineBusy,
                    onMutate: onSpeakerMutate,
                )
            }
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
        help: "Euclidean distance threshold for clustering speaker embeddings. Lower values split speakers more aggressively.",
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
