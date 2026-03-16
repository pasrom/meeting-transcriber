import SwiftUI

/// A row showing permission status with a colored icon, info popover, and click-to-open Settings.
struct PermissionRow: View {
    let label: String
    let detail: String
    var granted: Bool
    var warning: Bool = false
    var optional: Bool = false
    var help: String = ""
    var settingsURL: String = ""
    @State private var showingHelp = false

    private var icon: String {
        if granted { return "checkmark.circle.fill" }
        if warning || optional { return "exclamationmark.triangle.fill" }
        return "xmark.circle.fill"
    }

    private var iconColor: Color {
        if granted { return .green }
        if warning || optional { return .orange }
        return .red
    }

    var body: some View {
        // swiftlint:disable:next closure_body_length
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !help.isEmpty {
                Button {
                    showingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(help)
                            .font(.callout)
                        if !settingsURL.isEmpty {
                            Button("Open System Settings") {
                                if let url = URL(string: settingsURL) {
                                    NSWorkspace.shared.open(url)
                                }
                                showingHelp = false
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }
}
