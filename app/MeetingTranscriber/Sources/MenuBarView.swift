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
    let onOpenLastProtocol: () -> Void
    let onOpenProtocol: (URL) -> Void
    let onOpenProtocolsFolder: () -> Void
    let onOpenSettings: () -> Void
    let onNameSpeakers: (() -> Void)?
    let onProcessFiles: () -> Void
    let onDismissJob: (UUID) -> Void
    let onQuit: () -> Void

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

    private var isQueueProcessing: Bool {
        pipelineQueue.isProcessing || pipelineQueue.jobs.contains { job in
            job.state == .waiting || job.state == .transcribing
                || job.state == .diarizing || job.state == .generatingProtocol
        }
    }

    private var queueHeaderTitle: String {
        if isQueueProcessing {
            "Processing"
        } else if pipelineQueue.jobs.contains(where: { $0.state == .speakerNamingPending }) {
            "Needs Attention"
        } else if pipelineQueue.jobs.allSatisfy({ $0.state == .done }) {
            "Completed"
        } else {
            "Queue"
        }
    }

    private var queueHeaderIcon: String {
        if isQueueProcessing {
            "gearshape.2.fill"
        } else if pipelineQueue.jobs.contains(where: { $0.state == .speakerNamingPending }) {
            "person.2.fill"
        } else if pipelineQueue.jobs.allSatisfy({ $0.state == .done }) {
            "checkmark.circle"
        } else {
            "tray.full.fill"
        }
    }

    @ViewBuilder private var processingQueue: some View {
        if !pipelineQueue.jobs.isEmpty {
            Divider()
            Label(queueHeaderTitle, systemImage: queueHeaderIcon)

            ForEach(Array(pipelineQueue.jobs.enumerated()), id: \.element.id) { index, job in
                jobRow(job, index: index)
            }
        }
    }

    @ViewBuilder private var protocolActions: some View {
        if let protocolPath = status?.protocolPath {
            Button {
                onOpenLastProtocol()
            } label: {
                Label("Open Last Protocol", systemImage: "doc.text")
            }
            .keyboardShortcut("o")
            .disabled(protocolPath.isEmpty)
        }

        Button {
            onOpenProtocolsFolder()
        } label: {
            Label("Open Protocols Folder", systemImage: "folder")
        }
    }

    @ViewBuilder private var updateSection: some View {
        if let update = updateChecker?.availableUpdate {
            Divider()
            Button {
                NSWorkspace.shared.open(update.dmgURL ?? update.htmlURL)
            } label: {
                Label(
                    "Update Available: \(update.tagName)",
                    systemImage: "arrow.down.circle.fill",
                )
            }
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

    @ViewBuilder
    private func jobRow(_ job: PipelineJob, index: Int) -> some View {
        Text(job.meetingTitle)
        jobStateLabel(job)

        if job.state == .done, let path = job.protocolPath ?? job.transcriptPath {
            Button("Open") { onOpenProtocol(path) }
        }
        if job.state == .speakerNamingPending {
            Button("Name Speakers") { onNameSpeakers?() }
        }
        if job.state == .waiting || job.state == .transcribing
            || job.state == .diarizing || job.state == .generatingProtocol {
            Button("Cancel") { pipelineQueue.cancelJob(id: job.id) }
        }
        retryButton(job, index: index)
        if job.state == .done || job.state == .error || job.state == .speakerNamingPending {
            Button("Dismiss") { onDismissJob(job.id) }
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
    private func jobStateLabel(_ job: PipelineJob) -> some View {
        if [.transcribing, .diarizing, .generatingProtocol].contains(job.state) {
            MenuStageProgressLabel(text: MenuStageProgressUpdater.progressText(job: job, queue: pipelineQueue))
        } else if job.state == .error, let msg = job.error {
            Text(msg)
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
