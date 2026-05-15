import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Three-stage sheet that seeds `speakers.json` from an existing audio file:
/// 1. Pick file → 2. Diarize → 3. Name speakers (reuses `SpeakerNamingView`)
/// → persists embeddings via the same path as a real meeting.
///
/// Engine-independent: never touches the ASR pipeline, only the FluidAudio
/// diarization side.
struct VoiceEnrollmentView: View {
    let matcher: SpeakerMatcher
    let diarizerFactory: () -> any DiarizationProvider
    let onClose: () -> Void

    @State private var stage: Stage
    @State private var diarizeStart: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var elapsedTimer: Task<Void, Never>?
    @State private var diarizationTask: Task<Void, Never>?

    init(
        matcher: SpeakerMatcher,
        diarizerFactory: @escaping () -> any DiarizationProvider,
        onClose: @escaping () -> Void,
        initialStage: Stage = .pickFile,
    ) {
        self.matcher = matcher
        self.diarizerFactory = diarizerFactory
        self.onClose = onClose
        _stage = State(initialValue: initialStage)
    }

    enum Stage {
        case pickFile
        case diarizing(URL)
        /// Snapshot of everything the naming stage needs — computed once on
        /// entry, NOT re-derived inside the view body on every render.
        case naming(NamingPayload)
        case done(savedNames: [String])
        case error(String)
    }

    struct NamingPayload {
        let url: URL
        let diarization: DiarizationResult
        let namingData: PipelineQueue.SpeakerNamingData
        let knownNames: [String]
        let speakerCount: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Voice from Recording").font(.title2).bold()
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            switch stage {
            case .pickFile: pickFileBody
            case let .diarizing(url): diarizingBody(url: url)
            case let .naming(payload): namingBody(payload: payload)
            case let .done(names): doneBody(savedNames: names)
            case let .error(message): errorBody(message: message)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 420)
        .onDisappear {
            diarizationTask?.cancel()
            stopElapsedTimer()
        }
    }

    // MARK: - Stage views

    private var pickFileBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick an audio file with the speaker(s) you want to enroll.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose File…") { pickFile(initialDirectory: nil) }
                Button("Browse Past Recordings…") {
                    pickFile(initialDirectory: AppPaths.recordingsDir)
                }
            }
            Text(
                "The file is diarized to find speakers, then you name them. "
                    + "Embeddings + centroid land in your speaker DB exactly as if "
                    + "the meeting had just happened.",
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func diarizingBody(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diarizing \(url.lastPathComponent)…").font(.headline)
            HStack {
                ProgressView()
                Text(String(format: "%.0f s elapsed", elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func namingBody(payload: NamingPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Found \(payload.speakerCount) speakers in \(payload.url.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)

            SpeakerNamingView(
                data: payload.namingData,
                knownSpeakerNames: payload.knownNames,
            ) { result in
                switch VoiceEnrollmentLogic.handleNamingResult(
                    result, payload: payload, matcher: matcher,
                ) {
                case let .stage(next): stage = next
                case let .rerun(url, count): startDiarization(url: url, numSpeakers: count)
                }
            }
            .frame(minHeight: 320)
        }
    }

    private func doneBody(savedNames: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enrolled \(savedNames.count) speaker\(savedNames.count == 1 ? "" : "s")")
                .font(.headline)
            if !savedNames.isEmpty {
                Text(savedNames.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func errorBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enrollment failed").font(.headline).foregroundStyle(.red)
            Text(message).foregroundStyle(.secondary)
            HStack {
                Button("Try Again") { stage = .pickFile }
                Spacer()
                Button("Close") { onClose() }
            }
        }
    }

    // MARK: - Actions

    private func pickFile(initialDirectory: URL?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav]
        panel.allowsMultipleSelection = false
        if let initialDirectory {
            try? FileManager.default.createDirectory(
                at: initialDirectory, withIntermediateDirectories: true,
            )
            panel.directoryURL = initialDirectory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startDiarization(url: url, numSpeakers: 0)
    }

    private func startDiarization(url: URL, numSpeakers: Int) {
        stage = .diarizing(url)
        diarizeStart = Date()
        elapsed = 0
        startElapsedTimer()
        diarizationTask?.cancel()
        diarizationTask = Task {
            do {
                let result = try await diarizerFactory().run(
                    audioPath: url, numSpeakers: numSpeakers, meetingTitle: url.lastPathComponent,
                )
                guard !Task.isCancelled else { return }
                stopElapsedTimer()
                if result.segments.isEmpty {
                    stage = .error("No speakers detected in this recording.")
                } else {
                    stage = .naming(VoiceEnrollmentLogic.buildNamingPayload(
                        url: url, diarization: result, matcher: matcher,
                    ))
                }
            } catch is CancellationError {
                // sheet dismissed mid-diarization; nothing to do
            } catch {
                guard !Task.isCancelled else { return }
                stopElapsedTimer()
                stage = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if let start = diarizeStart {
                    elapsed = Date().timeIntervalSince(start)
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }
}

// MARK: - Pure logic (testable without SwiftUI)

/// Pure functions backing `VoiceEnrollmentView`. Separating them out keeps
/// the view's mutating helpers `private` and lets tests assert on the
/// computed outcome instead of poking at `@State`.
enum VoiceEnrollmentLogic {
    /// Outcome of consuming a `SpeakerNamingResult`: either a direct stage
    /// transition, or a request to re-run diarization with N speakers.
    /// The view turns the `.rerun` case into an async Task; the logic itself
    /// stays synchronous and side-effect-free apart from `matcher.updateDB`.
    enum Outcome {
        case stage(VoiceEnrollmentView.Stage)
        case rerun(url: URL, numSpeakers: Int)
    }

    static func handleNamingResult(
        _ result: PipelineQueue.SpeakerNamingResult,
        payload: VoiceEnrollmentView.NamingPayload,
        matcher: SpeakerMatcher,
    ) -> Outcome {
        switch result {
        case let .confirmed(mapping):
            guard let embeddings = payload.diarization.embeddings else {
                return .stage(.error("Diarization produced no embeddings; cannot enroll."))
            }
            matcher.updateDB(
                mapping: mapping,
                embeddings: embeddings,
                speakingTimes: payload.diarization.speakingTimes,
            )
            let saved = Set(mapping.values.filter { !$0.isEmpty }).sorted()
            return .stage(.done(savedNames: saved))

        case .skipped:
            return .stage(.done(savedNames: []))

        case let .rerun(count):
            return .rerun(url: payload.url, numSpeakers: count)
        }
    }

    static func buildNamingPayload(
        url: URL,
        diarization: DiarizationResult,
        matcher: SpeakerMatcher,
    ) -> VoiceEnrollmentView.NamingPayload {
        let knownNames = matcher.allSpeakerNames()
        // Pre-fill auto-name suggestions by running a match against the
        // existing DB. Same flow as a real meeting.
        let autoNames = diarization.embeddings.map { matcher.match(embeddings: $0) } ?? [:]
        let mapping = autoNames.isEmpty
            ? Dictionary(uniqueKeysWithValues: diarization.speakingTimes.keys.map { ($0, $0) })
            : autoNames
        let data = PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: url.lastPathComponent,
            mapping: mapping,
            speakingTimes: diarization.speakingTimes,
            embeddings: diarization.embeddings ?? [:],
            audioPath: url,
            segments: diarization.segments.map { seg in
                PipelineQueue.SpeakerNamingData.Segment(
                    start: seg.start, end: seg.end, speaker: seg.speaker,
                )
            },
            participants: [],
            isDualSource: false,
        )
        let speakerCount = Set(diarization.segments.map(\.speaker)).count
        return VoiceEnrollmentView.NamingPayload(
            url: url,
            diarization: diarization,
            namingData: data,
            knownNames: knownNames,
            speakerCount: speakerCount,
        )
    }
}
