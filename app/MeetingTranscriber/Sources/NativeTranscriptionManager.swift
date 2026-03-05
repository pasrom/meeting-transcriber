import Foundation

/// Coordinates native WhisperKit transcription + Python protocol generation.
@Observable
final class NativeTranscriptionManager {
    let engine = WhisperKitEngine()

    private var ipcDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
    }

    /// Transcribe audio with WhisperKit, save transcript, then spawn Python for protocol.
    func handleRecordingDone(audioPath: String, meetingTitle: String, pythonProcess: PythonProcess) async {
        let audioURL = URL(fileURLWithPath: audioPath)

        guard FileManager.default.fileExists(atPath: audioPath) else {
            NSLog("NativeTranscriptionManager: audio file not found: \(audioPath)")
            return
        }

        do {
            // 1. Load model if needed
            if engine.modelState != .loaded {
                await engine.loadModel()
            }

            guard engine.modelState == .loaded else {
                NSLog("NativeTranscriptionManager: failed to load WhisperKit model")
                return
            }

            // 2. Transcribe with WhisperKit
            let transcript = try await engine.transcribe(audioPath: audioURL)

            guard !transcript.isEmpty else {
                NSLog("NativeTranscriptionManager: transcription produced empty result")
                return
            }

            // 3. Save transcript to IPC directory
            let transcriptPath = ipcDir.appendingPathComponent("native_transcript.txt")
            try transcript.write(to: transcriptPath, atomically: true, encoding: .utf8)
            NSLog("NativeTranscriptionManager: transcript saved to \(transcriptPath.path)")

            // 4. Spawn Python for protocol generation
            pythonProcess.start(arguments: [
                "--file", transcriptPath.path,
                "--title", meetingTitle,
            ])
        } catch {
            NSLog("NativeTranscriptionManager: transcription failed: \(error)")
        }
    }
}
