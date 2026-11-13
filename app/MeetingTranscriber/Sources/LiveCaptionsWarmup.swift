import SwiftUI

/// The live-caption model warm-up, as Settings, the menu and `/state` show it.
enum LiveCaptionsWarmup: Equatable {
    /// No controller: captions are off or not available.
    case idle
    /// With the time the controller was built, which the Settings line counts from.
    case preparing(since: Date)
    case ready
    /// No caption backend loaded, with the load error.
    case failed(String)

    /// `/state.liveCaptions.warmup`.
    var name: String {
        switch self {
        case .idle: "none"
        case .preparing: "preparing"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }

    var failureReason: String? {
        if case let .failed(reason) = self { return reason }
        return nil
    }

    static let preparingMenuText = "Preparing live captions\u{2026}"

    /// The status line under the live-captions toggle; nil shows none.
    var settingsText: String? {
        switch self {
        case .idle: nil
        case .preparing: "\(Self.preparingMenuText) (loading the model can take a minute or more)"
        case .ready: "Live captions ready"
        case let .failed(reason): "Live captions unavailable: \(reason)\nTurn live captions off and on to retry."
        }
    }
}

/// The warm-up status line under the live-captions toggle in Settings.
struct CaptionWarmupStatus: View {
    let warmup: LiveCaptionsWarmup

    /// Styled as the engine's "Loading model..." and "Model ready" rows above it.
    var body: some View {
        if let text = warmup.settingsText {
            switch warmup {
            case .ready:
                Label(text, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .accessibilityIdentifier(A11yID.liveCaptionsWarmupStatus)

            default:
                HStack {
                    // The model compile reports no progress, so this only says it is still running.
                    if warmup.isPreparing {
                        ProgressView().controlSize(.small)
                    }
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(warmup.failureReason == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(A11yID.liveCaptionsWarmupStatus)
                    if case let .preparing(since) = warmup {
                        // Counts up by itself; says how long this warm-up has run.
                        Text(since, style: .timer)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(A11yID.liveCaptionsWarmupElapsed)
                    }
                }
            }
        }
    }
}
