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

            Section("Voice Activity Detection") {
                Toggle("Voice Activity Detection (VAD)", isOn: $settings.vadEnabled)
                    .help("Remove silence before transcription for better results")

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

private struct PerChannelIndicatorSection: View {
    @Bindable var settings: AppSettings

    private static let toggleHelp =
        "Turn the menu bar red when one capture channel goes silent while the other still carries audio. " +
        "Catches asymmetric capture failures (muted mic, dropped app-audio tap) in real time."

    private static let sliderHelp =
        "Continuous asymmetric silence required before the indicator and notification fire. " +
        "Short enough to surface a dead channel during a meeting, long enough to ignore speaking pauses."

    var body: some View {
        Section("Per-Channel Indicator") {
            Toggle("Detect Silent Capture Channel", isOn: $settings.perChannelIndicatorEnabled)
                .help(Self.toggleHelp)

            if settings.perChannelIndicatorEnabled {
                HStack {
                    Text("Warn after:")
                    Slider(
                        value: $settings.asymmetricSilenceWarningSeconds,
                        in: 30 ... 300,
                        step: 10,
                    )
                    Text("\(Int(settings.asymmetricSilenceWarningSeconds))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                .help(Self.sliderHelp)
            }
        }
        .accessibilityIdentifier("channelIndicatorSection")
    }
}
