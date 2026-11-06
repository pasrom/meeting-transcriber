import SwiftUI

/// The pending-meeting picker at the top of the naming window, shown once more
/// than one meeting waits for names.
///
/// A menu, not a segmented control: the window is sized to its content
/// (`.windowResizability(.contentSize)`) and a segmented control is as wide
/// as all its titles together, so every meeting left unnamed widened the
/// window, to several screen widths with enough of them waiting.
///
/// A menu still asks for the width of its widest title, and titles have no
/// length limit (an import takes the file's basename), so the picker asks for
/// none: the dialog below it decides the window's width and the picker fills
/// it, truncating a long title instead of widening the window.
struct NamingJobPicker: View {
    let jobs: [PipelineJob]
    @Binding var selection: UUID?

    var body: some View {
        Picker("Meeting", selection: $selection) {
            ForEach(jobs) { job in
                Text(job.meetingTitle).tag(Optional(job.id))
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
        .accessibilityIdentifier(A11yID.namingJobPicker)
    }
}
