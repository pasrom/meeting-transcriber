import AppKit
import AVFoundation
import Foundation

// --- Configuration ---
let fixturePath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : findFixture()

let windowTitle = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "Simulator Meeting | MeetingSimulator"

// --- Find fixture audio ---
func findFixture() -> String {
    // Walk up from executable to find project root
    let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Sources/
        .deletingLastPathComponent() // meeting-simulator/
        .deletingLastPathComponent() // tools/
    let fixture = dir.appendingPathComponent("tests/fixtures/two_speakers_de.wav")
    if FileManager.default.fileExists(atPath: fixture.path) {
        return fixture.path
    }
    // Try relative
    let relative = "tests/fixtures/two_speakers_de.wav"
    if FileManager.default.fileExists(atPath: relative) {
        return relative
    }
    print("ERROR: Fixture not found. Pass audio path as first argument.")
    print("Usage: meeting-simulator [audio.wav] [window-title]")
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

print("Window: \"\(windowTitle)\"")
print("PID: \(ProcessInfo.processInfo.processIdentifier)")
print("Audio: \(fixturePath)")
print("Leave button visible for AX verification")

// --- Play audio ---
let audioURL = URL(fileURLWithPath: fixturePath)
guard FileManager.default.fileExists(atPath: fixturePath) else {
    print("ERROR: Audio file not found: \(fixturePath)")
    exit(1)
}

// --- App delegate to handle window close + audio end ---
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AVAudioPlayerDelegate {
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

// Run
app.run()
