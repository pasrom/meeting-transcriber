import SwiftUI

struct SpeakersSettingsView: View {
    @Bindable var settings: AppSettings
    var recognitionStatsLog: RecognitionStatsLog
    var enrollmentDiarizerFactory: (() -> DiarizationProvider)?
    var namingDialogActive: Bool
    var pipelineBusy: Bool
    /// Called whenever the user mutates the speakers DB from the Known
    /// Voices sheet (rename / delete / merge). Used to refresh
    /// `PipelineQueue.knownSpeakerNames` so the next naming dialog sees
    /// up-to-date chips. Optional — tests and the parent that doesn't
    /// own a PipelineQueue can omit.
    var onSpeakerMutate: (() -> Void)?

    @State private var showKnownVoices = false

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
                            "Sortformer does not identify recurring speakers — speaker naming and auto-recognition are disabled.",
                            systemImage: "exclamationmark.triangle.fill",
                        )
                        .foregroundStyle(.orange)
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
                Button("Manage\u{2026}") { showKnownVoices = true }
                Text("Rename, delete, or merge entries in your speaker DB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RecognitionStatsView(log: recognitionStatsLog)
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showKnownVoices) {
            KnownVoicesView(
                matcher: SpeakerMatcher(),
                diarizerFactory: enrollmentDiarizerFactory,
                namingDialogActive: namingDialogActive,
                pipelineBusy: pipelineBusy,
                onMutate: onSpeakerMutate,
            )
        }
    }
}
