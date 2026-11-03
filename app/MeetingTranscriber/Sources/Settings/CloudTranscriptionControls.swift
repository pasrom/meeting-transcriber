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

/// Test Connection's state; a reference type for the same reason as
/// `CloudTranscriptionConsent`.
@MainActor
@Observable
final class CloudConnectionTest {
    private(set) var isRunning = false
    private(set) var result: CloudConnectionTestResult?
    private let session: URLSession
    /// The test in flight, kept so a view test can await it.
    private(set) var task: Task<Void, Never>?
    /// Advanced by `invalidate`, so a test started before an edit cannot
    /// report on the configuration that replaced it.
    private var generation = 0

    init(session: URLSession = .shared) {
        self.session = session
    }

    func run(_ config: CloudTranscriptionConfiguration) {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        let started = generation
        task = Task {
            let outcome = await CloudTranscriptionEngine.testConnection(config, session: session)
            guard started == generation else { return }
            result = outcome
            isRunning = false
        }
    }

    /// The endpoint, key or model changed: the last result says nothing about it.
    func invalidate() {
        generation += 1
        result = nil
        isRunning = false
    }
}

/// "Transcribe in the cloud" and its endpoint fields, above the local engine
/// picker, which stays selected for when cloud is off.
struct CloudTranscriptionControls: View {
    @Bindable var settings: AppSettings
    @Bindable var consent: CloudTranscriptionConsent
    var connectionTest: CloudConnectionTest
    var drafts: CloudEndpointDrafts

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
            TextField("Base URL", text: endpointDraft(\.baseURL), prompt: Text("https://api.openai.com/v1"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(A11yID.cloudTranscriptionBaseURLField)
                .onAppear { drafts.load(from: settings) }
            TextField("Model", text: $settings.cloudTranscriptionModel, prompt: Text("whisper-1"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(A11yID.cloudTranscriptionModelField)
            SecureField("API key", text: endpointDraft(\.apiKey))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(A11yID.cloudTranscriptionAPIKeyField)
            saveRow
            connectionTestRow
        }
    }

    /// A draft field's binding; an edit invalidates what described the old value.
    private func endpointDraft(_ keyPath: ReferenceWritableKeyPath<CloudEndpointDrafts, String>) -> Binding<String> {
        Binding(
            get: { drafts[keyPath: keyPath] },
            set: { newValue in
                guard newValue != drafts[keyPath: keyPath] else { return }
                drafts[keyPath: keyPath] = newValue
                connectionTest.invalidate()
            },
        )
    }

    private var saveRow: some View {
        HStack {
            Button("Save") { drafts.save(to: settings) }
                .disabled(!drafts.hasChanges)
                .accessibilityIdentifier(A11yID.cloudTranscriptionSaveButton)
            if drafts.hasChanges {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(A11yID.cloudTranscriptionUnsavedNote)
            }
        }
    }

    private var connectionTestRow: some View {
        HStack {
            Button {
                connectionTest.run(drafts.configuration(from: settings))
            } label: {
                HStack(spacing: 4) {
                    if connectionTest.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Test Connection")
                }
            }
            .disabled(connectionTest.isRunning)
            .accessibilityIdentifier(A11yID.cloudTranscriptionTestButton)

            if let result = connectionTest.result {
                Label(result.message, systemImage: result == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result == .success ? .green : .red)
                    .font(.caption)
                    .accessibilityIdentifier(A11yID.cloudTranscriptionTestStatus)
            }
        }
    }

    /// The host part of the base URL, or the entry itself when it has none.
    static func host(of baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)?.host ?? trimmed
    }
}
