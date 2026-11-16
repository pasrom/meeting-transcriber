import SwiftUI

/// The storage-limit rows of Settings → Output → Recording Retention.
struct RecordingStorageLimitRows: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Toggle("Limit recording storage", isOn: $settings.recordingStorageLimitEnabled)
            .accessibilityIdentifier(A11yID.recordingStorageLimitToggle)

        HStack {
            Text("Storage limit")
            Spacer()
            Text("\(settings.recordingStorageLimitGB) GB")
                .foregroundStyle(.secondary)
            Stepper("", value: $settings.recordingStorageLimitGB, in: 1 ... 10000)
                .labelsHidden()
        }
        .disabled(!settings.recordingStorageLimitEnabled)

        Text(
            "When the recordings this app keeps use more than the limit, you get a notification. "
                + "24 hours later the oldest recordings are deleted until they fit. The same rules as above "
                + "decide which recordings can go: meeting notes saved, and only audio this app recorded.",
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
