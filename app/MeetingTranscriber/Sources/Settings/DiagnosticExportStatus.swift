import SwiftUI

/// What Settings → Advanced says after Export Diagnostics. An export that
/// found no recent entry still writes a file (the header plus a notice saying
/// why), so it is a success, but it must not read like a full one.
struct DiagnosticExportStatus: Equatable {
    enum Kind: Equatable {
        case exported
        case exportedWithoutEntries
        case failed
    }

    let kind: Kind
    let message: String

    /// `outcome` is what `DiagnosticExporter.export` returned: the number of
    /// entries written, or the error it threw.
    init(fileName: String, outcome: Result<Int, any Error>) {
        switch outcome {
        case let .success(entries) where entries > 0:
            kind = .exported
            message = "Exported to: \(fileName)"

        case .success:
            kind = .exportedWithoutEntries
            message = "Exported to: \(fileName). It holds no recent log entries; the file says why."

        case let .failure(error):
            kind = .failed
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// The one line under the Export Diagnostics button.
struct DiagnosticExportStatusText: View {
    let status: DiagnosticExportStatus

    var body: some View {
        Text(status.message)
            .font(.caption)
            .foregroundStyle(color)
            .accessibilityIdentifier(A11yID.diagnosticExportStatus)
    }

    private var color: Color {
        switch status.kind {
        case .exported: .secondary
        case .exportedWithoutEntries: .orange
        case .failed: .red
        }
    }
}
