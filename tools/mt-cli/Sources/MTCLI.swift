import ArgumentParser
import AVFoundation
import Foundation

@main
struct MTCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mt-cli",
        abstract: "Thin client for the Meeting Transcriber debug RPC server.",
        subcommands: [
            State.self, Healthz.self, Screenshot.self, UITree.self, UIPress.self,
            OpenSettings.self, CloseSettings.self, ConfirmBrowserConsent.self,
            SeedSpeaker.self, RenameSpeaker.self, DeleteSpeaker.self, MergeSpeakers.self,
            WavVerdictCommand.self, Watch.self, Record.self,
        ],
    )
}

/// The verb set both `/v1` lifecycle resources accept.
///
/// `start`/`stop` are offered alongside `toggle` on purpose: a button press
/// expresses a desired end state, and any external controller's view of the app
/// is slightly stale. A blind toggle after a meeting already ended does exactly
/// the wrong thing and stays inverted; the idempotent verbs converge instead.
///
/// Shared by the two subcommands below. Not the wire contract — the server's
/// `WatchAction` and `RecordAction` are, and those stay separate so a verb added
/// to one resource does not silently appear on the other.
enum ControlAction: String, ExpressibleByArgument, CaseIterable {
    case status
    case start
    case stop
    case toggle
}

/// Read or change one `/v1` lifecycle resource, printing the resulting status.
///
/// Always prints the state *after* the call, so a caller can redraw from the
/// response rather than racing a follow-up poll. A refusal surfaces as a thrown
/// `RPCError.http` — non-zero exit with the JSON body in the message.
private func runControl(resource: String, action: ControlAction) async throws {
    let client = try RPCClient.loadDefault()
    let data = action == .status
        ? try await client.get(resource)
        : try await client.post(
            resource, json: ["action": action.rawValue],
            timeout: RPCClient.controlTimeoutSeconds,
        )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// `mt-cli record [status|start|stop|toggle]` — the microphone counterpart to
/// `mt-cli watch`, for a meeting happening in the room rather than in an app
/// (issue #633).
///
/// What differs from watching is the refusals, and both are worth knowing before
/// scripting against it. `409` means something else is being recorded and
/// starting would clobber it. `412` means nothing would be captured: either "No
/// Microphone (app audio only)" is set, or the microphone permission is denied
/// or broken. A 412 will not clear on its own, so a retry loop should stop on
/// it; the printed body says which of the two it was.
struct Record: AsyncParsableCommand {
    /// The resource this command drives. Named rather than inlined at the call
    /// site so a test can pin it: `Record` and `Watch` differ in this one
    /// string, and getting it wrong starts the wrong thing without a compile
    /// error.
    static let resource = "/v1/record"

    static let configuration = CommandConfiguration(
        abstract: "Read or change microphone recording. Prints the resulting status as JSON.",
    )

    @Argument(help: "status (default), start, stop, or toggle.")
    var action: ControlAction = .status

    func run() async throws {
        try await runControl(resource: Self.resource, action: action)
    }
}

/// `mt-cli watch [status|start|stop|toggle]` — the scriptable surface behind a
/// hotkey, a Shortcut or a Stream Deck key.
///
/// A refusal here is `409`: a manual recording owns the loop.
struct Watch: AsyncParsableCommand {
    /// See `Record.resource`.
    static let resource = "/v1/watch"

    static let configuration = CommandConfiguration(
        abstract: "Read or change meeting watching. Prints the resulting status as JSON.",
    )

    @Argument(help: "status (default), start, stop, or toggle.")
    var action: ControlAction = .status

    func run() async throws {
        try await runControl(resource: Self.resource, action: action)
    }
}

struct State: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the current pipeline + speaker DB state as JSON.",
    )

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.get("/state")
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct Healthz: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Probe the RPC server. Exits 0 when reachable, non-zero otherwise.",
    )

    func run() async throws {
        let client = try RPCClient.loadDefault()
        _ = try await client.get("/healthz")
        print("ok")
    }
}

struct OpenSettings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-settings",
        abstract: "Open the app's Settings window.",
    )

    func run() async throws {
        let client = try RPCClient.loadDefault()
        _ = try await client.post("/action/openSettings", json: [:])
        print("ok")
    }
}

struct CloseSettings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-settings",
        abstract: "Close the Settings window if it is open.",
    )

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.post("/action/closeSettings", json: [:])
        FileHandle.standardOutput.write(data)
    }
}

struct ConfirmBrowserConsent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "confirm-browser-consent",
        abstract: "Answer a parked browser-meeting consent prompt (issue #503). "
            + "Prints the server's {\"resolved\":bool} JSON; resolved:false means "
            + "no prompt was waiting yet, so poll until true.",
    )

    @Flag(inversion: .prefixedNo, help: "Grant recording (default) or --no-granted to decline.")
    var granted = true

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.post("/action/confirmBrowserConsent", json: ["granted": granted])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// Sync ParsableCommand (not Async) — the analysis + file load are synchronous,
// so a `run() async` would be an async_without_await. ArgumentParser dispatches
// a sync subcommand of an async root fine.
struct WavVerdictCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wav-verdict",
        abstract: "Analyze an audio file's loudness (issue #503 capture proof). "
            + "Prints a JSON verdict; exits 0 when non-silent AND at least "
            + "--min-active-seconds of audio is above the threshold, 1 otherwise.",
    )

    @Argument(help: "Path to the WAV/audio file to analyze.")
    var path: String

    @Option(name: .long, help: "dBFS threshold below which a window is silent. Default -50.")
    var thresholdDbfs: Double = -50

    /// Seconds rather than a fraction of the file: every recording carries
    /// trailing silence (grace period, then finalisation) whose length varies
    /// run to run, so a ratio floor gates on how long the recording happened to
    /// be rather than on how much audio was captured.
    @Option(name: .long, help: "Minimum seconds of audio above the threshold to pass. Default 3.")
    var minActiveSeconds: Double = 3

    @Option(name: .long, help: "Analysis window length in seconds. Default 0.5.")
    var windowSeconds: Double = 0.5

    func run() throws {
        let (samples, sampleRate) = try Self.loadSamples(path: path)
        let verdict = WavVerdict.analyze(
            samples: samples, sampleRate: sampleRate,
            windowSeconds: windowSeconds, thresholdDBFS: thresholdDbfs,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileHandle.standardOutput.write(encoder.encode(verdict))
        FileHandle.standardOutput.write(Data("\n".utf8))
        // Non-zero exit if silent or too little audio, so a driver can gate on
        // the exit code alone. Which of the two failed goes to stderr: they
        // mean different things, and a caller reporting "silent" for a file
        // whose own verdict says `isSilent: false` sends the reader hunting in
        // the wrong place.
        if verdict.isSilent {
            FileHandle.standardError.write(Data(
                "silent: no window above \(thresholdDbfs) dBFS\n".utf8,
            ))
            throw ExitCode(1)
        }
        if verdict.activeSeconds < minActiveSeconds {
            let reason = "too little audio: \(verdict.activeSeconds)s above "
                + "\(thresholdDbfs) dBFS, need \(minActiveSeconds)s\n"
            FileHandle.standardError.write(Data(reason.utf8))
            throw ExitCode(1)
        }
    }

    /// Load an audio file as mono Float32 samples via AVAudioFile, averaging any
    /// channels down to mono. Thin I/O layer — the verdict logic stays pure.
    static func loadSamples(path: String) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return ([], format.sampleRate) }
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< channels {
                sum += channelData[channel][frame]
            }
            mono[frame] = sum / Float(channels)
        }
        return (mono, format.sampleRate)
    }
}

/// POST a JSON action to the RPC server and write the response body + newline
/// to stdout. Shared by every action subcommand that returns the server's
/// outcome JSON unchanged.
private func postAction(_ path: String, _ payload: [String: String]) async throws {
    let client = try RPCClient.loadDefault()
    let data = try await client.post(path, json: payload)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

struct SeedSpeaker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed-speaker",
        abstract: "Insert a synthetic speaker with a random embedding (testing only).",
    )

    @Argument(help: "Name of the speaker to seed.")
    var name: String

    func run() async throws {
        try await postAction("/action/seedSpeaker", ["name": name])
    }
}

struct RenameSpeaker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename-speaker",
        abstract: "Rename a speaker in the persisted DB. Merges if the target name exists.",
    )

    @Argument(help: "Current name of the speaker.")
    var from: String

    @Argument(help: "New name. If a speaker already has this name, the two are merged.")
    var to: String

    func run() async throws {
        try await postAction("/action/renameSpeaker", ["from": from, "to": to])
    }
}

struct DeleteSpeaker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-speaker",
        abstract: "Remove a speaker from the persisted DB.",
    )

    @Argument(help: "Name of the speaker to delete.")
    var name: String

    func run() async throws {
        try await postAction("/action/deleteSpeaker", ["name": name])
    }
}

struct MergeSpeakers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge-speakers",
        abstract: "Merge one speaker into another. Embeddings, centroid and counts are combined.",
    )

    @Argument(help: "Source speaker — its data is merged into the target and the source is removed.")
    var from: String

    @Argument(help: "Target speaker — receives the source's embeddings and centroid.")
    var into: String

    func run() async throws {
        try await postAction("/action/mergeSpeakers", ["from": from, "into": into])
    }
}

struct UITree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui-tree",
        abstract: "Print the accessibility tree of an allowed app window as JSON. "
            + "Assert on UI structure (a section exists, a control is enabled) "
            + "instead of eyeballing a screenshot.",
    )

    @Option(name: .long, help: "Window identifier to introspect. Defaults to settings.")
    var window: String = "settings"

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.get("/ui/tree?window=\(window)")
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// Mirrors the server's `UIPressVia` (`DebugRPCServer+UIPress.swift`): `ax` (the
/// default) performs `kAXPressAction` directly; `click` posts a real mouse click,
/// needed for a `List(selection:)` row (e.g. a Settings sidebar tab) that accepts
/// an AX press and reports success without actually selecting itself.
enum PressVia: String, ExpressibleByArgument {
    case ax
    case click
}

struct UIPress: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui-press",
        abstract: "Press a control (by accessibility identifier) in an allowed app window. "
            + "Drives a real in-process UI action — assert the effect via `state`, "
            + "not the returned `pressed` flag.",
    )

    @Argument(help: "Accessibility identifier of the control to press.")
    var identifier: String

    @Option(name: .long, help: "Window identifier the control lives in. Defaults to settings.")
    var window: String = "settings"

    @Option(
        name: .long,
        help: "How to actuate the control: ax (default) or click. Use click for a sidebar tab row, which an ax press reports as pressed without selecting.",
    )
    var via: PressVia?

    func run() async throws {
        var payload = ["window": window, "identifier": identifier]
        if let via { payload["via"] = via.rawValue }
        try await postAction("/ui/press", payload)
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a PNG of the app's frontmost window.",
    )

    @Argument(help: "Output PNG path. Defaults to ./screenshot.png.")
    var path: String = "screenshot.png"

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.get("/screenshot", timeout: RPCClient.screenshotTimeoutSeconds)
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(data.count) bytes to \(path)")
    }
}
