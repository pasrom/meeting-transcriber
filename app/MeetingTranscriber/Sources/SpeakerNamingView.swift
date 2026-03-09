import SwiftUI

/// NSTextField subclass that forwards accessibility `set value` (AppleScript)
/// to the delegate so the SwiftUI Binding stays in sync.
private final class AutomationTextField: NSTextField {
    override func setAccessibilityValue(_ value: Any?) {
        if let str = value as? String {
            self.stringValue = str
            // Post the same notification that user typing would trigger
            NotificationCenter.default.post(
                name: NSControl.textDidChangeNotification,
                object: self
            )
        }
    }
}

/// NSTextField wrapper that syncs accessibility `set value` to the Binding.
/// Standard SwiftUI TextField ignores programmatic accessibility value changes
/// (e.g. from AppleScript `set value of text field`), which breaks UI automation.
struct AccessibleTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var identifier: String

    func makeNSView(context: Context) -> NSTextField {
        let field = AutomationTextField()
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(identifier)
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Format seconds as "Xs" or "M:SS".
func formattedTime(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return m > 0 ? "\(m):\(String(format: "%02d", s))" : "\(s)s"
}

/// Window that lets the user name speakers after diarization.
struct SpeakerNamingView: View {
    let data: PipelineQueue.SpeakerNamingData
    let onComplete: ([String: String]) -> Void

    @State private var names: [String] = []
    @State private var completed = false

    private var speakers: [(label: String, autoName: String?, speakingTime: Double)] {
        data.mapping.keys.sorted().map { label in
            let autoName = data.mapping[label]
            let isAutoNamed = autoName != nil && autoName != label
            return (
                label: label,
                autoName: isAutoNamed ? autoName : nil,
                speakingTime: data.speakingTimes[label] ?? 0
            )
        }
    }

    init(data: PipelineQueue.SpeakerNamingData, onComplete: @escaping ([String: String]) -> Void) {
        self.data = data
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Name Speakers — \"\(data.meetingTitle)\"")
                .font(.headline)
                .padding(.top, 8)

            ForEach(Array(speakers.enumerated()), id: \.element.label) { index, speaker in
                speakerRow(index: index, speaker: speaker)
            }

            HStack(spacing: 12) {
                Button("Skip") {
                    guard !completed else { return }
                    completed = true
                    onComplete([:])
                }
                .keyboardShortcut(.escape)
                .accessibilityIdentifier("skip-button")

                Button("Confirm") {
                    guard !completed else { return }
                    completed = true
                    confirm()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("confirm-button")
            }
            .padding(.bottom, 8)
        }
        .padding()
        .frame(minWidth: 400)
        .id(data.meetingTitle)
        .onAppear {
            names = speakers.map { $0.autoName ?? "" }
        }
        .onDisappear {
            if !completed {
                completed = true
                onComplete([:])
            }
        }
    }

    @ViewBuilder
    private func speakerRow(
        index: Int,
        speaker: (label: String, autoName: String?, speakingTime: Double)
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(speaker.label)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text("(\(formattedTime(speaker.speakingTime)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let autoName = speaker.autoName {
                    Text("Auto: \(autoName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if index < names.count {
                    AccessibleTextField(
                        text: $names[index],
                        placeholder: "Name",
                        identifier: "speaker-name-\(speaker.label)"
                    )
                }
            }
            .padding(4)
        }
    }

    private func confirm() {
        var mapping: [String: String] = [:]
        for (index, speaker) in speakers.enumerated() {
            let name = index < names.count
                ? names[index].trimmingCharacters(in: .whitespaces) : ""
            if !name.isEmpty {
                mapping[speaker.label] = name
            }
        }
        onComplete(mapping)
    }
}
