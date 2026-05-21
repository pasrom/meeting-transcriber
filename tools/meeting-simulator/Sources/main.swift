import AppKit
import ArgumentParser
import AVFoundation
import Foundation
import IOKit.pwr_mgt

@main
struct MeetingSimulator: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meeting-simulator",
        abstract: "Synthetic meeting trigger for the dev app's auto-detect path.",
        discussion: """
        Pops a window with a MeetingDetector-matching title and creates the same
        IOKit power assertion a real Teams / Zoom call would. Plays the fixture
        WAV through the system output so the CATapDescription tap captures real
        audio. With --silent, the fixture is played at volume=0 so the audio
        device stays active but the tap captures only zero-content buffers —
        used by scripts/e2e-silent-recording.sh to exercise the
        SilentRecordingMonitor path end-to-end.
        """,
    )

    @Argument(help: "Path to fixture WAV. Defaults to the repo's two_speakers_de.wav.")
    var audioPath: String?

    @Argument(help: "Window title. Must match a MeetingDetector pattern for auto-detect to fire.")
    var windowTitle: String = "Simulator Meeting | MeetingSimulator"

    @Flag(help: """
    Play the fixture at volume=0 so the audio device stays active but produces
    zero-content buffers. Without this the CATapDescription tap has no producer
    and gets no IOProc callbacks, so the recording file ends up zero bytes.
    """)
    var silent = false

    @Option(name: .long, help: """
    Auto-terminate after N seconds. Defaults: audio duration + 2 s (without
    --silent) or 60 s (with --silent, where there's no
    audioPlayerDidFinishPlaying callback to drive the natural exit).
    """)
    var duration: Double?

    func validate() throws {
        if let duration, duration <= 0 {
            throw ValidationError("--duration must be a positive number of seconds, got \(duration).")
        }
    }

    func run() {
        let fixturePath = audioPath ?? Self.findFixture()
        let title = windowTitle
        let silentMode = silent
        let dur = duration
        MainActor.assumeIsolated {
            runSimulator(fixturePath: fixturePath, windowTitle: title, silent: silentMode, duration: dur)
        }
    }

    /// Locate the repo's bundled fixture WAV.
    ///
    /// `#filePath` resolves to the absolute path of this source file at
    /// compile time, so walking up from it lands at the repo root regardless
    /// of where the binary is later executed — works for both `swift run`
    /// in the package dir and a built binary copied elsewhere, as long as
    /// the source was compiled from the repo checkout.
    private static let fixtureRepoRelativePath = "app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav"

    private static func findFixture() -> String {
        // Walk Sources/ → meeting-simulator/ → tools/ → repo root. The
        // fourth deletion is the one that actually lands at the repo
        // root; without it we'd end up at `tools/` and append a path
        // that has never existed.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fromSource = repoRoot.appendingPathComponent(fixtureRepoRelativePath)
        if FileManager.default.fileExists(atPath: fromSource.path) {
            return fromSource.path
        }
        // Fallback for binaries run from the repo root.
        if FileManager.default.fileExists(atPath: fixtureRepoRelativePath) {
            return fixtureRepoRelativePath
        }
        FileHandle.standardError.write(Data(
            "ERROR: Fixture not found at \(fromSource.path) or \(fixtureRepoRelativePath)\n".utf8,
        ))
        FileHandle.standardError.write(Data(
            "Pass the audio path as the first positional argument, or `--help` for usage.\n".utf8,
        ))
        Self.exit(withError: ExitCode.failure)
    }
}

// MARK: - Simulator runtime

/// Default --duration when --silent is set, since silent mode has no
/// `audioPlayerDidFinishPlaying` to drive a natural exit.
private let defaultSilentDuration: Double = 60

/// AppKit lifecycle isn't reentrant — `NSApplication.shared.run()` blocks
/// forever once started. This runs the whole window + audio + assertion
/// dance from inside ArgumentParser's `run()` and never returns.
@MainActor
func runSimulator(fixturePath: String, windowTitle: String, silent: Bool, duration: Double?) {
    // Fail fast before any AppKit / IOKit state is created.
    guard FileManager.default.fileExists(atPath: fixturePath) else {
        FileHandle.standardError.write(Data("ERROR: Audio file not found: \(fixturePath)\n".utf8))
        exit(1)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let (window, label) = buildMeetingWindow(title: windowTitle)
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    let assertionID = createPowerAssertion()
    print("Window: \"\(windowTitle)\"")
    print("PID: \(ProcessInfo.processInfo.processIdentifier)")
    print(silent ? "Audio: <silent mode — zero-volume playback>" : "Audio: \(fixturePath)")
    print("Leave button visible for AX verification")

    let delegate = AppDelegate(assertionID: assertionID)
    app.delegate = delegate
    window.delegate = delegate

    // Non-silent mode without an explicit --duration exits via the audio
    // player's finish callback, so its effective duration is nil.
    let effectiveDuration = duration ?? (silent ? defaultSilentDuration : nil)
    startPlayback(
        fixturePath: fixturePath,
        silent: silent,
        silentDuration: effectiveDuration ?? defaultSilentDuration,
        label: label,
        delegate: delegate,
    )

    if let effectiveDuration {
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDuration) {
            MainActor.assumeIsolated {
                print("Duration elapsed — closing.")
                NSApplication.shared.terminate(nil)
            }
        }
    }

    app.run()
}

/// Builds the window + content view + Teams-style toolbar. Returns the
/// window and the status label so callers can update it during playback.
@MainActor
private func buildMeetingWindow(title: String) -> (NSWindow, NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false,
    )
    window.title = title
    window.isReleasedWhenClosed = false

    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

    let label = NSTextField(labelWithString: "Loading audio...")
    label.font = .systemFont(ofSize: 24)
    label.alignment = .center
    label.frame = NSRect(x: 50, y: 300, width: 700, height: 100)
    contentView.addSubview(label)

    let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 60))
    toolbar.wantsLayer = true
    toolbar.layer?.backgroundColor = NSColor.darkGray.cgColor

    let muteBtn = NSButton(title: "Mute", target: nil, action: nil)
    muteBtn.frame = NSRect(x: 200, y: 15, width: 80, height: 30)
    muteBtn.setAccessibilityLabel("Mute")
    toolbar.addSubview(muteBtn)

    let cameraBtn = NSButton(title: "Camera", target: nil, action: nil)
    cameraBtn.frame = NSRect(x: 300, y: 15, width: 80, height: 30)
    toolbar.addSubview(cameraBtn)

    let shareBtn = NSButton(title: "Share", target: nil, action: nil)
    shareBtn.frame = NSRect(x: 400, y: 15, width: 80, height: 30)
    toolbar.addSubview(shareBtn)

    let leaveBtn = NSButton(title: "Leave", target: nil, action: #selector(AppDelegate.leaveClicked))
    leaveBtn.frame = NSRect(x: 520, y: 15, width: 80, height: 30)
    leaveBtn.bezelColor = .systemRed
    leaveBtn.setAccessibilityLabel("Leave")
    leaveBtn.setAccessibilityIdentifier("leave-call")
    toolbar.addSubview(leaveBtn)

    contentView.addSubview(toolbar)
    window.contentView = contentView
    return (window, label)
}

/// Creates the same IOKit "prevent display sleep" assertion a real Teams /
/// Zoom call creates; `PowerAssertionDetector` picks it up via
/// `IOPMCopyAssertionsByProcess`. Returns the assertion ID so `AppDelegate`
/// can release it on termination.
private func createPowerAssertion() -> IOPMAssertionID {
    var assertionID: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
        "PreventUserIdleDisplaySleep" as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "Simulator Meeting Call in progress" as CFString,
        &assertionID,
    )
    if result == kIOReturnSuccess {
        print("Power assertion created (ID: \(assertionID))")
    } else {
        print("WARNING: Could not create power assertion (status: \(result))")
    }
    return assertionID
}

@MainActor
private func startPlayback(
    fixturePath: String,
    silent: Bool,
    silentDuration: Double,
    label: NSTextField,
    delegate: AppDelegate,
) {
    let audioURL = URL(fileURLWithPath: fixturePath)
    do {
        let player = try AVAudioPlayer(contentsOf: audioURL)
        player.delegate = delegate
        if silent {
            // Volume=0 + loop forever keeps the audio device active so the
            // CATapDescription tap fires its IOProc and captures
            // zero-content buffers. Skipping playback entirely (no
            // `AVAudioPlayer` at all) leaves the device with no producer —
            // the tap stays subscribed but gets no callbacks, and the
            // recording file ends up zero bytes.
            player.volume = 0
            player.numberOfLoops = -1
            let seconds = Int(silentDuration)
            label.stringValue = "SILENT MODE\n(zero-volume playback, \(seconds)s)"
            print("Silent mode: playing fixture at volume=0 for \(seconds)s.")
        } else {
            label.stringValue = "Playing \(audioURL.lastPathComponent)\n"
                + "(\(String(format: "%.0f", player.duration))s)"
            print("Playing audio (\(String(format: "%.1f", player.duration))s)...")
            print("Window closes automatically after playback.")
        }
        player.prepareToPlay()
        player.play()
        delegate.audioPlayer = player
    } catch {
        print("ERROR: Could not play audio: \(error)")
        label.stringValue = "Audio error: \(error.localizedDescription)"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AVAudioPlayerDelegate {
    let assertionID: IOPMAssertionID
    var audioPlayer: AVAudioPlayer?

    init(assertionID: IOPMAssertionID) {
        self.assertionID = assertionID
    }

    func applicationWillTerminate(_: Notification) {
        IOPMAssertionRelease(assertionID)
    }

    func windowWillClose(_: Notification) {
        print("Window closed — exiting.")
        NSApplication.shared.terminate(nil)
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        print("Audio finished — closing in 2s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @objc
    func leaveClicked() {
        print("Leave clicked — closing.")
        NSApplication.shared.terminate(nil)
    }
}
