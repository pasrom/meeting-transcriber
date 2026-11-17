import SwiftUI

/// The selected OpenAI-compatible connection's endpoint and API key, with its
/// rarely changed request options (key placement, sampling overrides) in a
/// collapsed Advanced group.
struct OpenAIConnectionSection: View {
    @Bindable var settings: AppSettings
    @ObservedObject var apiKeyDrafts: ProtocolAPIKeyDrafts
    @State private var advanced: OpenAIAdvancedDisclosure
    @State private var hoveringAdvanced = false

    init(
        settings: AppSettings,
        apiKeyDrafts: ProtocolAPIKeyDrafts,
        advanced: OpenAIAdvancedDisclosure = OpenAIAdvancedDisclosure(),
    ) {
        self.settings = settings
        self.apiKeyDrafts = apiKeyDrafts
        _advanced = State(initialValue: advanced)
    }

    var body: some View {
        Section {
            HStack {
                Text("Endpoint")
                Spacer()
                TextField("", text: $settings.openAIEndpoint, prompt: Text(verbatim: "http://localhost:1234/v1"))
                    .frame(width: OutputSettingsView.fieldWidth)
                    .accessibilityIdentifier(A11yID.openAIEndpointField)
            }

            HStack {
                Text("API Key")
                Spacer()
                DraftTextField("", value: apiKeyDrafts.savedOpenAI, draft: $apiKeyDrafts.openAI, secure: true) { key in
                    apiKeyDrafts.commitOpenAI(key, to: settings)
                }
                .frame(width: OutputSettingsView.fieldWidth)
                .accessibilityIdentifier(A11yID.openAIAPIKeyField)
            }

            advancedToggle

            // Plain rows rather than a DisclosureGroup, whose nested rows lose
            // the form's row padding and separators.
            if advanced.isExpanded(headerNameInvalid: headerNameInvalid) {
                Group {
                    advancedRows
                }
                .padding(.leading, 18)
            }
        } header: {
            HStack(spacing: 4) {
                Text("Connection Settings")
                HelpBadge(text: SettingsHelp.openAIConnection, systemImage: "questionmark.circle")
            }
        }
    }

    /// The whole row toggles, and highlights under the pointer so it reads as clickable.
    private var advancedToggle: some View {
        let expanded = advanced.isExpanded(headerNameInvalid: headerNameInvalid)
        return Button {
            // Rows appear at once, so the page has its final height before it scrolls;
            // only closing animates.
            if expanded {
                withAnimation(.easeInOut(duration: 0.15)) { advanced.toggle(headerNameInvalid: headerNameInvalid) }
            } else {
                advanced.toggle(headerNameInvalid: headerNameInvalid)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Advanced")
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoveringAdvanced ? Color.primary.opacity(0.08) : .clear),
            )
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringAdvanced = $0 }
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(A11yID.openAIAdvancedToggle)
    }

    @ViewBuilder
    private var advancedRows: some View { // swiftlint:disable:this attributes
        Picker("Authentication", selection: latchingOpen($settings.openAIAPIKeyPlacement)) {
            ForEach(OpenAIAPIKeyPlacement.allCases, id: \.self) { placement in
                Text(placement.label).tag(placement)
            }
        }
        .accessibilityIdentifier(A11yID.openAIAPIKeyPlacementPicker)

        if settings.openAIAPIKeyPlacement == .customHeader {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Header Name")
                    Spacer()
                    TextField("", text: latchingOpen($settings.openAIAPIKeyHeaderName))
                        .frame(width: OutputSettingsView.fieldWidth)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier(A11yID.openAIAPIKeyHeaderNameField)
                }
                if headerNameInvalid {
                    Text("Enter a valid HTTP header name. Content-Type, Content-Length, Host and other connection-level headers are reserved.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(A11yID.openAIAPIKeyHeaderNameWarning)
                }
            }
        }

        SamplingOverrideRow(
            parameter: .temperature,
            value: $settings.openAITemperature,
            toggleID: A11yID.openAITemperatureToggle,
            valueID: A11yID.openAITemperatureValue,
        )
        SamplingOverrideRow(
            parameter: .topP,
            value: $settings.openAITopP,
            toggleID: A11yID.openAITopPToggle,
            valueID: A11yID.openAITopPValue,
            scrollPending: advanced.scrollPending,
            onScrolled: advanced.scrollHandled,
        )
    }

    /// Editing a row inside Advanced keeps it open, so fixing an invalid header
    /// name does not close the group under the cursor.
    private func latchingOpen<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                advanced.isOpen = true
                binding.wrappedValue = value
            },
        )
    }

    private var headerNameInvalid: Bool {
        settings.openAIAPIKeyPlacement == .customHeader
            && !OpenAIProtocolGenerator.isValidAPIKeyHeaderName(
                settings.openAIAPIKeyHeaderName.trimmingCharacters(in: .whitespacesAndNewlines),
            )
    }
}

/// One optional sampling override: a toggle that switches it on and, while it
/// is on, a field and stepper for the value. Switching it off clears the value,
/// so the parameter is left out of the request and the server default applies.
private struct SamplingOverrideRow: View {
    let parameter: OpenAISamplingParameter
    @Binding var value: Double?
    let toggleID: String
    let valueID: String
    /// While set, this row's last line scrolls into view, then `onScrolled` runs.
    var scrollPending = false
    var onScrolled: () -> Void = {}

    var body: some View {
        Toggle("Override \(parameter.label)", isOn: isOverridden)
            .accessibilityIdentifier(toggleID)
            .background(value == nil ? scrollAnchor : nil)

        if value != nil {
            HStack {
                Text(parameter.label)
                Spacer()
                TextField(parameter.label, value: currentValue, format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper(parameter.label, value: currentValue, in: parameter.range, step: 0.05)
                    .labelsHidden()
            }
            // A container element, so the identifier names the row instead
            // of being copied onto the label, field and stepper inside it.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(valueID)
            .background(scrollAnchor)
        }
    }

    private var scrollAnchor: ScrollIntoViewWhenPending {
        ScrollIntoViewWhenPending(pending: scrollPending, onScrolled: onScrolled)
    }

    private var isOverridden: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { value = $0 ? OpenAISamplingParameter.initialOverride : nil },
        )
    }

    private var currentValue: Binding<Double> {
        Binding(
            // The row only renders while overridden; the fallback just makes it total.
            get: { value ?? OpenAISamplingParameter.initialOverride },
            set: { value = $0 },
        )
    }
}

/// Scrolls the enclosing scroll view by the least amount that brings this
/// row into view while `pending` is set, including when the row is created
/// with it set, as the Advanced rows are. `ScrollViewReader.scrollTo` left the
/// grouped `Form` unscrolled on macOS 27, so this drives AppKit directly.
private struct ScrollIntoViewWhenPending: NSViewRepresentable {
    let pending: Bool
    let onScrolled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard pending, !context.coordinator.scheduled else { return }
        context.coordinator.scheduled = true
        // On the next pass, after the new rows are laid out.
        DispatchQueue.main.async { [weak nsView, onScrolled, coordinator = context.coordinator] in
            nsView.map(Self.glideIntoView)
            coordinator.scheduled = false
            onScrolled()
        }
    }

    private static func glideIntoView(_ row: NSView) {
        guard let scrollView = row.enclosingScrollView, let document = scrollView.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let rowRect = clip.convert(row.bounds, from: row)
        let target = clip.constrainBoundsRect(
            NSRect(origin: originRevealing(rowRect, in: clip.bounds, flipped: clip.isFlipped), size: clip.bounds.size),
        ).origin
        guard target != clip.bounds.origin else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// The visible origin moved down only as far as needed for the bottom of
    /// `rect` to show; a row already in view leaves it where it is.
    private static func originRevealing(_ rect: NSRect, in visible: NSRect, flipped: Bool) -> NSPoint {
        var origin = visible.origin
        if flipped {
            if rect.maxY > visible.maxY { origin.y += rect.maxY - visible.maxY }
        } else if rect.minY < visible.minY {
            origin.y -= visible.minY - rect.minY
        }
        return origin
    }

    final class Coordinator {
        var scheduled = false
    }
}

/// Whether the Advanced group of `OpenAIConnectionSection` is open.
///
/// A reference type so a test holds the object the Advanced button writes to
/// (see `docs/architecture/gui-testing.md`).
@Observable
@MainActor
final class OpenAIAdvancedDisclosure {
    var isOpen: Bool
    /// Set when the user opens the group, until its new rows have scrolled into view.
    private(set) var scrollPending = false

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    /// An invalid header name shows the group, so its warning stays in view.
    func isExpanded(headerNameInvalid: Bool) -> Bool {
        isOpen || headerNameInvalid
    }

    /// While the header name is invalid the group cannot close; a click then
    /// latches it open, so it stays open once the name is fixed.
    func toggle(headerNameInvalid: Bool) {
        if headerNameInvalid {
            isOpen = true
        } else if isOpen {
            isOpen = false
            scrollPending = false
        } else {
            isOpen = true
            scrollPending = true
        }
    }

    func scrollHandled() {
        scrollPending = false
    }
}
