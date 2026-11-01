import Foundation
@testable import MeetingTranscriber

/// Holds every export open until the test releases it, and does not notice
/// being cancelled: the stand-in for a Notion that never answers.
actor GatedNotionExporter: NotionExporting {
    private let gate = AsyncGate()
    private(set) var startedExports = 0

    func release() async {
        await gate.open()
    }

    // swiftlint:disable:next function_parameter_count
    func exportMeeting(
        title _: String,
        date _: Date?,
        tags _: [String],
        markdown _: String,
        transcript _: String?,
        existingPageID _: String?,
        onPageCreated _: @Sendable (NotionPageResult) async -> Void,
    ) async -> NotionPageResult {
        startedExports += 1
        await gate.wait()
        return NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1")
    }
}
