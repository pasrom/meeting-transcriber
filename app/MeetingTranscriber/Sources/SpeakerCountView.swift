import SwiftUI

/// Dialog that asks the user how many speakers participated in the meeting.
struct SpeakerCountView: View {
    let request: SpeakerCountRequest
    let onComplete: (Int) -> Void

    @State private var speakerCount = 0
    @State private var completed = false

    var body: some View {
        VStack(spacing: 16) {
            Text("How many speakers? — \"\(request.meetingTitle)\"")
                .font(.headline)
                .padding(.top, 8)

            HStack(spacing: 16) {
                Stepper(value: $speakerCount, in: 0...20) {
                    Text(speakerCount == 0 ? "Auto-detect" : "\(speakerCount) speakers")
                        .monospacedDigit()
                        .frame(minWidth: 120, alignment: .leading)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Auto-detect") {
                    guard !completed else { return }
                    completed = true
                    onComplete(0)
                }
                .keyboardShortcut(.escape)

                Button("Confirm") {
                    guard !completed else { return }
                    completed = true
                    onComplete(speakerCount)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 8)
        }
        .padding()
        .frame(minWidth: 320)
        .onDisappear {
            // If window is closed without confirming, send 0 (auto-detect)
            // so Python doesn't block waiting for speaker_count_response.json
            if !completed {
                completed = true
                onComplete(0)
            }
        }
    }
}
