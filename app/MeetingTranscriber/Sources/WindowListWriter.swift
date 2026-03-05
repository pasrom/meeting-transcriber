import CoreGraphics
import Foundation

/// Periodically writes on-screen window info to ~/.meeting-transcriber/windows.json
/// so the Python subprocess can detect meetings without needing Screen Recording permission.
final class WindowListWriter {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "WindowListWriter", qos: .utility)
    private let outputURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outputURL = dir.appendingPathComponent("windows.json")
    }

    func start(interval: TimeInterval = 1.0) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            self?.writeWindowList()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        // Clean up file so Python doesn't read stale data
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func writeWindowList() {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        // Only include windows from apps we care about to keep the file small
        let targetOwners: Set<String> = [
            "Microsoft Teams", "Microsoft Teams (work or school)",
            "zoom.us", "Webex", "Cisco Webex Meetings",
        ]

        var entries: [[String: Any]] = []
        for window in windowList {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  targetOwners.contains(owner)
            else { continue }

            var entry: [String: Any] = [
                "kCGWindowOwnerName": owner,
                "kCGWindowOwnerPID": window[kCGWindowOwnerPID as String] ?? 0,
            ]
            if let name = window[kCGWindowName as String] as? String {
                entry["kCGWindowName"] = name
            }
            if let bounds = window[kCGWindowBounds as String] {
                entry["kCGWindowBounds"] = bounds
            }
            entries.append(entry)
        }

        // Atomic write via temp file + rename
        guard let data = try? JSONSerialization.data(
            withJSONObject: entries, options: []
        ) else { return }

        let tmp = outputURL.deletingLastPathComponent()
            .appendingPathComponent("windows.json.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.moveItem(at: tmp, to: outputURL)
        } catch {
            // moveItem fails if destination exists — overwrite
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.moveItem(at: tmp, to: outputURL)
        }
    }
}
