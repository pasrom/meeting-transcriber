import Foundation

/// Groups a flat list of URLs into dual-source recording groups (`_app`+`_mic`
/// or `_mix` sharing a stem) plus singletons — so re-importing a recording
/// produces one dual-track `PipelineJob` instead of two independent jobs.
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

    static func resolve(urls: [URL]) -> Resolution {
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
            guard let (stem, suffix) = RecordingFileSuffix.stripSuffix(from: url.lastPathComponent) else {
                singletonsWithIndex.append((index, url))
                continue
            }
            let directory = url.deletingLastPathComponent()
            let key = Key(directory: directory.standardizedFileURL.path, stem: stem)
            var partial = partials[key] ?? Partial()
            partial.firstIndex = min(partial.firstIndex, index)
            switch suffix {
            case RecordingFileSuffix.mix: partial.mix = url
            case RecordingFileSuffix.app: partial.app = url
            case RecordingFileSuffix.mic: partial.mic = url
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
