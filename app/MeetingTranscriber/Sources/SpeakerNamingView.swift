import AVFoundation
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
    let onComplete: (PipelineQueue.SpeakerNamingResult) -> Void

    @State private var names: [String] = []
    @State private var completed = false
    @State private var player: AVAudioPlayer?
    @State private var playingLabel: String?
    @State private var rerunCount: Int = 2

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

    init(data: PipelineQueue.SpeakerNamingData, onComplete: @escaping (PipelineQueue.SpeakerNamingResult) -> Void) {
        self.data = data
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Name Speakers — \"\(data.meetingTitle)\"")
                .font(.headline)
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Array(speakers.enumerated()), id: \.element.label) { index, speaker in
                        speakerRow(index: index, speaker: speaker)
                    }
                }
            }
            .frame(height: min(CGFloat(speakers.count) * 120, 500))

            Divider()

            HStack(spacing: 8) {
                Text("Wrong count?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("\(rerunCount) speakers", value: $rerunCount, in: 1...10)
                    .font(.caption)
                    .accessibilityIdentifier("rerun-stepper")
                Button("Re-run") {
                    guard !completed else { return }
                    completed = true
                    player?.stop()
                    onComplete(.rerun(rerunCount))
                }
                .font(.caption)
                .accessibilityIdentifier("rerun-button")
            }

            HStack(spacing: 12) {
                Button("Skip") {
                    guard !completed else { return }
                    completed = true
                    onComplete(.skipped)
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
        .frame(minWidth: 400, maxHeight: 700)
        .id(data.meetingTitle)
        .onAppear {
            names = speakers.map { $0.autoName ?? "" }
            rerunCount = max(2, speakers.count + 1)
        }
        .onDisappear {
            if !completed {
                completed = true
                onComplete(.skipped)
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

                    if data.audioPath != nil {
                        Button {
                            playSpeakerSnippet(label: speaker.label)
                        } label: {
                            Image(systemName: playingLabel == speaker.label
                                  ? "stop.circle.fill" : "play.circle.fill")
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("play-\(speaker.label)")
                    }

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

                    if !unusedParticipants(currentIndex: index).isEmpty {
                        HStack(spacing: 4) {
                            ForEach(unusedParticipants(currentIndex: index), id: \.self) { name in
                                Button(name) {
                                    names[index] = name
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    /// Play the longest segment of a speaker from the audio file.
    private func playSpeakerSnippet(label: String) {
        // Stop if already playing this speaker
        if playingLabel == label {
            player?.stop()
            player = nil
            playingLabel = nil
            return
        }

        guard let audioPath = data.audioPath else { return }

        // Find the longest segment for this speaker
        let speakerSegments = data.segments.filter { $0.speaker == label }
        guard let longest = speakerSegments.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return }

        // Perform file I/O off the main thread
        Task.detached { [audioPath, longest] in
            do {
                let samples = try AudioMixer.loadAudioFileAsFloat32(url: audioPath)
                let audioFile = try AVAudioFile(forReading: audioPath)
                let sampleRate = Int(audioFile.processingFormat.sampleRate)
                let startSample = max(0, Int(longest.start) * sampleRate)
                let endSample = min(samples.count, Int(longest.end) * sampleRate)
                guard startSample < endSample else { return }

                let snippet = Array(samples[startSample..<endSample])
                let tmpPath = FileManager.default.temporaryDirectory
                    .appendingPathComponent("speaker_\(label).wav")
                try AudioMixer.saveWAV(samples: snippet, sampleRate: sampleRate, url: tmpPath)

                let newPlayer = try AVAudioPlayer(contentsOf: tmpPath)
                let duration = newPlayer.duration

                await MainActor.run {
                    player?.stop()
                    player = newPlayer
                    player?.play()
                    playingLabel = label
                }

                // Reset icon when done
                try? await Task.sleep(for: .seconds(duration + 0.1))
                await MainActor.run {
                    if playingLabel == label {
                        playingLabel = nil
                    }
                }
            } catch {
                // Silently fail — playback is best-effort
            }
        }
    }

    /// Participant names not yet assigned to any other speaker.
    private func unusedParticipants(currentIndex: Int) -> [String] {
        let usedNames = Set(
            names.enumerated()
                .filter { $0.offset != currentIndex && !$0.element.isEmpty }
                .map(\.element)
        )
        return data.participants.filter { !usedNames.contains($0) }
    }

    private func confirm() {
        player?.stop()
        var mapping: [String: String] = [:]
        for (index, speaker) in speakers.enumerated() {
            let name = index < names.count
                ? names[index].trimmingCharacters(in: .whitespaces) : ""
            if !name.isEmpty {
                mapping[speaker.label] = name
            }
        }
        onComplete(.confirmed(mapping))
    }
}
