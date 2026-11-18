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
                .accessibilityIdentifier(A11yID.recordingStorageLimitStepper)
        }
        .disabled(!settings.recordingStorageLimitEnabled)

        if settings.recordingStorageLimitEnabled, let status = settings.recordingStorageStatus {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.statusLines(status, now: Date()), id: \.self) { Text($0) }
            }
            .font(.caption)
            .accessibilityIdentifier(A11yID.recordingStorageStatus)
        }

        Text(
            "When the recordings this app keeps use more than the limit, you get a notification. "
                + "24 hours later, the oldest recordings whose notes were saved before the notification are "
                + "deleted until they fit; a recording whose notes are saved later, also after a retry, is "
                + "only deleted after a notification of its own. The same rules as above decide which "
                + "recordings can go: meeting notes saved, and only audio this app recorded. Recordings "
                + "that cannot go yet still count toward the limit.",
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The usage line, and the pending deletion while a warning is stored.
    static func statusLines(_ status: RecordingStorageStatus, now: Date) -> [String] {
        let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .decimal) }
        var usage = "Recordings use \(size(status.totalBytes))"
        if status.keptBytes > 0 { usage += ", \(size(status.keptBytes)) of it cannot be deleted yet" }
        guard let warning = status.warning else { return [usage + "."] }
        let date = { (instant: Date) in instant.formatted(date: .abbreviated, time: .shortened) }
        let deletion = now >= warning.deletesFrom
            ? "are being deleted, oldest first, until they fit."
            : "are deleted from \(date(warning.deletesFrom)), oldest first, until they fit."
        return [
            usage + ".",
            "Over the limit since \(date(warning.since)). Recordings whose notes were saved by then " + deletion,
        ]
    }
}
