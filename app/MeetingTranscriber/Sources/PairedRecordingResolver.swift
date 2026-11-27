import Foundation

/// Groups a flat list of URLs into dual-source recording groups (`_app`+`_mic`
/// or `_mix` sharing a stem) plus singletons — so re-importing a recording
/// produces one dual-track `PipelineJob` instead of two independent jobs.
///
/// Which containers count as tracks is the caller's choice. The default is WAV
/// only, which is what the staging scans need (staging never holds anything
/// else). An import passes `RecordingFileSuffix.keptExtensions`, so tracks the
/// app compressed in the output folder pair as they did as WAV; a stem with
/// both spellings of one track takes the WAV.
enum PairedRecordingResolver {
    struct Group: Equatable {
        let stem: String
        let directory: URL
        let mix: URL?
        let app: URL?
        let mic: URL?
    }

    struct Resolution: Equatable {
        let paired: [Group]
        let singletons: [URL]
    }

    static func resolve(
        urls: [URL], extensions: [String] = [RecordingFileSuffix.wavExtension],
    ) -> Resolution {
        struct Key: Hashable {
            let directory: String
            let stem: String
        }
        struct Partial {
            var mix: URL?
            var app: URL?
            var mic: URL?
            var firstIndex: Int = .max
        }

        var partials: [Key: Partial] = [:]
        var singletonsWithIndex: [(Int, URL)] = []

        for (index, url) in urls.enumerated() {
            guard let track = RecordingFileSuffix.keptTrack(of: url.lastPathComponent, extensions: extensions) else {
                singletonsWithIndex.append((index, url))
                continue
            }
            let directory = url.deletingLastPathComponent()
            let key = Key(directory: directory.standardizedFileURL.path, stem: track.stem)
            var partial = partials[key] ?? Partial()
            partial.firstIndex = min(partial.firstIndex, index)
            // Of two spellings of one track, the one earlier in `extensions`
            // (the WAV for an import), whatever order the files came in.
            func take(_ current: URL?) -> URL {
                guard let current,
                      let held = RecordingFileSuffix.keptTrack(of: current.lastPathComponent, extensions: extensions),
                      let heldRank = extensions.firstIndex(of: held.fileExtension),
                      let newRank = extensions.firstIndex(of: track.fileExtension),
                      heldRank <= newRank else { return url }
                return current
            }
            switch track.suffix {
            case RecordingFileSuffix.mix: partial.mix = take(partial.mix)
            case RecordingFileSuffix.app: partial.app = take(partial.app)
            case RecordingFileSuffix.mic: partial.mic = take(partial.mic)
            default: break
            }
            partials[key] = partial
        }

        var paired: [(Int, Group)] = []
        for (key, partial) in partials {
            // A group is paired when it can feed the dual-track pipeline: either
            // both `_app`+`_mic` tracks (mix will be synthesized at enqueue time)
            // or a pre-mixed `_mix.wav`. A lone `_app` or `_mic` without partner
            // falls back to a singleton.
            let hasDualTracks = partial.app != nil && partial.mic != nil
            if hasDualTracks || partial.mix != nil {
                let directoryURL = URL(fileURLWithPath: key.directory, isDirectory: true)
                let group = Group(
                    stem: key.stem,
                    directory: directoryURL,
                    mix: partial.mix,
                    app: partial.app,
                    mic: partial.mic,
                )
                paired.append((partial.firstIndex, group))
            } else if let solo = partial.app ?? partial.mic {
                singletonsWithIndex.append((partial.firstIndex, solo))
            }
        }

        paired.sort { $0.0 < $1.0 }
        singletonsWithIndex.sort { $0.0 < $1.0 }

        return Resolution(
            paired: paired.map(\.1),
            singletons: singletonsWithIndex.map(\.1),
        )
    }
}
