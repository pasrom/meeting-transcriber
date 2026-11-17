import SwiftUI

/// The selected OpenAI-compatible connection's endpoint and API key, followed
/// by its rarely changed request options (key placement, sampling overrides).
struct OpenAIConnectionSection: View {
    @Bindable var settings: AppSettings
    @ObservedObject var apiKeyDrafts: ProtocolAPIKeyDrafts

    var body: some View {
        Section {
            HStack {
                Text("Endpoint")
                Spacer()
                TextField("", text: $settings.openAIEndpoint, prompt: Text(verbatim: "http://localhost:1234/v1"))
                    .frame(width: OutputSettingsView.fieldWidth)
                    .accessibilityIdentifier(A11yID.openAIEndpointField)
            }

            HStack {
                Text("API Key")
                Spacer()
                DraftTextField("", value: apiKeyDrafts.savedOpenAI, draft: $apiKeyDrafts.openAI, secure: true) { key in
                    apiKeyDrafts.commitOpenAI(key, to: settings)
                }
                .frame(width: OutputSettingsView.fieldWidth)
                .accessibilityIdentifier(A11yID.openAIAPIKeyField)
            }

            advancedRows
        } header: {
            HStack(spacing: 4) {
                Text("Connection Settings")
                HelpBadge(text: SettingsHelp.openAIConnection, systemImage: "questionmark.circle")
            }
        }
    }

    @ViewBuilder
    private var advancedRows: some View { // swiftlint:disable:this attributes
        Picker("Authentication", selection: $settings.openAIAPIKeyPlacement) {
            ForEach(OpenAIAPIKeyPlacement.allCases, id: \.self) { placement in
                Text(placement.label).tag(placement)
            }
        }
        .accessibilityIdentifier(A11yID.openAIAPIKeyPlacementPicker)

        if settings.openAIAPIKeyPlacement == .customHeader {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Header Name")
                    Spacer()
                    TextField("", text: $settings.openAIAPIKeyHeaderName)
                        .frame(width: OutputSettingsView.fieldWidth)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier(A11yID.openAIAPIKeyHeaderNameField)
                }
                if headerNameInvalid {
                    Text("Enter a valid HTTP header name. Content-Type, Content-Length, Host and other connection-level headers are reserved.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(A11yID.openAIAPIKeyHeaderNameWarning)
                }
            }
        }

        SamplingOverrideRow(
            parameter: .temperature,
            value: $settings.openAITemperature,
            toggleID: A11yID.openAITemperatureToggle,
            valueID: A11yID.openAITemperatureValue,
        )
        SamplingOverrideRow(
            parameter: .topP,
            value: $settings.openAITopP,
            toggleID: A11yID.openAITopPToggle,
            valueID: A11yID.openAITopPValue,
        )
    }

    private var headerNameInvalid: Bool {
        settings.openAIAPIKeyPlacement == .customHeader
            && !OpenAIProtocolGenerator.isValidAPIKeyHeaderName(
                settings.openAIAPIKeyHeaderName.trimmingCharacters(in: .whitespacesAndNewlines),
            )
    }
}

/// One optional sampling override: a toggle that switches it on and, while it
/// is on, a field and stepper for the value. Switching it off clears the value,
/// so the parameter is left out of the request and the server default applies.
private struct SamplingOverrideRow: View {
    let parameter: OpenAISamplingParameter
    @Binding var value: Double?
    let toggleID: String
    let valueID: String

    var body: some View {
        Toggle("Override \(parameter.label)", isOn: isOverridden)
            .accessibilityIdentifier(toggleID)

        if value != nil {
            HStack {
                Text(parameter.label)
                Spacer()
                TextField(parameter.label, value: currentValue, format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper(parameter.label, value: currentValue, in: parameter.range, step: 0.05)
                    .labelsHidden()
            }
            // A container element, so the identifier names the row instead
            // of being copied onto the label, field and stepper inside it.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(valueID)
        }
    }

    private var isOverridden: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { value = $0 ? OpenAISamplingParameter.initialOverride : nil },
        )
    }

    private var currentValue: Binding<Double> {
        Binding(
            // The row only renders while overridden; the fallback just makes it total.
            get: { value ?? OpenAISamplingParameter.initialOverride },
            set: { value = $0 },
        )
    }
}
