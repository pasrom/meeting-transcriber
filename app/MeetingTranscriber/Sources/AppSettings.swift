import SwiftUI

private let defaults = UserDefaults.standard

@Observable
final class AppSettings {
    // MARK: - Apps to Watch

    var watchTeams: Bool = defaults.object(forKey: "watchTeams") as? Bool ?? true {
        didSet { defaults.set(watchTeams, forKey: "watchTeams") }
    }

    var watchZoom: Bool = defaults.object(forKey: "watchZoom") as? Bool ?? true {
        didSet { defaults.set(watchZoom, forKey: "watchZoom") }
    }

    var watchWebex: Bool = defaults.object(forKey: "watchWebex") as? Bool ?? true {
        didSet { defaults.set(watchWebex, forKey: "watchWebex") }
    }

    // MARK: - Recording

    var pollInterval: Double = defaults.object(forKey: "pollInterval") as? Double ?? 3.0 {
        didSet {
            if pollInterval < 1.0 { pollInterval = 1.0 }
            defaults.set(pollInterval, forKey: "pollInterval")
        }
    }

    var endGrace: Double = defaults.object(forKey: "endGrace") as? Double ?? 15.0 {
        didSet {
            if endGrace < 5.0 { endGrace = 5.0 }
            defaults.set(endGrace, forKey: "endGrace")
        }
    }

    var noMic: Bool = defaults.object(forKey: "noMic") as? Bool ?? false {
        didSet { defaults.set(noMic, forKey: "noMic") }
    }

    // MARK: - Transcription

    var whisperModel: String = defaults.object(forKey: "whisperModel") as? String ?? "large-v3-turbo-q5_0" {
        didSet { defaults.set(whisperModel, forKey: "whisperModel") }
    }

    var diarize: Bool = defaults.object(forKey: "diarize") as? Bool ?? false {
        didSet { defaults.set(diarize, forKey: "diarize") }
    }

    var numSpeakers: Int = defaults.object(forKey: "numSpeakers") as? Int ?? 2 {
        didSet {
            if numSpeakers < 2 { numSpeakers = 2 }
            defaults.set(numSpeakers, forKey: "numSpeakers")
        }
    }

    // MARK: - Computed

    var watchApps: [String] {
        var apps: [String] = []
        if watchTeams { apps.append("Microsoft Teams") }
        if watchZoom { apps.append("Zoom") }
        if watchWebex { apps.append("Webex") }
        return apps
    }

    func buildArguments() -> [String] {
        var args = ["--watch"]

        // Apps
        let apps = watchApps
        if !apps.isEmpty && apps.count < 3 {
            args += ["--watch-apps"] + apps
        }

        // Recording
        if pollInterval != 3.0 {
            args += ["--poll-interval", String(pollInterval)]
        }
        if endGrace != 15.0 {
            args += ["--end-grace", String(endGrace)]
        }
        if noMic {
            args.append("--no-mic")
        }

        // Transcription
        if whisperModel != "large-v3-turbo-q5_0" {
            args += ["--model", whisperModel]
        }
        if diarize {
            args.append("--diarize")
            args += ["--speakers", String(numSpeakers)]
        }

        return args
    }
}
