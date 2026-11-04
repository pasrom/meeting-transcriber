@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The pending-meeting menu at the top of the naming window. Its width is
/// covered by `SpeakerNamingWindowWidthTests`; this pins the wiring.
@MainActor
final class NamingJobPickerTests: XCTestCase {
    func testPickingAMeetingWritesItsJobToTheSelection() throws {
        let jobs = ["Standup", "Retro"].map { title in
            PipelineJob(meetingTitle: title, appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        }
        var selection: UUID? = jobs[0].id
        let binding = Binding(get: { selection }, set: { selection = $0 })

        try NamingJobPicker(jobs: jobs, selection: binding).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.namingJobPicker)
            .find(ViewType.Picker.self)
            .select(value: UUID?.some(jobs[1].id))

        XCTAssertEqual(selection, jobs[1].id)
    }
}
