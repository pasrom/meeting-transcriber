import Foundation
@testable import MeetingTranscriber

/// Holds every export open until the test releases it, and does not notice
/// being cancelled: the stand-in for a Notion that never answers.
actor GatedNotionExporter: NotionExporting {
    /// When the page the export creates is reported through `onPageCreated`.
    enum PageCreation {
        /// Never: the export is stuck before its page exists.
        case never
        /// Before the gate: the page exists and the export is stuck appending.
        case beforeRelease
        /// After the gate: the page appears only once the test releases the export.
        case afterRelease
    }

    private let gate = AsyncGate()
    private let pageCreation: PageCreation
    private(set) var startedExports = 0
    /// The page each call was told to reuse, in call order.
    private(set) var existingPageIDs: [String?] = []

    init(pageCreation: PageCreation = .never) {
        self.pageCreation = pageCreation
    }

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
        existingPageID: String?,
        onPageCreated: @Sendable (NotionPageResult) async -> Void,
    ) async -> NotionPageResult {
        startedExports += 1
        existingPageIDs.append(existingPageID)
        let page = NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1")
        if pageCreation == .beforeRelease { await onPageCreated(page) }
        await gate.wait()
        if pageCreation == .afterRelease { await onPageCreated(page) }
        return page
    }
}
