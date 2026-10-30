import Foundation

/// Where a finished job's Open action should go.
///
/// A Notion export leaves the local protocol file absent when the user chose
/// "skip local markdown on success", so the page URL is the only usable target
/// for those jobs. The preference is explicit rather than inferred from the URL
/// alone: turning Notion export off should go back to opening the local file.
enum JobOpenTarget: Equatable {
    case notion(URL)
    case file(URL)

    static func resolve(for job: PipelineJob?, preferNotion: Bool) -> Self? {
        guard let job else { return nil }

        if preferNotion, job.hasCompletedNotionExport, let notionURL = job.notionPageURL {
            return .notion(notionURL)
        }
        if let path = job.protocolPath ?? job.transcriptPath {
            return .file(path)
        }
        if job.hasCompletedNotionExport, let notionURL = job.notionPageURL {
            return .notion(notionURL)
        }
        return nil
    }

    var url: URL {
        switch self {
        case let .notion(url), let .file(url): url
        }
    }

    /// The per-job menu row stays short; the Notion case says where it goes.
    var jobActionLabel: String {
        switch self {
        case .notion: "Open in Notion"
        case .file: "Open"
        }
    }

    var lastProtocolLabel: String {
        switch self {
        case .notion: "Open Last Notes in Notion"
        case .file: "Open Last Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .notion: "arrow.up.right.square"
        case .file: "doc.text"
        }
    }
}
