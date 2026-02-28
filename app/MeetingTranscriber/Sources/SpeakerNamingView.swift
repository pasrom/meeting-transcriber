import AVFoundation
import SwiftUI

/// Window that lets the user name speakers after diarization.
struct SpeakerNamingView: View {
    let request: SpeakerRequest
    let onComplete: ([String: String]) -> Void

    @State private var names: [String]
    @State private var audioPlayer: AVAudioPlayer?

    init(request: SpeakerRequest, onComplete: @escaping ([String: String]) -> Void) {
        self.request = request
        self.onComplete = onComplete
        // Pre-fill with auto-detected names
        _names = State(initialValue: request.speakers.map { $0.autoName ?? "" })
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Name Speakers — \"\(request.meetingTitle)\"")
                .font(.headline)
                .padding(.top, 8)

            ForEach(Array(request.speakers.enumerated()), id: \.element.id) { index, speaker in
                speakerRow(index: index, speaker: speaker)
            }

            HStack(spacing: 12) {
                Button("Skip") {
                    onComplete([:])
                }
                .keyboardShortcut(.escape)

                Button("Confirm") {
                    confirm()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 8)
        }
        .padding()
        .frame(minWidth: 400)
    }

    @ViewBuilder
    private func speakerRow(index: Int, speaker: SpeakerInfo) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(speaker.label)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text("(\(formattedTime(speaker.speakingTimeSeconds)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let autoName = speaker.autoName {
                    Text("Auto: \(autoName) (\(Int(speaker.confidence * 100))%)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        playSample(speaker: speaker)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .controlSize(.small)

                    TextField("Name", text: $names[index])
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(4)
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m > 0 ? "\(m):\(String(format: "%02d", s))" : "\(s)s"
    }

    private func playSample(speaker: SpeakerInfo) {
        let dir = (request.audioSamplesDir as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: dir)
            .appendingPathComponent(speaker.sampleFile)

        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
        } catch {
            print("Failed to play sample: \(error)")
        }
    }

    private func confirm() {
        var mapping: [String: String] = [:]
        for (index, speaker) in request.speakers.enumerated() {
            let name = names[index].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                mapping[speaker.label] = name
            }
        }
        onComplete(mapping)
    }
}
