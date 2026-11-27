import SwiftUI

/// Whether the cloud-transcription consent alert is up. A reference type so
/// the alert's actions and a view test see the same flag (see
/// docs/architecture/gui-testing.md).
@MainActor
@Observable
final class CloudTranscriptionConsent {
    var isAsking = false

    /// The "Transcribe with" write: picking Cloud asks first until the user has
    /// confirmed once; Local never asks.
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

/// The two choices of "Transcribe with". UI only: the stored settings stay
/// `cloudTranscriptionEnabled` plus the local engine, which stays selected for
/// Run Locally and for when cloud is off.
enum TranscriptionMethod: CaseIterable {
    case onThisMac
    case cloud

    var label: String {
        switch self {
        case .onThisMac: "Local"
        case .cloud: "Cloud"
        }
    }
}

/// "Transcribe with": picking Cloud asks for consent first until the user has
/// confirmed once; Cancel leaves it on Local.
struct TranscriptionMethodPicker: View {
    @Bindable var settings: AppSettings
    @Bindable var consent: CloudTranscriptionConsent

    var body: some View {
        Picker("Transcribe with", selection: Binding(
            get: { settings.cloudTranscriptionEnabled ? TranscriptionMethod.cloud : .onThisMac },
            set: { consent.request($0 == .cloud, in: settings) },
        )) {
            ForEach(TranscriptionMethod.allCases, id: \.self) { method in
                Text(method.label).tag(method)
            }
        }
        .accessibilityIdentifier(A11yID.transcriptionMethodPicker)
        .alert("Send meeting audio to the cloud?", isPresented: $consent.isAsking) {
            Button("Cancel", role: .cancel) { consent.cancel() }
            Button("Send to Cloud") { consent.confirm(in: settings) }
        } message: {
            Text(
                "Recordings queued while this is on are uploaded to "
                    + "\(CloudTranscriptionControls.host(of: settings.cloudTranscriptionBaseURL)) for transcription. "
                    + "Speaker identification stays on this Mac.",
            )
        }
    }
}

/// The rows "Transcribe with: Cloud" shows: endpoint fields, the cloud
/// language and the local model Run Locally falls back to. Base URL and key
/// are drafts until Save (`CloudEndpointDrafts`); an edit to either, or to the
/// model or language, drops the connection result and (for the endpoint) the
/// model list that described the previous values.
struct CloudTranscriptionControls: View {
    @Bindable var settings: AppSettings
    var drafts: CloudEndpointDrafts
    var connectionTest: CloudConnectionTest
    var modelList: CloudModelList
    /// e.g. "Run Locally uses WhisperKit · Large V3 Turbo".
    var localFallback: String

    var body: some View {
        Text("Meeting audio is sent to \(Self.host(of: settings.cloudTranscriptionBaseURL)).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(A11yID.cloudTranscriptionHostNote)
            .onAppear { drafts.load(from: settings) }
        TextField("Base URL", text: endpointDraft(\.baseURL), prompt: Text("https://api.openai.com/v1"))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.cloudTranscriptionBaseURLField)
        CloudModelRow(settings: settings, drafts: drafts, modelList: modelList, onModelChange: connectionTest.invalidate)
        SecureField("API key", text: endpointDraft(\.apiKey))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.cloudTranscriptionAPIKeyField)
        saveRow
        connectionTestRow
        Picker("Language", selection: Binding(
            get: { settings.cloudTranscriptionLanguage },
            set: { newValue in
                guard newValue != settings.cloudTranscriptionLanguage else { return }
                settings.cloudTranscriptionLanguage = newValue
                connectionTest.invalidate()
            },
        )) {
            ForEach(PickerLanguages.whisperKit, id: \.code) { lang in
                Text(lang.label).tag(lang.code)
            }
        }
        .accessibilityIdentifier(A11yID.cloudTranscriptionLanguagePicker)
        Text(localFallback)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(A11yID.cloudTranscriptionLocalFallbackNote)
    }

    /// A draft field's binding; an edit invalidates what described the old value.
    private func endpointDraft(_ keyPath: ReferenceWritableKeyPath<CloudEndpointDrafts, String>) -> Binding<String> {
        Binding(
            get: { drafts[keyPath: keyPath] },
            set: { newValue in
                guard newValue != drafts[keyPath: keyPath] else { return }
                drafts[keyPath: keyPath] = newValue
                connectionTest.invalidate()
                modelList.invalidate()
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
