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

            EchoSection(settings: settings)

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
        .accessibilityIdentifier(A11yID.vadSection)
        .recordOnlyDisabled(settings.recordOnly)
    }
}

/// Its own section rather than a row inside the VAD one: the VAD threshold
/// slider sits directly under whatever shares that section, and a threshold
/// row reading as if it tuned the echo removal is exactly the knob this
/// feature refuses to have.
private struct EchoSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("Echo") {
            HelpfulToggle(
                title: "Remove echoed remote speech from the transcript",
                help: SettingsHelp.echoDedup,
                isOn: $settings.echoDedupEnabled,
            )
            .accessibilityIdentifier(A11yID.echoDedupToggle)
        }
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

            // Shown whether or not the toggle above is on. The toggle decides
            // whether the menu bar turns red; this number decides how long a
            // channel must be failing before you are told about it, and that
            // reporting happens either way. Hiding it with the toggle left a
            // setting that still applied and could no longer be seen or changed.
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
        }
        .accessibilityIdentifier(A11yID.channelIndicatorSection)
    }
}
