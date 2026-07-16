import AVFoundation
import SwiftUI

struct AudioSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var audioDevices: [(id: String, name: String)] = []

    var body: some View {
        Form {
            Section("Microphone") {
                Toggle("No Microphone (app audio only)", isOn: $settings.noMic)

                if !settings.noMic {
                    Picker("Microphone", selection: $settings.micDeviceUID) {
                        Text("System Default").tag("")
                        ForEach(audioDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .onAppear { refreshAudioDevices() }
                }
            }

            VoiceActivityDetectionSection(settings: settings)

            PerChannelIndicatorSection(settings: settings)
        }
        .formStyle(.grouped)
    }

    private func refreshAudioDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified,
        )
        audioDevices = session.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }
}

private struct VoiceActivityDetectionSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("Voice Activity Detection") {
            HelpfulToggle(
                title: "Voice Activity Detection (VAD)",
                help: SettingsHelp.vad,
                isOn: $settings.vadEnabled,
            )

            if settings.vadEnabled {
                HStack {
                    Text("Threshold:")
                    Slider(value: $settings.vadThreshold, in: 0.3 ... 0.9, step: 0.05)
                    Text(String(format: "%.2f", settings.vadThreshold))
                        .monospacedDigit()
                        .frame(width: 35)
                }
            }
        }
        .accessibilityIdentifier("vadSection")
        .recordOnlyDisabled(settings.recordOnly)
    }
}

private struct PerChannelIndicatorSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("Per-Channel Indicator") {
            HelpfulToggle(
                title: "Detect Silent Capture Channel",
                help: SettingsHelp.silentCaptureChannel,
                isOn: $settings.perChannelIndicatorEnabled,
            )

            if settings.perChannelIndicatorEnabled {
                HStack {
                    Text("Warn after:")
                    HelpBadge(text: SettingsHelp.asymmetricSilenceWarning)
                    Slider(
                        value: $settings.asymmetricSilenceWarningSeconds,
                        in: 30 ... 300,
                        step: 10,
                    )
                    Text("\(Int(settings.asymmetricSilenceWarningSeconds))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                .help(SettingsHelp.asymmetricSilenceWarning)
            }
        }
        .accessibilityIdentifier("channelIndicatorSection")
    }
}
