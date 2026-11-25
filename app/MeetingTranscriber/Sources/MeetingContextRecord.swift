import Foundation

enum MeetingContextStatus: String, Codable, Sendable {
    case used, partial, skipped, failed
    case noRelevantContext = "no_relevant_context"

    var label: String {
        switch self {
        case .used: "Context used"
        case .partial: "Partial context"
        case .noRelevantContext: "No relevant context"
        case .skipped: "Context skipped"
        case .failed: "Context failed"
        }
    }
}

struct ContextEvidence: Codable, Sendable {
    let evidenceID: String
    let requestID: String
    let serverID: UUID
    let toolName: String
    let segmentIDs: [String]
    let retrievedAt: Date
    var content: ContextJSON

    var notesInput: ContextJSON {
        .object(["evidenceID": .string(evidenceID), "segmentIDs": .array(segmentIDs.map(ContextJSON.string)), "content": content])
    }
}

struct MeetingContextRecord: Encodable, Sendable {
    enum Reason: String, Codable, Sendable {
        // These names are stable version-one provenance codes.
        // swiftlint:disable raw_value_for_camel_cased_codable_enum
        case unsupportedProvider, unapprovedSources, transcriptTooLong, sensitiveTranscript, plannerFailed, invalidPlan
        case discoveryFailed, catalogLimit, invalidRequest, callLimit, callFailed, timeout, unsupportedContent
        case unsafeData, evidenceLimit, evidenceExcerpted, revoked, notesFailed
        // swiftlint:enable raw_value_for_camel_cased_codable_enum
    }

    struct Request: Encodable, Sendable {
        let id: String
        let serverID: UUID
        let toolName: String
        let segmentIDs: [String]
        let status: String
        var failure: ContextFailure?
        var evidenceID: String?
    }

    struct Provenance: Encodable, Sendable {
        let evidenceID: String
        let requestID: String
        let serverID: UUID
        let toolName: String
        let segmentIDs: [String]
        let retrievedAt: Date
        let content: ContextJSON?
        let evidenceRetained: Bool
    }

    // The synthesized encoder writes these fields to the provenance sidecar.
    let schemaVersion = 1 // swiftlint:disable:this unused_declaration
    let meetingID: UUID
    let attemptID = UUID() // swiftlint:disable:this unused_declaration
    let startedAt = Date() // swiftlint:disable:this unused_declaration
    var completedAt: Date?
    var status: MeetingContextStatus = .skipped
    var reasons: [Reason] = []
    var requests: [Request] = []
    var evidence: [Provenance] = []
    var model: String?
    var provider: String?
    var notesSHA256: String?
    var transcriptSHA256: String?
    var sourceFailures: [UUID: ContextFailure] = [:]

    mutating func add(_ reason: Reason) {
        if !reasons.contains(reason) { reasons.append(reason) }
    }

    var statusMessage: String {
        let reason = reasons.first { $0 != .evidenceExcerpted } ?? reasons.first
        let detail = switch reason {
        case .unsupportedProvider: "This notes provider is unavailable for MCP enrichment."
        case .unapprovedSources: "No source is approved for this notes destination."
        case .transcriptTooLong: "The full transcript exceeds the planning budget."
        case .sensitiveTranscript: "The transcript was withheld from planning after a credential check."
        case .plannerFailed, .invalidPlan: "The notes model did not return a usable lookup plan."
        case .discoveryFailed: "A knowledge source could not be connected or listed."
        case .catalogLimit, .callLimit: "An enrichment size or call limit was reached."
        case .evidenceLimit: "A lookup response or the notes request exceeded a size limit."
        case .evidenceExcerpted: "Long lookup results were shortened to fit the evidence budget."
        case .invalidRequest: "A proposed lookup did not pass validation."
        case .callFailed, .timeout: "A lookup failed or timed out."
        case .unsupportedContent, .unsafeData: "Some returned content was withheld."
        case .revoked: "Source authorization changed during generation."
        case .notesFailed: "Meeting notes were not saved."
        case nil: ""
        }
        return detail.isEmpty ? status.label : "\(status.label). \(detail)"
    }
}

struct MeetingContextOutcome: Sendable {
    struct Item: Sendable {
        let source: MCPSource
        let evidence: ContextEvidence
    }

    var record: MeetingContextRecord
    var items: [Item] = []

    mutating func retainAuthorized(_ authorized: (MCPSource) -> Bool) {
        withhold(failing: .revoked) { !authorized($0) }
    }

    mutating func withhold(failing reason: ContextFailure, where exclude: (MCPSource) -> Bool) {
        let withheld = Set(items.filter { exclude($0.source) }.map(\.evidence.evidenceID))
        guard !withheld.isEmpty else { return }
        record.add(reason == .limit ? .evidenceLimit : .revoked)
        items.removeAll { withheld.contains($0.evidence.evidenceID) }
        record.requests = record.requests.map { request in
            guard let evidenceID = request.evidenceID, withheld.contains(evidenceID) else { return request }
            return MeetingContextRecord.Request(
                id: request.id, serverID: request.serverID, toolName: request.toolName,
                segmentIDs: request.segmentIDs, status: "withheld", failure: reason,
            )
        }
        record.status = items.isEmpty ? .skipped : .partial
    }

    mutating func captureProvenance() {
        record.evidence = items.map { item in
            let evidence = item.evidence
            return MeetingContextRecord.Provenance(
                evidenceID: evidence.evidenceID, requestID: evidence.requestID, serverID: evidence.serverID,
                toolName: evidence.toolName, segmentIDs: evidence.segmentIDs, retrievedAt: evidence.retrievedAt,
                content: item.source.retainEvidence ? evidence.content : nil, evidenceRetained: item.source.retainEvidence,
            )
        }
    }
}
