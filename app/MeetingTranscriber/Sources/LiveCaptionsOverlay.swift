import SwiftUI

/// Caption-bar content rendered inside `LiveCaptionsWindow` (a borderless,
/// status-bar-level NSPanel pinned to the bottom of the main screen).
///
/// Layout (top to bottom): up to `maxFinalsKept` recent finalised utterances
/// at full opacity, then the per-channel hypotheses at 60 % opacity. Each
/// row is prefixed with its speaker label — finals carry their own
/// `LiveCaptionLine.speaker` so a settings rename after commit doesn't
/// retroactively re-label them, while live hypotheses read the current
/// `LiveCaptionsState.micLabel` / `.appLabel`. When the state is empty the
/// rounded background collapses to a tiny pill — the wrapping panel uses
/// `hasContent` to hide entirely.
///
/// The content is bottom-anchored inside the fixed-size NSPanel (see
/// `LiveCaptionsWindowController`) so the bar visually grows upward as new
/// captions arrive instead of jittering top-down.
struct LiveCaptionsOverlay: View {
    @Bindable var state: LiveCaptionsState

    var body: some View {
        // TimelineView re-evaluates the opacity expression every 200 ms while
        // visible so the >2 s-silence fade is smooth without a manual timer.
        // It's gated behind `state.hasContent` so the timeline stops when the
        // bar is empty (idle bar → zero recurring work).
        VStack {
            Spacer(minLength: 0)
            if state.hasContent {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    content.opacity(state.opacity(at: context.date))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.15), value: state.hypothesisMic)
        .animation(.easeInOut(duration: 0.15), value: state.hypothesisApp)
        .animation(.easeInOut(duration: 0.15), value: state.recentFinals)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.recentFinals.suffix(LiveCaptionsState.maxFinalsKept), id: \.self) { line in
                row(speaker: line.speaker, text: line.text, opacity: 1.0)
            }
            if !state.hypothesisApp.isEmpty {
                row(speaker: state.appLabel, text: state.hypothesisApp, opacity: 0.6)
            }
            if !state.hypothesisMic.isEmpty {
                row(speaker: state.micLabel, text: state.hypothesisMic, opacity: 0.6)
            }
        }
        .font(.system(size: 22, weight: .medium, design: .rounded))
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    private func row(speaker: String, text: String, opacity: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(speaker + ":")
                .foregroundStyle(.white.opacity(min(opacity, 0.85)))
                .fontWeight(.semibold)
            Text(text)
                .foregroundStyle(.white.opacity(opacity))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
