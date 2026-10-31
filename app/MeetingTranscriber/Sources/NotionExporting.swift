import Foundation

/// Result of a meeting export to Notion.
struct NotionPageResult: Sendable, Equatable {
    let pageID: String
    let url: String?
    /// Optional values the target database could not accept because it has no
    /// recognized column for them. Never silently dropped: the job warning
    /// names them.
    let omittedProperties: [String]
    /// True when an earlier export of this job already created the page and
    /// this run updated its properties instead of creating another page.
    let updatedExistingPage: Bool
    init(
        pageID: String,
        url: String? = nil,
        omittedProperties: [String] = [],
        updatedExistingPage: Bool = false,
    ) {
        self.pageID = pageID
        self.url = url
        self.omittedProperties = omittedProperties
        self.updatedExistingPage = updatedExistingPage
    }
}

/// Abstract interface for exporting meeting minutes to Notion.
protocol NotionExporting: Sendable {
    /// Exports one meeting.
    ///
    /// `existingPageID` is the page a previous attempt created for this job.
    /// Passing it makes a retry recover that page instead of creating a second
    /// one. `onPageCreated` runs as soon as the page exists, before overflow
    /// blocks are appended, so a failed append still leaves a page ID the next
    /// retry can use.
    func exportMeeting( // swiftlint:disable:this function_parameter_count
        title: String,
        date: Date?,
        tags: [String],
        markdown: String,
        transcript: String?,
        existingPageID: String?,
        onPageCreated: @escaping @Sendable (NotionPageResult) async -> Void,
    ) async throws -> NotionPageResult
}
