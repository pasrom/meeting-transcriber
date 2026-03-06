import Foundation

/// Polls the IPC directory for speaker request files from diarize.py.
/// Fires callbacks when requests appear.
class IPCPoller {
    private let ipcDir: URL
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var seenFiles: Set<String> = []

    var onSpeakerCountRequest: ((SpeakerCountRequest) -> Void)?
    var onSpeakerRequest: ((SpeakerRequest) -> Void)?

    init(
        ipcDir: URL? = nil,
        pollInterval: TimeInterval = 1.0
    ) {
        self.ipcDir = ipcDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        self.pollInterval = pollInterval
    }

    func start() {
        stop()
        seenFiles.removeAll()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 1.0))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() {
        checkFile("speaker_count_request.json") { (request: SpeakerCountRequest) in
            self.onSpeakerCountRequest?(request)
        }
        checkFile("speaker_request.json") { (request: SpeakerRequest) in
            self.onSpeakerRequest?(request)
        }
    }

    private func checkFile<T: Decodable>(_ filename: String, handler: (T) -> Void) {
        guard !seenFiles.contains(filename) else { return }
        let url = ipcDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(T.self, from: data) else { return }
        seenFiles.insert(filename)
        handler(request)
    }

    /// Reset seen files (call after diarization completes to allow next session).
    func reset() {
        seenFiles.removeAll()
    }
}
