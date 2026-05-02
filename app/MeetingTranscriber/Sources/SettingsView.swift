import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var whisperKitEngine: WhisperKitEngine
    var parakeetEngine: ParakeetEngine
    var qwen3Engine: (any TranscribingEngine)? // nil on macOS < 15
    var updateChecker: UpdateChecker?
    var recognitionStatsLog: RecognitionStatsLog = .init()
    /// Factory for the voice-enrollment diarizer. nil → enroll button hidden.
    var enrollmentDiarizerFactory: (() -> DiarizationProvider)?
    /// True when a meeting is currently waiting on a naming dialog. We gate
    /// the enroll button to avoid two `SpeakerNamingView` instances.
    var namingDialogActive: Bool = false
    /// True when the pipeline is processing a job — soft hint only.
    var pipelineBusy: Bool = false

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings, updateChecker: updateChecker)
                .tabItem { Label("General", systemImage: "gear") }

            AudioSettingsView(settings: settings)
                .tabItem { Label("Audio", systemImage: "mic") }

            TranscriptionSettingsView(
                settings: settings,
                whisperKitEngine: whisperKitEngine,
                parakeetEngine: parakeetEngine,
                qwen3Engine: qwen3Engine,
            )
            .tabItem { Label("Transcription", systemImage: "waveform") }

            SpeakersSettingsView(
                settings: settings,
                recognitionStatsLog: recognitionStatsLog,
                enrollmentDiarizerFactory: enrollmentDiarizerFactory,
                namingDialogActive: namingDialogActive,
                pipelineBusy: pipelineBusy,
            )
            .tabItem { Label("Speakers", systemImage: "person.2") }

            OutputSettingsView(settings: settings)
                .tabItem { Label("Output", systemImage: "doc.text") }

            AdvancedSettingsView(settings: settings)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(
            minWidth: 620,
            idealWidth: 720,
            maxWidth: 900,
            minHeight: 480,
            idealHeight: 600,
            maxHeight: .infinity,
        )
    }
}
