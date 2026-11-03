import SwiftUI

/// The cloud endpoint's speech-to-text models for the Model dropdown, and
/// whether the user picked "Custom…". A reference type so a view test can
/// await the fetch and see the same state the view does (see
/// docs/architecture/gui-testing.md).
@MainActor
@Observable
final class CloudModelList {
    /// Empty until a fetch returns models; the Model row is a text field until then.
    private(set) var models: [String] = []
    private(set) var isFetching = false
    /// Why the last fetch failed; nil after a success.
    private(set) var failure: String?
    /// "Custom…" chosen, so the text field shows even for a listed model.
    var customChosen = false
    private let session: URLSession
    /// The fetch in flight, kept so a view test can await it.
    private(set) var task: Task<Void, Never>?
    /// Advanced by `invalidate`, so a fetch from the previous endpoint cannot
    /// fill the list for the one that replaced it.
    private var generation = 0

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// GETs `{baseURL}/models` with the key as a Bearer token. A redirect off
    /// the configured origin is refused, so the key goes nowhere else.
    func fetch(baseURL: String, apiKey: String) {
        guard !isFetching else { return }
        isFetching = true
        failure = nil
        let started = generation
        task = Task {
            let result = await OpenAIProtocolGenerator.testConnection(
                endpoint: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: "",
                apiKey: apiKey.isEmpty ? nil : apiKey,
                refuseCrossOriginRedirects: true,
                session: session,
            )
            guard started == generation else { return }
            switch result {
            case let .success(ids):
                models = Self.speechModels(ids)

            case let .failure(error):
                models = []
                failure = "Couldn't fetch models: \(error.localizedDescription)"
            }
            isFetching = false
        }
    }

    /// The endpoint or key changed: the list was the previous endpoint's.
    func invalidate() {
        generation += 1
        models = []
        failure = nil
        isFetching = false
    }

    /// The ids that look like speech-to-text, in the given order; all of them
    /// when none does, so a wrong guess hides nothing.
    static func speechModels(_ ids: [String]) -> [String] {
        let speech = ids.filter { id in
            let lowered = id.lowercased()
            return speechMarkers.contains { lowered.contains($0) }
        }
        return speech.isEmpty ? ids : speech
    }

    private static let speechMarkers = ["whisper", "transcribe", "asr", "stt"]
}

/// What the Model dropdown shows as selected.
enum CloudModelChoice: Hashable {
    case listed(String)
    case custom
}

/// The cloud Model row: a text field until the server's list arrives, then a
/// dropdown of it plus "Custom…", which adds a "Model ID" field row below it.
/// A saved model the list lacks shows as Custom, unchanged.
struct CloudModelRow: View {
    @Bindable var settings: AppSettings
    var drafts: CloudEndpointDrafts
    var modelList: CloudModelList
    /// The connection result described the previous model.
    var onModelChange: () -> Void = {}

    var body: some View {
        Group {
            if modelList.models.isEmpty {
                modelField(label: "Model")
            } else {
                modelPicker
                if choice.wrappedValue == .custom {
                    modelField(label: "Model ID")
                }
            }
            fetchRow
        }
        .onAppear {
            drafts.load(from: settings)
            guard !drafts.hasChanges, modelList.models.isEmpty, !modelList.isFetching else { return }
            let baseURL = settings.cloudTranscriptionBaseURL
            let apiKey = settings.cloudTranscriptionAPIKey
            if !baseURL.isEmpty, !apiKey.isEmpty {
                modelList.fetch(baseURL: baseURL, apiKey: apiKey)
            }
        }
    }

    /// Every model write goes through here, so the connection result is
    /// dropped as the model changes.
    private func setModel(_ model: String) {
        guard model != settings.cloudTranscriptionModel else { return }
        settings.cloudTranscriptionModel = model
        onModelChange()
    }

    private var modelPicker: some View {
        Picker("Model", selection: choice) {
            ForEach(modelList.models, id: \.self) { model in
                Text(model).tag(CloudModelChoice.listed(model))
            }
            Text("Custom…").tag(CloudModelChoice.custom)
        }
        .accessibilityIdentifier(A11yID.cloudTranscriptionModelPicker)
    }

    private func modelField(label: String) -> some View {
        TextField(label, text: Binding(get: { settings.cloudTranscriptionModel }, set: setModel), prompt: Text("whisper-1"))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.cloudTranscriptionModelField)
    }

    private var choice: Binding<CloudModelChoice> {
        Binding(
            get: {
                let model = settings.cloudTranscriptionModel
                return modelList.customChosen || !modelList.models.contains(model) ? .custom : .listed(model)
            },
            set: { newValue in
                switch newValue {
                case let .listed(model):
                    modelList.customChosen = false
                    setModel(model)

                case .custom:
                    modelList.customChosen = true
                }
            },
        )
    }

    private var fetchRow: some View {
        HStack {
            Button {
                fetch()
            } label: {
                HStack(spacing: 4) {
                    if modelList.isFetching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(modelList.models.isEmpty ? "Fetch Models" : "Refresh Models")
                }
            }
            .disabled(modelList.isFetching)
            .accessibilityIdentifier(A11yID.cloudTranscriptionFetchModelsButton)

            if let failure = modelList.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(A11yID.cloudTranscriptionModelsFailure)
            }
        }
    }

    private func fetch() {
        modelList.fetch(baseURL: drafts.baseURL, apiKey: drafts.apiKey)
    }
}
