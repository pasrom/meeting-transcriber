import Foundation

/// Failures of the Notion client, with the fixed cause text shown in a job warning
/// (never Notion's response text, which can quote meeting content back).
enum NotionClientError: LocalizedError, Equatable {
    case invalidID(String)
    case missingDatabaseID
    case missingTitleProperty
    case databaseInTrash
    case invalidResponse
    case httpError(statusCode: Int, code: String? = nil, message: String)

    var httpStatusCode: Int? {
        guard case let .httpError(status, _, _) = self else { return nil }
        return status
    }

    /// A short cause for the job warning. Fixed categories rather than the
    /// response text, which can quote meeting content back.
    static func exportFailureReason(for error: any Error) -> String {
        switch error {
        case let error as Self:
            error.exportFailureReason

        case let error as URLError where error.code == .timedOut:
            "request timed out"

        case is URLError:
            "network error"

        case is NotionBlockTooLargeError:
            "a block is too large for Notion"

        case is CancellationError:
            "cancelled"

        case is NotionExportDeadlineExceeded:
            "time limit reached"

        default:
            "unexpected response from Notion"
        }
    }

    private var exportFailureReason: String {
        switch self {
        case .invalidID, .missingDatabaseID:
            "invalid database ID"

        case .missingTitleProperty:
            "database has no title column"

        case .databaseInTrash:
            "database is in the trash"

        case .invalidResponse:
            "unexpected response from Notion"

        case let .httpError(status, _, _):
            switch status {
            case 401: "invalid API token"
            case 403: "integration lacks permission"
            case 404: "not shared with the integration"
            case 429: "rate limited by Notion"
            case 500...: "Notion server error, HTTP \(status)"
            default: "rejected by Notion, HTTP \(status)"
            }
        }
    }

    var errorDescription: String? {
        switch self {
        case let .invalidID(msg):
            msg

        case .missingDatabaseID:
            "No Notion Database ID configured."

        case .missingTitleProperty:
            "This Notion database has no title column, so a page cannot be created in it."

        case .databaseInTrash:
            "This Notion database is in the trash. Restore it in Notion or choose another database."

        case .invalidResponse:
            "Invalid response received from Notion."

        case let .httpError(status, _, msg):
            "Notion error (HTTP \(status)): \(msg)"
        }
    }
}
