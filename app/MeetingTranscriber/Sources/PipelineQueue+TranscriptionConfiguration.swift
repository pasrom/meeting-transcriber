import Foundation

/// Admission captures current settings; restoring does not recapture them.
extension PipelineQueue {
    func transcriptionEngine(for job: PipelineJob) -> (any TranscribingEngine)? {
        engine?.session(for: transcriptionConfiguration(for: job))
    }

    func stampTranscriptionConfiguration(on job: inout PipelineJob) {
        if job.transcriptionConfiguration == nil {
            job.transcriptionConfiguration = transcriptionConfigurationProvider()
        }
    }

    func transcriptionConfiguration(for job: PipelineJob) -> TranscriptionConfiguration {
        if let configuration = job.transcriptionConfiguration { return configuration }
        // A pre-feature job must never acquire translation from current Settings.
        var legacy = engine?.transcriptionConfiguration ?? .init()
        legacy.whisper?.outputMode = .original
        return legacy
    }
}
