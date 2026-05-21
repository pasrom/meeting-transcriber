import SwiftUI

/// Caption-bar content rendered inside `LiveCaptionsWindow` (a borderless,
/// status-bar-level NSPanel pinned to the bottom of the main screen).
///
/// Layout: the most recent finalised utterance on top (white, full opacity)
/// followed by the live hypothesis (60 % opacity) on the next line. When the
/// hypothesis is empty the row collapses. When everything is empty the view
/// renders nothing — the surrounding panel uses
/// `LiveCaptionsState.hasContent` to decide whether to be visible at all.
///
/// The content is bottom-anchored inside the fixed-size NSPanel (see
/// `LiveCaptionsWindowController`) so the bar visually grows upward as new
/// captions arrive instead of jittering top-down.
struct LiveCaptionsOverlay: View {
    @Bindable var state: LiveCaptionsState

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if state.hasContent {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.15), value: state.hypothesis)
        .animation(.easeInOut(duration: 0.15), value: state.recentFinals)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.recentFinals.suffix(LiveCaptionsState.maxFinalsKept), id: \.self) { line in
                Text(line)
                    .foregroundStyle(.white)
            }
            if !state.hypothesis.isEmpty {
                Text(state.hypothesis)
                    .foregroundStyle(.white.opacity(0.6))
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
}
