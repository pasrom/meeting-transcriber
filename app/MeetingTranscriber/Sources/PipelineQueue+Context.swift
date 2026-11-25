import Foundation

/// The enabled sources a job may use, plus a live revocation check. Capture once
/// at the start of the notes stage, before sending anything to either endpoint.
struct MeetingContextConfiguration {
    let sources: [MCPSource]
    let authorize: ContextEnrichment.Authorization
    var credentials: ContextEnrichment.Credentials = ContextMCPKeychain.load
}

extension PipelineQueue {
    func collectMeetingContext(
        for job: PipelineJob, transcript: String, model: (any ContextNotesModel)?, configuration: MeetingContextConfiguration?,
    ) async throws -> (MeetingContextOutcome, MeetingContextConfiguration)? {
        guard let configuration else { return nil }
        guard let model else {
            var record = MeetingContextRecord(meetingID: job.id)
            record.add(.unsupportedProvider)
            return (MeetingContextOutcome(record: record), configuration)
        }
        let enrichment = ContextEnrichment(authorized: configuration.authorize, credentials: configuration.credentials)
        let context = try await enrichment.collect(meetingID: job.id, transcript: transcript, sources: configuration.sources, model: model)
        return (context, configuration)
    }

    func generateContextualNotes(
        with model: (any ContextNotesModel)?, job: PipelineJob, transcript: String, diarized: Bool,
        context: inout (outcome: MeetingContextOutcome, configuration: MeetingContextConfiguration)?,
    ) async throws -> String? {
        if var attempt = context, let model {
            let authorize = attempt.configuration.authorize
            attempt.outcome.retainAuthorized(authorize)
            context = attempt
            if !attempt.outcome.items.isEmpty {
                let evidence = try ContextJSON.encodedText(attempt.outcome.items.map(\.evidence.notesInput))
                let sources = attempt.outcome.items.map(\.source)
                do {
                    let notes = try await model.generateWithContext(
                        transcript: transcript, diarized: diarized, meetingStartTime: job.meetingStartTime,
                        evidence: evidence,
                    ) { sources.allSatisfy(authorize) }
                    try ensureStillQueued(job.id)
                    guard sources.allSatisfy(authorize) else { throw ContextFailure.revoked }
                    return notes
                } catch let reason as ContextFailure where reason == .revoked || reason == .limit {
                    // A changed policy or a template that uses the remaining
                    // context budget can still use the ordinary notes path.
                    attempt.outcome.withhold(failing: reason) { _ in true }
                    context = attempt
                }
            }
        }
        return nil
    }

    func existingNotesVersion(for job: PipelineJob, at notesURL: URL) async throws -> MeetingContextFiles.ExistingNotes? {
        guard job.notesContextMode != nil else { return nil }
        let version = try await Task.detached { try MeetingContextFiles.ExistingNotes.capture(notesURL) }.value
        try ensureStillQueued(job.id)
        return version
    }

    func recordMeetingContext(
        _ outcome: MeetingContextOutcome, jobID: UUID, notes: URL, markdown: String?, transcript: String,
    ) {
        var outcome = outcome
        outcome.record.completedAt = Date()
        if let markdown {
            outcome.captureProvenance()
            outcome.record.notesSHA256 = ContextDigest.hash(Data(markdown.utf8))
        } else {
            outcome.record.add(.notesFailed)
            outcome.record.status = .failed
        }
        outcome.record.transcriptSHA256 = ContextDigest.hash(Data(transcript.utf8))
        if let index = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[index].meetingContextMessage = outcome.record.statusMessage
        }
        // A failed attempt must never replace provenance for earlier notes.
        if markdown == nil, FileManager.default.fileExists(atPath: notes.path) { return }
        do { try MeetingContextFiles.save(outcome.record, beside: notes) } catch { addWarning(id: jobID, "The meeting context record could not be saved.") }
    }
}

@MainActor
extension AppSettings {
    func meetingContextConfiguration() -> MeetingContextConfiguration? {
        guard meetingContextEnabled else { return nil }
        let provider = protocolProvider
        let destination = openAIEndpoint
        let connectionID = activeOpenAIConnectionID
        return MeetingContextConfiguration(sources: mcpSources) { [weak self] source in
            guard let self, meetingContextEnabled, protocolProvider == provider, openAIEndpoint == destination,
                  activeOpenAIConnectionID == connectionID else { return false }
            return mcpSources.contains(source)
        }
    }
}
