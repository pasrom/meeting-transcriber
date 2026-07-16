import SwiftUI

/// A small, clickable ⓘ that explains a settings option in a popover.
///
/// The bare `.help()` tooltips used elsewhere are invisible until hovered, so
/// non-expert users never discover them (issue #505). This gives an option a
/// visible affordance while still exposing the same text as a hover tooltip and
/// to VoiceOver.
///
/// Place it as a sibling of the option's label, not inside an interactive
/// control's label (see ``HelpfulToggle`` for why). For a plain row:
/// ```swift
/// HStack(spacing: 4) {
///     Text("Warn after:")
///     HelpBadge(text: SettingsHelp.someOption)
///     Slider(value: $seconds, in: 30 ... 300)
/// }
/// ```
/// For a toggle row, use ``HelpfulToggle``, which wires the badge in safely.
struct HelpBadge: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        // Show on hover (no click needed); the Button keeps click working for
        // touch / keyboard / VoiceOver, which a hover-only affordance can't reach.
        .onHover { showing = $0 }
        // `.help` still feeds the full text to VoiceOver (AXHelp) and is the
        // ViewInspector hook the tests match on (popover content isn't inspectable).
        .help(text)
        .accessibilityLabel("Help")
        // Keep the hint terse and action-describing (per HIG); the full
        // explanation is surfaced by the popover on activation/hover.
        .accessibilityHint("Shows an explanation of this setting")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                // fixedSize forces the text to take its full multi-line height;
                // without it the popover proposes a single line and truncates.
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding()
        }
    }
}

/// A settings `Toggle` with a trailing switch and an inline ``HelpBadge`` next
/// to its label.
///
/// The badge is a *sibling* of the toggle, not nested inside the toggle's label.
/// Nesting an interactive control in a `Toggle` label folds the button into the
/// toggle's single accessibility element, so VoiceOver can't focus the badge
/// separately (and on some macOS versions the toggle's label hit region can also
/// intercept the tap). Keeping it a sibling (mirroring the existing
/// `TuningHelpIcon` placement) keeps the badge separately focusable with its own
/// hit target.
struct HelpfulToggle: View {
    let title: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 4) {
            // The hidden Toggle label carries the accessibility name; this
            // visible copy is decorative, so keep it out of the a11y tree to
            // avoid announcing the title twice.
            Text(title)
                .accessibilityHidden(true)
            HelpBadge(text: help)
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
        }
        // Row-wide hover tooltip preserves the pre-badge behaviour for people
        // used to hovering the control; the badge stays the visible, clickable
        // affordance for everyone else.
        .help(help)
    }
}
