import SwiftUI

/// A small, clickable ⓘ that explains a settings option in a popover.
///
/// The bare `.help()` tooltips used elsewhere are invisible until hovered, so
/// non-expert users never discover them (issue #505). This gives an option a
/// visible affordance instead, and it is the ONE place the explanation appears:
/// a `.help()` alongside it renders the same paragraph a second time on top of
/// the popover, because both fire on hover.
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
        .accessibilityLabel("Help")
        // Terse and action-describing, per HIG, and deliberately NOT the whole
        // explanation. Carrying the full text here was tried and is wrong twice
        // over: a hint is spoken in full on every focus with no way to skim,
        // and it is suppressible (VoiceOver Verbosity, "Speak hints"), so the
        // explanation would be read out unasked to the people who leave hints
        // on and be gone entirely for the people who switch them off. The
        // popover's `Text` is an ordinary accessible element and carries the
        // explanation for everyone.
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
/// intercept the tap). Keeping it a sibling keeps the badge separately
/// focusable with its own hit target.
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
    }
}
