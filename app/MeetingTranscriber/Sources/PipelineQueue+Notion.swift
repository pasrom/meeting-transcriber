import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// One settings read supplies the destination and output policy for an export.
struct NotionExportConfiguration {
    let exporter: any NotionExporting
    let databaseID: String
    var skipLocalMarkdown = false
    var speakerTagsEnabled = false
    /// How long one export may run in all. Each request has its own timeout, but
    /// a replace of a long page issues hundreds of them, so without this a
    /// Notion that answers slowly instead of failing keeps the job's export in
    /// progress for hours.
    var deadline = Self.defaultDeadline

    static let defaultDeadline = Duration.seconds(600)

    @MainActor
    static func resolve(settings: AppSettings) -> NotionExportResolution {
        guard settings.notionExportEnabled else { return .disabled }
        // Trimmed like the client and the Settings notice do: a key of only
        // whitespace is no key, and would otherwise fail every export as a bad token.
        let key = settings.notionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let databaseID = settings.notionDatabaseID
        guard !key.isEmpty, !databaseID.isEmpty else { return .unconfigured }
        return .ready(Self(
            exporter: NotionClient(apiKey: key, databaseID: databaseID),
            databaseID: databaseID,
            skipLocalMarkdown: settings.notionSkipLocalMarkdownOnSuccess,
            speakerTagsEnabled: settings.notionSpeakerTagsEnabled,
        ))
    }
}

/// Keeps "switched off" and "switched on but unusable" apart: only the second
/// one is worth telling the user about.
enum NotionExportResolution {
    case disabled
    case unconfigured
    case ready(NotionExportConfiguration)

    var configuration: NotionExportConfiguration? {
        if case let .ready(configuration) = self { return configuration }
        return nil
    }
}

extension AppNotifying {
    func notifyNotionExport(job: PipelineJob, failureReason: String?) {
        if let failureReason {
            notify(title: "Notion Export Failed", body: "\(job.meetingTitle): \(failureReason)")
        } else {
            notify(title: "Saved to Notion", body: job.meetingTitle)
        }
    }
}

/// A speaker nobody named keeps a generic label, which is not a name worth a tag.
enum NotionTagFilter {
    static func confirmedNames(_ names: [String]) -> [String] {
        names.filter { $0.range(of: #"^(?:[RM]_)?(?:speaker|unknown)(?:[ _]?\d+)?$"#, options: [.regularExpression, .caseInsensitive]) == nil }
    }
}

/// What the export needs once the job has reached `.done`.
struct PendingNotionExport {
    let protocolMD: String
    let transcript: String?
    let speakerNames: [String]
    let configuration: NotionExportConfiguration
    let savedLocally: Bool
}

extension PipelineQueue {
    static let notionExportUnconfiguredWarning =
        "Notion export skipped: add an API token and choose a database in Settings → Output"
    private static let notionExportFailurePrefix = "Notion export failed"
    private static let notionExportBackupNote = "saved locally as backup"
    private static let notionExportBackupMissingNote = "local backup could not be saved"
    static let notionExportInterruptedReason = "interrupted when the app quit"
    private static let notionRetryConfigurationWarning = "Configure and enable Notion export in Settings before retrying"
    private static let notionRetryReadWarning = "Could not read the local protocol backup; Notion export was not retried"
    private static let notionRetryTranscriptWarning =
        "The local protocol backup no longer has the transcript; Notion export was not retried"

    /// Marks the export as running before the `.done` transition, so nothing
    /// reading that transition can mistake the job for one with no export.
    func queueNotionExport(_ export: PendingNotionExport, jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].beginNotionExport(speakerNames: export.speakerNames, localBackupSaved: export.savedLocally)
        pendingNotionExports[jobID] = export
        saveSnapshot()
    }

    /// Runs off the pipeline so a slow or rate-limited Notion cannot hold up the
    /// next job. Exports of one job run in order, so a re-export after speaker
    /// naming cannot race an earlier write to the same page.
    func startPendingNotionExport(jobID: UUID) {
        guard let export = pendingNotionExports.removeValue(forKey: jobID) else { return }
        startNotionExport(export, jobID: jobID)
    }

    private func startNotionExport(_ export: PendingNotionExport, jobID: UUID) {
        let previous = notionExportTasks[jobID]?.task
        let token = UUID()
        let task = Task { [self] in
            // Cancelling this export must reach the one it waits behind as well.
            await withTaskCancellationHandler { await previous?.value } onCancel: { previous?.cancel() }
            let succeeded = await exportToNotion(
                jobID: jobID, protocolMD: export.protocolMD, transcript: export.transcript,
                speakerNames: export.speakerNames, configuration: export.configuration,
                localBackupSaved: export.savedLocally,
            )
            if succeeded {
                if export.configuration.skipLocalMarkdown { removeLocalProtocol(jobID: jobID) }
                scheduleCompletedJobRemoval(id: jobID)
            } else if !export.savedLocally, !isRetired {
                noteNotionBackupMissing(jobID: jobID)
            }
            if notionExportTasks[jobID]?.token == token { notionExportTasks.removeValue(forKey: jobID) }
        }
        notionExportTasks[jobID] = (token, task, export)
    }

    /// Whether every export still in progress can move to a replacement queue,
    /// which is what lets a slow Notion go on without holding this queue in
    /// place. Only a queue the controller built is adopted from, and a manual
    /// retry, which its caller awaits, has no input to hand over.
    ///
    /// An export also has to know its page already. A create request that is
    /// still in flight when the queue is swapped loses its response, Notion has
    /// the page, and the restart would create a second one with no warning and
    /// no retry entry, unlike a quit, which ends the job as failed. That window
    /// is the create request alone, so the swap waits for that, not for the whole export.
    func canHandOverNotionExports(builtHere: Bool) -> Bool {
        jobs.allSatisfy { job in
            guard job.notionExportStatus == .inProgress else { return true }
            guard builtHere, let running = notionExportTasks[job.id] else { return false }
            return Self.notionPageToReuse(for: job, databaseID: Self.normalizedDatabaseID(running.export.configuration.databaseID)) != nil
        }
    }

    private static func normalizedDatabaseID(_ id: String) -> String {
        NotionClient.extractID(from: id) ?? id
    }

    /// The page an earlier attempt created in the database this export writes
    /// to (`databaseID`, normalized), which a new attempt updates instead of
    /// creating another one.
    private static func notionPageToReuse(for job: PipelineJob, databaseID: String) -> String? {
        job.notionDatabaseID.map(normalizedDatabaseID) == databaseID ? job.notionPageID : nil
    }

    /// Stops the exports running here so a replacement queue can start them
    /// again with the configuration they were queued with, writing into the page
    /// the stopped run created (`canHandOverNotionExports` guarantees there is
    /// one). What a stopped run still returns is dropped by `liveJobIndex`,
    /// because the caller retires this queue straight after `adoptJobs`, with no
    /// suspension in between that could let a stopped run observe the queue as
    /// live.
    func handOverRunningNotionExports() -> [UUID: PendingNotionExport] {
        var running: [UUID: PendingNotionExport] = [:]
        for (jobID, entry) in notionExportTasks {
            entry.task.cancel()
            running[jobID] = entry.export
        }
        return running
    }

    /// Starts the exports another queue handed over. The jobs came across as
    /// still in progress, see `adoptJobs`.
    func resumeHandedOverNotionExports(_ handedOver: [UUID: PendingNotionExport]) {
        for (jobID, export) in handedOver where jobs.contains(where: { $0.id == jobID }) {
            startNotionExport(export, jobID: jobID)
        }
    }

    /// The job's index, or nil once a replacement queue owns it: a run stopped by
    /// the hand-over can still return, and must not report on a job that has
    /// started over there.
    private func liveJobIndex(of jobID: UUID) -> Int? {
        isRetired ? nil : jobs.firstIndex { $0.id == jobID }
    }

    func awaitNotionExports() async {
        while let running = notionExportTasks.values.first?.task {
            await running.value
        }
    }

    private func removeLocalProtocol(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), let path = jobs[index].protocolPath else { return }
        do {
            try FileManager.default.removeItem(at: path)
            jobs[index].protocolPath = nil
            persistNotionExportChange(jobID: jobID)
        } catch {
            let shortID = PipelineJob.shortID(for: jobID)
            // Private: a file-write CocoaError names the file, which is the meeting title.
            logger.warning("[\(shortID, privacy: .public)] protocol_backup_remove_failed error=\(error.localizedDescription, privacy: .private)")
        }
    }

    /// Export finished Markdown independently of generation and local saving.
    /// A failed export leaves the local-save decision to the caller.
    func exportToNotion(
        jobID: UUID, protocolMD: String, transcript: String?,
        speakerNames: [String], configuration: NotionExportConfiguration?,
        localBackupSaved: Bool = false,
    ) async -> Bool {
        guard let configuration, let index = liveJobIndex(of: jobID) else { return false }
        jobs[index].beginNotionExport(speakerNames: speakerNames, localBackupSaved: localBackupSaved)
        persistNotionExportChange(jobID: jobID)
        let job = jobs[index]
        let databaseID = Self.normalizedDatabaseID(configuration.databaseID)
        let existingPageID = Self.notionPageToReuse(for: job, databaseID: databaseID)
        do {
            let pageRecorder: @Sendable (NotionPageResult) async -> Void = { [weak self] page in
                await self?.recordNotionPageExport(jobID: jobID, databaseID: databaseID, page: page)
            }
            let exporter = configuration.exporter
            let title = ProtocolGenerator.extractTitle(from: protocolMD) ?? job.meetingTitle
            let date = job.meetingStartTime
            let tags = configuration.speakerTagsEnabled ? NotionTagFilter.confirmedNames(speakerNames) : []
            let pageResult = try await NotionExportDeadline.run(limit: configuration.deadline) {
                try await exporter.exportMeeting(
                    title: title,
                    date: date,
                    tags: tags,
                    markdown: protocolMD,
                    transcript: transcript,
                    existingPageID: existingPageID,
                    onPageCreated: pageRecorder,
                )
            }
            guard let index = liveJobIndex(of: jobID) else { return false }
            jobs[index].recordNotionPage(pageResult, databaseID: databaseID)
            jobs[index].finishNotionExport(succeeded: true)
            jobs[index].warnings.removeAll { warning in
                warning.hasPrefix(Self.notionExportFailurePrefix)
                    || warning == Self.notionRetryConfigurationWarning
                    || warning == Self.notionRetryReadWarning
                    || warning == Self.notionRetryTranscriptWarning
            }
            addNotionExportWarnings(pageResult, id: jobID)
            persistNotionExportChange(jobID: jobID)
            onNotionExportFinished?(jobs[index], nil)
            logger.info("[\(job.shortID, privacy: .public)] notion_exported page=\(pageResult.url ?? pageResult.pageID, privacy: .private)")
            return true
        } catch {
            guard let index = liveJobIndex(of: jobID) else { return false }
            jobs[index].finishNotionExport(succeeded: false)
            logger.warning("[\(job.shortID, privacy: .public)] notion_export_failed error=\(error.localizedDescription, privacy: .private)")
            let reason = NotionClientError.exportFailureReason(for: error)
            recordNotionExportFailure(jobID: jobID, reason: reason)
            persistNotionExportChange(jobID: jobID)
            onNotionExportFinished?(jobs[index], reason)
            return false
        }
    }

    /// A retry replaces the earlier reason instead of listing both.
    func recordNotionExportFailure(jobID: UUID, reason: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        Self.noteNotionExportFailure(on: &jobs[index], reason: reason)
    }

    static func noteNotionExportFailure(on job: inout PipelineJob, reason: String, backupSaved: Bool = true) {
        job.warnings.removeAll { $0.hasPrefix(notionExportFailurePrefix) }
        let backupNote = backupSaved ? notionExportBackupNote : notionExportBackupMissingNote
        job.warnings.append("\(notionExportFailurePrefix) (\(reason)); \(backupNote)")
    }

    /// The failure text promises a backup, which a failed local save takes back.
    func noteNotionBackupMissing(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].warnings = jobs[index].warnings.map { warning in
            guard warning.hasPrefix(Self.notionExportFailurePrefix) else { return warning }
            return warning.replacingOccurrences(of: Self.notionExportBackupNote, with: Self.notionExportBackupMissingNote)
        }
    }

    /// A failed export already has a complete Markdown backup. Retrying it
    /// must not transcribe the audio or spend another protocol-generation call.
    /// A hint from the job's state only; see `PipelineJob.hasRetryableNotionBackup`.
    /// It must not check the file: it stands for what the menu shows on every
    /// render, and the output folder can be a network volume. The retry reads
    /// the file itself.
    func canRetryNotionExport(id: UUID) -> Bool {
        jobs.first { $0.id == id }?.hasRetryableNotionBackup ?? false
    }

    @discardableResult
    func retryNotionExport(id: UUID) async -> Bool {
        guard canRetryNotionExport(id: id), let job = jobs.first(where: { $0.id == id }) else { return false }
        guard let configuration = notionExportConfigurationProvider?().configuration else {
            addWarning(id: id, Self.notionRetryConfigurationWarning)
            persistNotionExportChange(jobID: id)
            return false
        }
        guard let path = job.protocolPath,
              let markdown = try? String(contentsOf: path, encoding: .utf8),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            addWarning(id: id, Self.notionRetryReadWarning)
            persistNotionExportChange(jobID: id)
            return false
        }
        // The retry replaces the page's blocks. The backup is the only place the
        // transcript survives (the export got it appended under its heading), so
        // a backup without it would swap a page that has the transcript for one
        // that has none.
        if job.includeFullTranscriptInProtocol == true, !MarkdownToNotionBlocks.hasFullTranscriptHeading(in: markdown) {
            addWarning(id: id, Self.notionRetryTranscriptWarning)
            persistNotionExportChange(jobID: id)
            return false
        }
        let succeeded = await exportToNotion(
            jobID: id, protocolMD: markdown, transcript: nil,
            speakerNames: job.notionExportSpeakerNames ?? [], configuration: configuration,
        )
        if succeeded {
            if configuration.skipLocalMarkdown { removeLocalProtocol(jobID: id) }
            scheduleCompletedJobRemoval(id: id)
        }
        return succeeded
    }

    private func recordNotionPageExport(jobID: UUID, databaseID: String, page: NotionPageResult) {
        guard let index = liveJobIndex(of: jobID) else { return }
        jobs[index].recordNotionPage(page, databaseID: databaseID)
        persistNotionExportChange(jobID: jobID)
    }

    private func persistNotionExportChange(jobID: UUID) {
        saveSnapshot()
        // Like the snapshot, the shared store is not written from a replaced queue.
        if !isRetired, let job = jobs.first(where: { $0.id == jobID }), job.state.isTerminal {
            recordTerminalJob(job)
        }
    }

    private func addNotionExportWarnings(_ result: NotionPageResult, id jobID: UUID) {
        guard !result.omittedProperties.isEmpty else { return }
        let fields = result.omittedProperties.joined(separator: " and ")
        addWarning(
            id: jobID,
            "Notion export omitted \(fields): the database has no recognized column for \(fields). "
                + "Add one in Settings → Output → Notion Database Export.",
        )
    }
}
