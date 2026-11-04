import SwiftUI

/// The pending-meeting picker at the top of the naming window, shown once more
/// than one meeting waits for names.
///
/// A menu, not a segmented control: the window is sized to its content
/// (`.windowResizability(.contentSize)`) and a segmented control is as wide
/// as all its titles together, so every meeting left unnamed widened the
/// window, to several screen widths with enough of them waiting.
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
        .accessibilityIdentifier(A11yID.namingJobPicker)
    }
}
