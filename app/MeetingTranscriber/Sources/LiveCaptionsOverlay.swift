import AppKit
import SwiftUI

/// Caption-bar content rendered inside `LiveCaptionsWindow` (a borderless,
/// status-bar-level NSPanel pinned to the bottom of the main screen).
///
/// Layout (top to bottom): one row per run of recent finalised lines of one
/// channel and speaker, the open hypotheses continuing their channel's row
/// (see `rows`). Finals
/// carry their own per-line `LiveCaptionLine.speaker` (resolved by
/// `LiveSpeakerMatcher` for that line) so a `speakers.json` rename after
/// the line is committed doesn't retroactively re-label it. A hypothesis
/// continues the preceding row if it is on the same channel, or uses the
/// channel-default `LiveCaptionsState.micLabel` / `.appLabel` otherwise.
/// When the state is empty the rounded background collapses to a tiny pill;
/// the wrapping panel uses `hasContent` to hide entirely.
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
        let rows = Self.rows(
            finals: state.recentFinals,
            awaiting: state.awaitsSpeaker(lineAt:),
            voiceHint: state.voiceHint(for:),
            hypotheses: [(.app, state.hypothesisApp), (.mic, state.hypothesisMic)],
            label: state.label(for:),
        )
        return VStack(alignment: .leading, spacing: 4) {
            if state.isDetectingLanguage {
                Text("Detecting language…")
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let backend = state.activeBackend {
                Text(backend)
                    .font(.system(size: state.size.labelFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityIdentifier(A11yID.liveCaptionBackend)
            }
            // Keyed by position: a row that grows or is relabelled keeps its view, so its text does not cross-fade.
            ForEach(rows.indices, id: \.self) { index in
                row(speaker: rows[index].speaker, text: rows[index].text)
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

    struct Row: Equatable {
        let channel: LiveCaptionChannel
        let speaker: String
        var text: String
    }

    /// Consecutive finals of one channel and speaker share a row, and a hypothesis or a final still
    /// awaiting its speaker continues the row before it when that row is on its channel, unless the
    /// voice change detector heard another voice take over that channel.
    static func rows(
        finals: [LiveCaptionLine],
        awaiting: (Int) -> Bool = { _ in false },
        voiceHint: (LiveCaptionChannel) -> String? = { _ in nil },
        hypotheses: [(LiveCaptionChannel, String)],
        label: (LiveCaptionChannel) -> String,
    ) -> [Row] {
        var rows: [Row] = []
        func add(_ channel: LiveCaptionChannel, _ speaker: String, _ text: String) {
            if let last = rows.last, last.channel == channel, last.speaker == speaker {
                rows[rows.count - 1].text += " " + text
            } else {
                rows.append(Row(channel: channel, speaker: speaker, text: text))
            }
        }
        for (index, line) in finals.enumerated() {
            // Under the channel label until its match lands, it flashed a row of its own.
            if awaiting(index), line.speaker == label(line.channel), let last = rows.last, last.channel == line.channel {
                rows[rows.count - 1].text += " " + line.text
            } else {
                add(line.channel, line.speaker, line.text)
            }
        }
        for (channel, text) in hypotheses where !text.isEmpty {
            if let voice = voiceHint(channel) {
                add(channel, voice, text)
            } else if let last = rows.last, last.channel == channel {
                // Unmatched yet, so it continues the bottom row when that row is on its channel; under the
                // channel label it stood in a row of its own below every named row.
                rows[rows.count - 1].text += " " + text
            } else {
                add(channel, label(channel), text)
            }
        }
        return rows
    }

    private func row(speaker: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(speaker + ":")
                .foregroundStyle(.white.opacity(0.85))
                .fontWeight(.semibold)
                .lineLimit(1)
                .layoutPriority(1)
            // Bound each row too, so a long mic row cannot push the app row out of the bar.
            LiveCaptionTextClip(maxHeight: 2 * Self.lineHeight(fontSize: state.size.fontSize)) {
                Text(text)
                    .foregroundStyle(.white)
                    // New words swap in at once; only the position eases, so a full line slides out the top.
                    .contentTransition(.identity)
            }
            .clipped()
            .animation(.easeOut(duration: 0.2), value: text)
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
