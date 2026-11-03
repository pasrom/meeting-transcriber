import SwiftUI

/// Whether the cloud-transcription consent alert is up. A reference type so
/// the alert's actions and a view test see the same flag (see
/// docs/architecture/gui-testing.md).
@MainActor
@Observable
final class CloudTranscriptionConsent {
    var isAsking = false

    /// The toggle's write: switching on asks first until the user has
    /// confirmed once; switching off never asks.
    func request(_ enabled: Bool, in settings: AppSettings) {
        if enabled, !settings.cloudTranscriptionConsented {
            isAsking = true
        } else {
            settings.cloudTranscriptionEnabled = enabled
        }
    }

    func confirm(in settings: AppSettings) {
        settings.cloudTranscriptionConsented = true
        settings.cloudTranscriptionEnabled = true
        isAsking = false
    }

    func cancel() {
        isAsking = false
    }
}

/// "Transcribe in the cloud" and its endpoint fields, above the local engine
/// picker, which stays selected for when cloud is off.
struct CloudTranscriptionControls: View {
    @Bindable var settings: AppSettings
    @Bindable var consent: CloudTranscriptionConsent

    var body: some View {
        Toggle("Transcribe in the cloud", isOn: Binding(
            get: { settings.cloudTranscriptionEnabled },
            set: { consent.request($0, in: settings) },
        ))
        .accessibilityIdentifier(A11yID.cloudTranscriptionToggle)
        .alert("Send meeting audio to the cloud?", isPresented: $consent.isAsking) {
            Button("Cancel", role: .cancel) { consent.cancel() }
            Button("Send to Cloud") { consent.confirm(in: settings) }
        } message: {
            Text(
                "Recordings queued while this is on are uploaded to "
                    + "\(Self.host(of: settings.cloudTranscriptionBaseURL)) for transcription. "
                    + "Speaker identification stays on this Mac.",
            )
        }

        if settings.cloudTranscriptionEnabled {
            Text("Meeting audio is sent to \(Self.host(of: settings.cloudTranscriptionBaseURL)).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(A11yID.cloudTranscriptionHostNote)
            TextField("Base URL", text: $settings.cloudTranscriptionBaseURL, prompt: Text("https://api.openai.com/v1"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(A11yID.cloudTranscriptionBaseURLField)
            TextField("Model", text: $settings.cloudTranscriptionModel, prompt: Text("whisper-1"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(A11yID.cloudTranscriptionModelField)
            SecureField("API key", text: $settings.cloudTranscriptionAPIKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(A11yID.cloudTranscriptionAPIKeyField)
        }
    }

    /// The host part of the base URL, or the entry itself when it has none.
    static func host(of baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)?.host ?? trimmed
    }
}
