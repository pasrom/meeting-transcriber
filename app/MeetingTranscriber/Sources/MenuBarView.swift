import SwiftUI

struct MenuBarView: View {
    let status: TranscriberStatus?
    let isWatching: Bool
    let pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker?
    let onStartStop: () -> Void
    let onRecordApp: () -> Void
    let onRecordMicrophone: () -> Void
    /// Whether the user set "No Microphone (app audio only)". Only reaches the
    /// microphone item, which it disables with a reason.
    let noMic: Bool
    /// The *wide* predicate: a manual recording that is running, or a start that
    /// has registered and not yet built its loop. `state == .recording` misses
    /// that second window, and the microphone item would sit enabled through it
    /// handing back a dead click, which is what `AppPickerStartState` was built
    /// to avoid on the picker.
    let manualRecordingPendingOrActive: Bool
    let onStopManualRecording: (() -> Void)?
    let onOpenProtocol: (JobOpenTarget) -> Void
    let onOpenProtocolsFolder: () -> Void
    let onOpenSettings: () -> Void
    let onNameSpeakers: (() -> Void)?
    let onProcessFiles: () -> Void
    let onDismissJob: (UUID) -> Void
    let onQuit: () -> Void
    /// The browser whose recording-consent prompt is open, nil when none is.
    /// Mirrors the notification in the menu so a prompt hidden by Focus, screen
    /// sharing or a notification style of None can still be answered (issue #814).
    var pendingConsentApp: String?
    /// Answers the open prompt: true records, false declines.
    var onAnswerPendingConsent: (Bool) -> Void = { _ in }
    /// Whether Notion export is on. A job that has a page URL but was exported
    /// before the setting was turned off still falls back to it when no local
    /// file exists; `JobOpenTarget` owns that rule.
    var notionExportEnabled: Bool = false

    private var state: TranscriberState {
        status?.state ?? .idle
    }

    private var microphoneAvailability: MicrophoneRecordingAvailability {
        .resolve(
            isRecording: manualRecordingPendingOrActive || state == .recording,
            noMic: noMic,
        )
    }

    /// Hoisted out of the `ViewBuilder`: an `Optional.map` returning an
    /// interpolated string, coalesced with `??`, inside an overloaded `Text`
    /// initializer is the exact shape that blew the 300 ms type-check budget in
    /// this file before (see the note on `body`).
    private func meetingLabel(_ meeting: MeetingInfo) -> String {
        guard let pid = meeting.pid else { return meeting.app }
        return "\(meeting.app) (PID \(pid))"
    }

    // The sections below are hoisted out of `body` into separate computed
    // properties so each is type-checked independently. Inlined as one
    // expression, the `body` getter crossed the 300 ms type-check budget that
    // the analyze build enforces (-warn-long-expression-type-checking=300 with
    // -warnings-as-errors), failing the build on slower CI hardware. The view
    // order, dividers, and conditionals are unchanged.
    var body: some View {
        statusHeader
        meetingInfo
        errorInfo
        consentPrompt

        Divider()

        watchControls
        processingQueue

        Divider()

        protocolActions
        updateSection

        Divider()

        settingsButton

        Divider()

        quitButton
    }

    // MARK: - Body sections

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(state.label, systemImage: state.icon)
                .font(.headline)

            if let detail = status?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var meetingInfo: some View {
        if let meeting = status?.meeting {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                // A microphone-only recording owns no process, so there is no
                // PID to show and a placeholder would only read as a real one.
                Text(meetingLabel(meeting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var errorInfo: some View {
        if let error = status?.error, state == .error {
            Divider()
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var consentPrompt: some View {
        if let app = pendingConsentApp {
            Divider()
            Text("Meeting detected in \(app)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            Button {
                onAnswerPendingConsent(true)
            } label: {
                Label("Record This Meeting", systemImage: "record.circle.fill")
            }
            .accessibilityIdentifier(A11yID.menuRecordPendingConsent)
            Button {
                onAnswerPendingConsent(false)
            } label: {
                Label("Don't Record", systemImage: "xmark.circle")
            }
            .accessibilityIdentifier(A11yID.menuDeclinePendingConsent)
        }
    }

    @ViewBuilder private var watchControls: some View {
        Button {
            onStartStop()
        } label: {
            if isWatching {
                Label("Stop Watching", systemImage: "stop.fill")
            } else {
                Label("Start Watching", systemImage: "play.fill")
            }
        }
        .keyboardShortcut("s")

        if let onStopManualRecording {
            Button {
                onStopManualRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".")
        } else if state != .recording {
            Button {
                onRecordMicrophone()
            } label: {
                Label("Record Microphone", systemImage: "mic.circle")
            }
            .keyboardShortcut("m")
            .disabled(!microphoneAvailability.allowsStart)
            .help(microphoneAvailability.disabledReason ?? "Record the system microphone, with no app audio")

            Button {
                onRecordApp()
            } label: {
                Label("Record App...", systemImage: "record.circle")
            }
            .keyboardShortcut("r")
        }

        if let onNameSpeakers {
            Button {
                onNameSpeakers()
            } label: {
                Label("Name Speakers...", systemImage: "person.2.fill")
            }
            .keyboardShortcut("n")
        }

        Button {
            onProcessFiles()
        } label: {
            Label("Process Audio/Video Files...", systemImage: "doc.badge.plus")
        }
        .keyboardShortcut("p")
    }

    private var queueHeader: QueueHeader {
        QueueHeader.compute(jobStates: pipelineQueue.jobs.map(\.state), isProcessing: pipelineQueue.isProcessing)
    }

    @ViewBuilder private var processingQueue: some View {
        if !pipelineQueue.jobs.isEmpty {
            Divider()
            Label(queueHeader.title, systemImage: queueHeader.systemImage)

            ForEach(Array(pipelineQueue.jobs.enumerated()), id: \.element.id) { index, job in
                // A native separator, not a grouping view: each job is a run of
                // flat menu items, and without one the repeated Cancel / Retry /
                // Dismiss rows of neighbouring jobs read as one list.
                if index > 0 { Divider() }
                jobRow(job, index: index)
            }
        }
    }

    @ViewBuilder private var protocolActions: some View {
        let completedTarget = JobOpenTarget.resolve(
            for: pipelineQueue.completedJobs.last,
            preferNotion: notionExportEnabled,
        )
        let target = completedTarget ?? status?.protocolPath.map { path in
            JobOpenTarget.file(URL(fileURLWithPath: path))
        }
        if let target {
            Button {
                onOpenProtocol(target)
            } label: {
                Label(target.lastProtocolLabel, systemImage: target.systemImage)
            }
            .keyboardShortcut("o")
        }

        Button {
            onOpenProtocolsFolder()
        } label: {
            Label("Open Protocols Folder", systemImage: "folder")
        }
    }

    @ViewBuilder private var updateSection: some View {
        if let updateChecker, let update = updateChecker.availableUpdate {
            let route = updateChecker.installRoute(for: update)
            Divider()
            Button {
                route.perform()
            } label: {
                Label(updateTitle(update, route: route), systemImage: "arrow.down.circle.fill")
            }
        }
    }

    /// The menu closes on click, so the title has to say up front that the
    /// item copies a command rather than opening a download.
    private func updateTitle(_ update: ReleaseInfo, route: UpdateInstallRoute) -> String {
        switch route {
        case .homebrew: "Update Available: \(update.tagName) (Copy brew Command)"
        case .download: "Update Available: \(update.tagName)"
        }
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            Label("Settings...", systemImage: "gear")
        }
        .keyboardShortcut(",")
    }

    private var quitButton: some View {
        Button {
            onQuit()
        } label: {
            Text("Quit")
        }
        .keyboardShortcut("q")
    }

    // MARK: - Helpers

    /// Each job is a run of flat rows: a title, then a state row, then its
    /// actions. `MenuStageProgressUpdater` finds a job's state row by that order
    /// (below the queue heading, jobs in queue order), so a disabled row put
    /// between the title and the state row, or a changed order, breaks the
    /// live progress text without any compile error. Keep the order, or change
    /// the updater and its tests with it.
    @ViewBuilder
    private func jobRow(_ job: PipelineJob, index: Int) -> some View {
        Text(job.meetingTitle)
        jobStateLabel(job)

        if job.state == .done,
           let target = JobOpenTarget.resolve(for: job, preferNotion: notionExportEnabled) {
            Button(target.jobActionLabel) { onOpenProtocol(target) }
        }
        if job.state == .speakerNamingPending {
            Button("Name Speakers") { onNameSpeakers?() }
        }
        if job.state == .waiting || job.state == .transcribing
            || job.state == .diarizing || job.state == .generatingProtocol {
            Button("Cancel") { pipelineQueue.cancelJob(id: job.id) }
        }
        retryButton(job, index: index)
        notionRetryButton(job, index: index)
        if job.state == .done || job.state == .error || job.state == .speakerNamingPending {
            Button(job.notionExportStatus == .failed ? "Discard Notion Retry" : "Dismiss") { onDismissJob(job.id) }
                .disabled(job.notionExportStatus == .inProgress)
        }
    }

    /// Runs a failed job again from its audio, instead of the user having to
    /// find the staged recording and import it by hand.
    @ViewBuilder
    private func retryButton(_ job: PipelineJob, index: Int) -> some View {
        if pipelineQueue.canRetryJob(id: job.id) {
            Button("Retry") { pipelineQueue.retryJob(id: job.id) }
                .accessibilityIdentifier(A11yID.jobRetryButton(index))
        }
    }

    @ViewBuilder
    private func notionRetryButton(_ job: PipelineJob, index: Int) -> some View {
        if job.state == .done, job.hasPendingNotionExport {
            Button("Retry Notion Export") {
                Task { await pipelineQueue.retryNotionExport(id: job.id) }
            }
            .accessibilityIdentifier(A11yID.jobNotionRetryButton(index))
            .disabled(!notionExportEnabled || !pipelineQueue.canRetryNotionExport(id: job.id))
            .help(notionExportEnabled ? "" : "Enable Notion export in Settings → Output to retry.")
        }
    }

    @ViewBuilder
    private func jobStateLabel(_ job: PipelineJob) -> some View {
        if StageKind(jobState: job.state) != nil {
            MenuStageProgressLabel(text: MenuStageProgressUpdater.progressText(job: job, queue: pipelineQueue))
        } else if job.state == .error, let msg = job.error {
            Text(msg)
        } else if job.state == .done, job.notionExportStatus == .inProgress {
            Text("Exporting to Notion…")
        } else if job.state == .done, !job.warnings.isEmpty {
            Text(job.warnings.joined(separator: "; "))
        } else {
            Text(job.state.label)
        }
    }
}

/// Keep SwiftUI's text stable for the active row's lifetime. The native updater
/// owns subsequent stage and timer changes so Cancel keeps its hover highlight.
private struct MenuStageProgressLabel: View {
    @State private var text: String

    init(text: String) {
        _text = State(initialValue: text)
    }

    var body: some View {
        Text(text)
    }
}
