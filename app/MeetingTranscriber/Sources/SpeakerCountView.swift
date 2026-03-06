import SwiftUI

/// Label for speaker count: 0 → "Auto-detect", N → "N speakers".
func speakerCountLabel(_ count: Int) -> String {
    count == 0 ? "Auto-detect" : "\(count) speakers"
}

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
                    Text(speakerCountLabel(speakerCount))
                        .monospacedDigit()
                        .frame(minWidth: 120, alignment: .leading)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Auto-detect") {
                    confirm(count: 0)
                }
                .keyboardShortcut(.escape)

                Button("Confirm") {
                    confirm(count: speakerCount)
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

    private func confirm(count: Int) {
        guard !completed else { return }
        completed = true
        onComplete(count)
        // Close the window so the user sees the app proceeding
        DispatchQueue.main.async {
            (NSApp as NSApplication?)?.keyWindow?.close()
        }
    }
}
