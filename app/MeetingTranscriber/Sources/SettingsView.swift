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

    @State private var selection: SettingsTab = .general

    var body: some View {
        if #available(macOS 13, *) {
            splitView
        } else {
            tabContent
        }
    }

    @available(macOS 13, *)
    private var splitView: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                Label(tab.label, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailView(for: selection)
        }
        .navigationTitle("Settings")
        .frame(
            minWidth: 760,
            idealWidth: 860,
            maxWidth: 1000,
            minHeight: 520,
            idealHeight: 640,
            maxHeight: .infinity,
        )
    }

    @ViewBuilder
    private func detailView(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(settings: settings, updateChecker: updateChecker)

        case .audio:
            AudioSettingsView(settings: settings)

        case .transcription:
            TranscriptionSettingsView(
                settings: settings,
                whisperKitEngine: whisperKitEngine,
                parakeetEngine: parakeetEngine,
                qwen3Engine: qwen3Engine,
            )

        case .speakers:
            SpeakersSettingsView(
                settings: settings,
                recognitionStatsLog: recognitionStatsLog,
                enrollmentDiarizerFactory: enrollmentDiarizerFactory,
                namingDialogActive: namingDialogActive,
                pipelineBusy: pipelineBusy,
            )

        case .output:
            OutputSettingsView(settings: settings)

        case .advanced:
            AdvancedSettingsView(settings: settings)
        }
    }

    private var tabContent: some View {
        TabView(selection: $selection) {
            ForEach(SettingsTab.allCases) { tab in
                detailView(for: tab)
                    .tabItem { Label(tab.label, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .frame(
            minWidth: 760,
            idealWidth: 860,
            maxWidth: 1000,
            minHeight: 520,
            idealHeight: 640,
            maxHeight: .infinity,
        )
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, audio, transcription, speakers, output, advanced

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .general: "General"
        case .audio: "Audio"
        case .transcription: "Transcription"
        case .speakers: "Speakers"
        case .output: "Output"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .audio: "mic"
        case .transcription: "waveform"
        case .speakers: "person.2"
        case .output: "doc.text"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}
