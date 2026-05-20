import AppKit
import AVFoundation
import Foundation
import IOKit.pwr_mgt

// --- CLI parsing ---
// Backwards-compatible: positional args [audio.wav] [window-title] still work.
// Flag args (any position): --silent, --duration=<seconds>.

var silentMode = false
var durationOverride: TimeInterval?
var positionals: [String] = []

for arg in CommandLine.arguments.dropFirst() {
    if arg == "--silent" {
        silentMode = true
    } else if arg.hasPrefix("--duration=") {
        let raw = String(arg.dropFirst("--duration=".count))
        guard let sec = TimeInterval(raw), sec > 0 else {
            print("ERROR: --duration expects a positive number of seconds, got '\(raw)'")
            exit(2)
        }
        durationOverride = sec
    } else if arg == "-h" || arg == "--help" {
        print("""
        Usage: meeting-simulator [audio.wav] [window-title] [--silent] [--duration=<seconds>]

          audio.wav       Path to a fixture WAV played through the system output.
                          Ignored when --silent is set.
          window-title    Window title (must match a MeetingDetector pattern for
                          the app to auto-detect this as a meeting).
          --silent        Skip audio playback entirely. The window + power
                          assertion still fire so detection triggers, but the
                          CATapDescription tap sees only zero buffers — exercises
                          the silent-recording detection path end-to-end.
          --duration=N    Auto-terminate after N seconds. Default: audio duration
                          + 2s when playing, or 60s when --silent.
        """)
        exit(0)
    } else {
        positionals.append(arg)
    }
}

// Fixture is needed even in --silent mode: AVAudioPlayer needs SOME
// PCM source to pump zero-content frames through the audio device
// so CATapDescription's IOProc fires and the recorder produces full
// silent buffers (rather than the no-producer case where the device
// goes idle and the recording is zero bytes).
let fixturePath: String = if let arg = positionals.first {
    arg
} else {
    findFixture()
}

let windowTitle = positionals.count > 1
    ? positionals[1]
    : "Simulator Meeting | MeetingSimulator"

// --- Find fixture audio ---
//
// The fixture lives at `app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav`
// in the repo. `#filePath` resolves to the absolute path of this source
// file at compile time, so walking up from it lands at the repo root
// regardless of where the binary is later executed — works for both
// `swift run` in the package dir and a built binary copied elsewhere,
// as long as the source was compiled from the repo checkout.
private let fixtureRepoRelativePath = "app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav"

func findFixture() -> String {
    // Walk Sources/ → meeting-simulator/ → tools/ → repo root. Four
    // deletions: the fourth is the one that actually lands at the repo
    // root; without it we'd end up at `tools/` and append a path that
    // has never existed.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fromSource = repoRoot.appendingPathComponent(fixtureRepoRelativePath)
    if FileManager.default.fileExists(atPath: fromSource.path) {
        return fromSource.path
    }
    // Fallback: a CWD-relative lookup so a user running the binary from
    // the repo root (e.g. `tools/meeting-simulator/.build/.../meeting-simulator`)
    // still works even if `#filePath` resolved to a stale clone path.
    if FileManager.default.fileExists(atPath: fixtureRepoRelativePath) {
        return fixtureRepoRelativePath
    }
    print("ERROR: Fixture not found at \(fromSource.path) or \(fixtureRepoRelativePath)")
    print("Usage: meeting-simulator [audio.wav] [window-title] [--silent] [--duration=<seconds>]")
    exit(1)
}

// --- Setup NSApplication ---
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Create window
let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered,
    defer: false,
)
window.title = windowTitle
window.isReleasedWhenClosed = false

// --- Build meeting-like UI ---
let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

// Status label
let label = NSTextField(labelWithString: "Loading audio...")
label.font = .systemFont(ofSize: 24)
label.alignment = .center
label.frame = NSRect(x: 50, y: 300, width: 700, height: 100)
contentView.addSubview(label)

// Meeting toolbar (mimics Teams call controls)
let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 60))
toolbar.wantsLayer = true
toolbar.layer?.backgroundColor = NSColor.darkGray.cgColor

// Mute button
let muteBtn = NSButton(title: "Mute", target: nil, action: nil)
muteBtn.frame = NSRect(x: 200, y: 15, width: 80, height: 30)
muteBtn.setAccessibilityLabel("Mute")
toolbar.addSubview(muteBtn)

// Camera button
let cameraBtn = NSButton(title: "Camera", target: nil, action: nil)
cameraBtn.frame = NSRect(x: 300, y: 15, width: 80, height: 30)
toolbar.addSubview(cameraBtn)

// Share button
let shareBtn = NSButton(title: "Share", target: nil, action: nil)
shareBtn.frame = NSRect(x: 400, y: 15, width: 80, height: 30)
toolbar.addSubview(shareBtn)

// Leave button (red, like Teams)
let leaveBtn = NSButton(title: "Leave", target: nil, action: #selector(AppDelegate.leaveClicked))
leaveBtn.frame = NSRect(x: 520, y: 15, width: 80, height: 30)
leaveBtn.bezelColor = .systemRed
leaveBtn.setAccessibilityLabel("Leave")
leaveBtn.setAccessibilityIdentifier("leave-call")
toolbar.addSubview(leaveBtn)

contentView.addSubview(toolbar)
window.contentView = contentView

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

// --- Create power assertion (triggers PowerAssertionDetector) ---
var assertionID: IOPMAssertionID = 0
let assertionResult = IOPMAssertionCreateWithName(
    "PreventUserIdleDisplaySleep" as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn),
    "Simulator Meeting Call in progress" as CFString,
    &assertionID,
)
if assertionResult == kIOReturnSuccess {
    print("Power assertion created (ID: \(assertionID))")
} else {
    print("WARNING: Could not create power assertion (status: \(assertionResult))")
}

print("Window: \"\(windowTitle)\"")
print("PID: \(ProcessInfo.processInfo.processIdentifier)")
print(silentMode ? "Audio: <silent mode — no playback>" : "Audio: \(fixturePath)")
print("Leave button visible for AX verification")

// --- App delegate to handle window close + audio end ---
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AVAudioPlayerDelegate {
    func applicationWillTerminate(_: Notification) {
        IOPMAssertionRelease(assertionID)
    }

    func windowWillClose(_: Notification) {
        print("Window closed — exiting.")
        NSApplication.shared.terminate(nil)
    }

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        print("Audio finished — closing in 2s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSApplication.shared.terminate(nil)
        }
    }

    @objc
    func leaveClicked() {
        print("Leave clicked — closing.")
        NSApplication.shared.terminate(nil)
    }
}

let delegate = AppDelegate()
app.delegate = delegate
window.delegate = delegate

var audioPlayer: AVAudioPlayer?

if silentMode {
    let duration = durationOverride ?? 60
    // Play the fixture at volume=0. AVAudioPlayer still pumps PCM
    // frames through the system audio chain — the default output
    // device stays active, CATapDescription's IOProc fires, the
    // tap captures buffers (all zeros after the volume scaling).
    // Without playing anything at all the tap stays subscribed but
    // gets no callbacks because the device has no producer, so
    // the recording file ends up zero bytes — wrong failure mode
    // for the symmetric-silence detector under test.
    let audioURL = URL(fileURLWithPath: fixturePath)
    if FileManager.default.fileExists(atPath: fixturePath) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            audioPlayer?.delegate = delegate
            audioPlayer?.volume = 0
            audioPlayer?.numberOfLoops = -1 // loop until the duration timer fires
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            label.stringValue = "SILENT MODE\n(zero-volume playback, \(Int(duration))s)"
            print("Silent mode: playing fixture at volume=0 for \(duration)s.")
        } catch {
            print("ERROR: Could not play fixture at volume 0: \(error)")
            label.stringValue = "Silent mode (audio error — tap may be inactive)"
        }
    } else {
        // Fallback for environments without the fixture: still pop
        // the window + power assertion, but warn that the recorder
        // path may produce zero-byte files because nothing drives
        // the audio device.
        label.stringValue = "SILENT MODE\n(no fixture — tap will be inactive)"
        print("Silent mode: fixture not found, no audio device producer.")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        print("Duration elapsed — closing.")
        NSApplication.shared.terminate(nil)
    }
} else {
    // --- Play audio ---
    let audioURL = URL(fileURLWithPath: fixturePath)
    guard FileManager.default.fileExists(atPath: fixturePath) else {
        print("ERROR: Audio file not found: \(fixturePath)")
        exit(1)
    }
    do {
        audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
        audioPlayer?.delegate = delegate
        audioPlayer?.prepareToPlay()
        audioPlayer?.play()
        let duration = audioPlayer?.duration ?? 0
        label.stringValue = "Playing \(URL(fileURLWithPath: fixturePath).lastPathComponent)\n(\(String(format: "%.0f", duration))s)"
        print("Playing audio (\(String(format: "%.1f", duration))s)...")
        print("Window closes automatically after playback.")
    } catch {
        print("ERROR: Could not play audio: \(error)")
        label.stringValue = "Audio error: \(error.localizedDescription)"
    }
    if let override = durationOverride {
        DispatchQueue.main.asyncAfter(deadline: .now() + override) {
            print("Duration elapsed — closing.")
            NSApplication.shared.terminate(nil)
        }
    }
}

// Run
app.run()
