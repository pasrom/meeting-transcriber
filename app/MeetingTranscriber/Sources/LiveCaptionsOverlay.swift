import AppKit
import SwiftUI

/// Caption-bar content rendered inside `LiveCaptionsWindow` (a borderless,
/// status-bar-level NSPanel pinned to the bottom of the main screen).
///
/// Layout (top to bottom): up to `maxFinalsKept` recent finalised utterances,
/// the older at 60 % opacity and the newest at full opacity, then the
/// per-channel hypotheses at full opacity. Finals
/// carry their own per-line `LiveCaptionLine.speaker` (resolved by
/// `LiveSpeakerMatcher` for that line) so a `speakers.json` rename after
/// the line is committed doesn't retroactively re-label it. Live hypothesis
/// rows fall back to the channel-default `LiveCaptionsState.micLabel` /
/// `.appLabel` because the partial transcript hasn't reached its end-of-
/// speech boundary yet and no embedding is available. When the state is
/// empty the rounded background collapses to a tiny pill — the wrapping
/// panel uses `hasContent` to hide entirely.
///
/// The content is bottom-anchored inside the fixed-size NSPanel (see
/// `LiveCaptionsWindowController`) so the bar visually grows upward as new
/// captions arrive instead of jittering top-down; past the panel's height
/// the oldest lines clip at the top.
struct LiveCaptionsOverlay: View {
    @Bindable var state: LiveCaptionsState

    var body: some View {
        // An overlay doesn't pass its content's height up, so overflow clips
        // the oldest lines at the top instead of centring and cutting off the newest.
        Color.clear
            .overlay(alignment: .bottom) {
                if state.hasContent {
                    content
                        .opacity(state.faded ? 0 : 1)
                        .animation(
                            state.faded
                                ? .linear(duration: LiveCaptionsState.fadeDuration)
                                : nil,
                            value: state.faded,
                        )
                }
            }
            // Not keyed on the hypotheses: a cross-fade on each partial overlaid old and new words.
            .animation(.easeInOut(duration: 0.15), value: state.recentFinals)
    }

    private var content: some View {
        let finals = state.recentFinals.suffix(LiveCaptionsState.maxFinalsKept)
        return VStack(alignment: .leading, spacing: 4) {
            if let backend = state.activeBackend {
                Text(backend)
                    .font(.system(size: state.size.labelFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityIdentifier(A11yID.liveCaptionBackend)
            }
            ForEach(Array(finals.enumerated()), id: \.element) { index, line in
                // The newest final is often still being read, so only older ones dim.
                row(speaker: line.speaker, text: line.text, opacity: index == finals.count - 1 ? 1.0 : 0.6)
            }
            if !state.hypothesisApp.isEmpty {
                row(speaker: state.appLabel, text: state.hypothesisApp, opacity: 1.0)
            }
            if !state.hypothesisMic.isEmpty {
                row(speaker: state.micLabel, text: state.hypothesisMic, opacity: 1.0)
            }
        }
        .font(.system(size: state.size.fontSize, weight: .medium, design: .rounded))
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: LiveCaptionsContentFrameKey.self, value: proxy.frame(in: .global))
        })
    }

    private func row(speaker: String, text: String, opacity: Double) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(speaker + ":")
                .foregroundStyle(.white.opacity(min(opacity, 0.85)))
                .fontWeight(.semibold)
                .lineLimit(1)
                .layoutPriority(1)
            // Bound each channel too, so a long mic row cannot push the app row out of the bar.
            LiveCaptionTextClip(maxHeight: 2 * Self.lineHeight(fontSize: state.size.fontSize)) {
                Text(text)
                    .foregroundStyle(.white)
                    .opacity(opacity)
            }
            .clipped()
        }
    }

    /// Line pitch of the row font, which SwiftUI rounds up to whole points (19 / 26 / 33 pt at
    /// small / medium / large). A clip off this pitch shows a strip of the hidden line's descenders.
    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let medium = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let font = medium.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: fontSize) } ?? medium
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }
}

/// Takes its content's height up to `maxHeight`, never more, and keeps the
/// content's bottom edge, so overflow leaves at the top.
struct LiveCaptionTextClip: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: min(size.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY),
            anchor: .bottomLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil),
        )
    }
}

/// The caption box's frame in the hosting view, so tests can see which end clips.
struct LiveCaptionsContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
