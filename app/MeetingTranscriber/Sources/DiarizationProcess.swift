import Foundation

/// Result from diarization.
struct DiarizationResult {
    struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
    }

    let segments: [Segment]
    let speakingTimes: [String: TimeInterval]
    let autoNames: [String: String]
    var embeddings: [String: [Float]]? // swiftlint:disable:this discouraged_optional_collection
}

/// Abstraction for diarization, enabling mock injection in tests.
/// `Sendable` because `PipelineQueue` runs two diarisations concurrently
/// from the same instance via `async let`. Implementations must keep
/// `run` stateless (or internally synchronised); FluidAudio's CoreML
/// inference is thread-safe, mocks must follow the same contract.
protocol DiarizationProvider: Sendable {
    var isAvailable: Bool { get }
    /// The diarizer mode this provider was instantiated with. Read post-run
    /// by `PipelineQueue` to record `PipelineJob.usedDiarizerMode`, so the
    /// re-run UI in `SpeakerNamingView` can initialise its mode picker to
    /// the mode that was actually used at recording time.
    var mode: DiarizerMode { get }
    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult
}

/// Speaker assignment utilities.
enum DiarizationProcess {
    /// Speaker tag carried by app/remote-audio segments in a dual-source mix.
    /// Written by `mergeDualSourceSegments` and read back here when splitting
    /// cached segments per track — both sides must agree, so the literal lives
    /// in one place.
    static let remoteSpeakerLabel = "Remote"

    /// Label and merge pre-transcribed app/mic segments by timestamp: app
    /// segments become `remoteSpeakerLabel`, mic segments take `micLabel`, the
    /// mic track is shifted by `micDelay`, and the result is sorted by start
    /// time. Pure timestamp math over transcript segments — lives here next to
    /// the diarization assignment that reads `remoteSpeakerLabel` back, rather
    /// than on the engine protocol (the engine doesn't care about speaker tags).
    static func mergeDualSourceSegments(
        appSegments: [TimestampedSegment],
        micSegments: [TimestampedSegment],
        micDelay: TimeInterval = 0,
        micLabel: String = "Me",
    ) -> [TimestampedSegment] {
        var app = appSegments
        var mic = micSegments

        if micDelay != 0 {
            mic = mic.map { seg in
                TimestampedSegment(
                    start: seg.start + micDelay,
                    end: seg.end + micDelay,
                    text: seg.text,
                    speaker: seg.speaker,
                )
            }
        }

        for i in app.indices {
            app[i].speaker = remoteSpeakerLabel
        }
        for i in mic.indices {
            mic[i].speaker = micLabel
        }

        var result = app + mic
        result.sort { $0.start < $1.start }
        return result
    }

    /// Assign speaker labels to transcript segments by maximum temporal overlap.
    /// Uses `autoNames` to replace raw labels (e.g. "SPEAKER_0") with human names.
    /// When no overlap exists, falls back to the nearest diarization segment by gap distance.
    static func assignSpeakers(
        transcript: [TimestampedSegment],
        diarization: DiarizationResult,
    ) -> [TimestampedSegment] {
        // swiftlint:disable:next closure_body_length
        transcript.map { seg in
            var best = seg
            var bestOverlap: TimeInterval = 0

            for dSeg in diarization.segments {
                let overlapStart = max(seg.start, dSeg.start)
                let overlapEnd = min(seg.end, dSeg.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best.speaker = diarization.autoNames[dSeg.speaker] ?? dSeg.speaker
                }
            }

            // Fallback: find nearest diarization segment by gap distance
            if bestOverlap == 0 {
                var nearestGap: TimeInterval = .infinity
                for dSeg in diarization.segments {
                    let gap: TimeInterval = if seg.end <= dSeg.start {
                        dSeg.start - seg.end
                    } else if seg.start >= dSeg.end {
                        seg.start - dSeg.end
                    } else {
                        0
                    }
                    if gap < nearestGap {
                        nearestGap = gap
                        best.speaker = diarization.autoNames[dSeg.speaker] ?? dSeg.speaker
                    }
                }
            }

            if best.speaker.isEmpty {
                best.speaker = "UNKNOWN"
            }
            return best
        }
    }

    // MARK: - Dual-Track Diarization

    /// Shift every segment's `start`/`end` by `offset` seconds, moving a
    /// track's diarization onto a different timeline. Used to bring the mic
    /// track's diarization onto the app/canonical timeline by `+micDelay`, so it
    /// aligns with the mic transcript segments — which
    /// `mergeDualSourceSegments` already shifts by the same
    /// `+micDelay`. Without this the two are offset and overlap-based speaker
    /// assignment mislabels mic-side segments. `speakingTimes` (durations),
    /// `autoNames`, and `embeddings` are timeline-independent, so they pass
    /// through unchanged. A zero offset is a no-op (returns the input verbatim).
    static func shiftSegments(_ result: DiarizationResult, by offset: TimeInterval) -> DiarizationResult {
        guard offset != 0 else { return result }
        return DiarizationResult(
            segments: result.segments.map { seg in
                DiarizationResult.Segment(start: seg.start + offset, end: seg.end + offset, speaker: seg.speaker)
            },
            speakingTimes: result.speakingTimes,
            autoNames: result.autoNames,
            embeddings: result.embeddings,
        )
    }

    /// Merge two separate diarization results (app + mic) into one,
    /// prefixing speaker IDs with `R_` (remote/app) and `M_` (mic/local).
    static func mergeDualTrackDiarization(
        appDiarization: DiarizationResult,
        micDiarization: DiarizationResult,
    ) -> DiarizationResult {
        // Prefix app segments with R_
        let appSegments = appDiarization.segments.map { seg in
            DiarizationResult.Segment(
                start: seg.start,
                end: seg.end,
                speaker: SpeakerKey(track: .app, id: seg.speaker).encoded,
            )
        }
        // Prefix mic segments with M_
        let micSegments = micDiarization.segments.map { seg in
            DiarizationResult.Segment(
                start: seg.start,
                end: seg.end,
                speaker: SpeakerKey(track: .mic, id: seg.speaker).encoded,
            )
        }

        // Merge and sort by start time
        var allSegments = appSegments + micSegments
        allSegments.sort { $0.start < $1.start }

        // Merge speaking times with prefixed keys
        var speakingTimes: [String: TimeInterval] = [:]
        for (key, value) in appDiarization.speakingTimes {
            speakingTimes[SpeakerKey(track: .app, id: key).encoded] = value
        }
        for (key, value) in micDiarization.speakingTimes {
            speakingTimes[SpeakerKey(track: .mic, id: key).encoded] = value
        }

        // Merge embeddings with prefixed keys
        var embeddings: [String: [Float]]? // swiftlint:disable:this discouraged_optional_collection
        if appDiarization.embeddings != nil || micDiarization.embeddings != nil {
            embeddings = [:]
            for (key, value) in appDiarization.embeddings ?? [:] {
                embeddings?[SpeakerKey(track: .app, id: key).encoded] = value
            }
            for (key, value) in micDiarization.embeddings ?? [:] {
                embeddings?[SpeakerKey(track: .mic, id: key).encoded] = value
            }
        }

        // Merge autoNames with prefixed keys
        var autoNames: [String: String] = [:]
        for (key, value) in appDiarization.autoNames {
            autoNames[SpeakerKey(track: .app, id: key).encoded] = value
        }
        for (key, value) in micDiarization.autoNames {
            autoNames[SpeakerKey(track: .mic, id: key).encoded] = value
        }

        return DiarizationResult(
            segments: allSegments,
            speakingTimes: speakingTimes,
            autoNames: autoNames,
            embeddings: embeddings,
        )
    }

    /// Strip a track prefix from a `[speakerID: name]` dictionary, keeping only
    /// entries whose key belongs to `track` and re-keying them to the raw
    /// diarizer id. Routes through `SpeakerKey`'s serialization boundary rather
    /// than duplicating the prefix strings, so a key like `R_SPEAKER_0` maps to
    /// `SPEAKER_0` under `.app`, while non-matching keys (other track, or a raw
    /// unprefixed id that parses as `.single`) are excluded. Inverse of the
    /// prefixing done in `mergeDualTrackDiarization`.
    static func unprefixNames(_ autoNames: [String: String], track: SpeakerKey.Track) -> [String: String] {
        var out: [String: String] = [:]
        for (label, name) in autoNames {
            let key = SpeakerKey(encoded: label)
            guard key.track == track else { continue }
            out[key.id] = name
        }
        return out
    }

    /// Maximum silence gap (seconds) before breaking a same-speaker block.
    /// Pauses longer than this start a new paragraph even for the same speaker.
    static let mergeGapThreshold: TimeInterval = 2.0

    /// Merge consecutive segments from the same speaker into single blocks.
    /// Preserves the start timestamp of the first segment and end timestamp of the last.
    /// Text is joined with spaces. A silence gap > `mergeGapThreshold` forces a break.
    static func mergeConsecutiveSpeakers(
        _ segments: [TimestampedSegment],
    ) -> [TimestampedSegment] {
        guard var current = segments.first else { return [] }

        var merged: [TimestampedSegment] = []
        for seg in segments.dropFirst() {
            let silenceGap = seg.start - current.end
            if seg.speaker == current.speaker, silenceGap <= mergeGapThreshold {
                current = TimestampedSegment(
                    start: current.start,
                    end: seg.end,
                    text: "\(current.text) \(seg.text)",
                    speaker: current.speaker,
                )
            } else {
                merged.append(current)
                current = seg
            }
        }
        merged.append(current)
        return merged
    }

    /// Assign speakers using separate diarizations for app and mic tracks.
    /// App segments are matched against appDiarization, mic segments against micDiarization.
    static func assignSpeakersDualTrack(
        appSegments: [TimestampedSegment],
        micSegments: [TimestampedSegment],
        appDiarization: DiarizationResult,
        micDiarization: DiarizationResult,
    ) -> [TimestampedSegment] {
        let labeledApp = assignSpeakers(transcript: appSegments, diarization: appDiarization)
        let labeledMic = assignSpeakers(transcript: micSegments, diarization: micDiarization)

        var result = labeledApp + labeledMic
        result.sort { $0.start < $1.start }
        return result
    }
}

extension DiarizationProcess {
    /// The diarization topologies the pipeline produces, each carrying the data
    /// its speaker assignment needs (single-source, dual-track, and the app-only
    /// and mic-only single-track fallbacks). `labelSegments` collapses what used
    /// to be near-duplicate inline assignment blocks in `PipelineQueue.diarize`;
    /// the merge + formatting tail they all shared is now applied once at the
    /// call site.
    enum LabelingTopology {
        /// Single mixed track: every transcript segment is assigned against one
        /// diarization.
        case single(segments: [TimestampedSegment], diarization: DiarizationResult)
        /// Dual track, both diarizations succeeded: cached segments are split by
        /// their `Remote` / `micLabel` tag and assigned against their own
        /// `R_` / `M_`-unprefixed diarization.
        case dualTrack(cached: [TimestampedSegment], micLabel: String, app: DiarizationResult, mic: DiarizationResult)
        /// Dual track, mic diarization failed: app segments are assigned against
        /// the app diarization; mic segments keep their raw `micLabel` rather
        /// than being force-matched.
        case dualTrackAppOnly(cached: [TimestampedSegment], micLabel: String, app: DiarizationResult)
        /// Dual track, app diarization failed (e.g. a silent remote side in a
        /// solo meeting): mic segments are assigned against the mic diarization;
        /// app segments keep their raw `remoteSpeakerLabel` tag rather than being
        /// force-matched. Mirror of `dualTrackAppOnly`.
        case dualTrackMicOnly(cached: [TimestampedSegment], micLabel: String, mic: DiarizationResult)
    }

    /// Apply speaker labels for any diarization topology, returning segments
    /// ready for `mergeConsecutiveSpeakers` + formatting. `autoNames` carries
    /// the speaker→name mapping (`R_`/`M_`-prefixed for the dual-track cases).
    static func labelSegments(_ topology: LabelingTopology, autoNames: [String: String]) -> [TimestampedSegment] {
        switch topology {
        case let .single(segments, diarization):
            let named = DiarizationResult(
                segments: diarization.segments,
                speakingTimes: diarization.speakingTimes,
                autoNames: autoNames,
                embeddings: diarization.embeddings,
            )
            return assignSpeakers(transcript: segments, diarization: named)

        case let .dualTrack(cached, micLabel, app, mic):
            let namedApp = DiarizationResult(
                segments: app.segments,
                speakingTimes: app.speakingTimes,
                autoNames: unprefixNames(autoNames, track: .app),
                embeddings: app.embeddings,
            )
            let namedMic = DiarizationResult(
                segments: mic.segments,
                speakingTimes: mic.speakingTimes,
                autoNames: unprefixNames(autoNames, track: .mic),
                embeddings: mic.embeddings,
            )
            let appSegs = cached.filter { $0.speaker == remoteSpeakerLabel }
            let micSegs = cached.filter { $0.speaker == micLabel }
            return assignSpeakersDualTrack(
                appSegments: appSegs,
                micSegments: micSegs,
                appDiarization: namedApp,
                micDiarization: namedMic,
            )

        case let .dualTrackAppOnly(cached, micLabel, app):
            // Mic diarization failed, so `combined` is the *unprefixed* app
            // diarization — autoNames keys are raw ("SPEAKER_0"), not "R_"-prefixed.
            // Pass them through directly; unprefixing would drop every mapping and
            // surface raw diarizer IDs instead of matched names.
            let namedApp = DiarizationResult(
                segments: app.segments,
                speakingTimes: app.speakingTimes,
                autoNames: autoNames,
                embeddings: app.embeddings,
            )
            let appSegs = cached.filter { $0.speaker == remoteSpeakerLabel }
            let micSegs = cached.filter { $0.speaker == micLabel }
            let labeledApp = assignSpeakers(transcript: appSegs, diarization: namedApp)
            // micSegs keep their original micLabel speaker tag.
            return (labeledApp + micSegs).sorted { $0.start < $1.start }

        case let .dualTrackMicOnly(cached, micLabel, mic):
            // App diarization failed, so `combined` is the *unprefixed* mic
            // diarization — autoNames keys are raw ("SPEAKER_0"), not "M_"-prefixed.
            // Pass them through directly (mirror of the app-only fallback above).
            let namedMic = DiarizationResult(
                segments: mic.segments,
                speakingTimes: mic.speakingTimes,
                autoNames: autoNames,
                embeddings: mic.embeddings,
            )
            let appSegs = cached.filter { $0.speaker == remoteSpeakerLabel }
            let micSegs = cached.filter { $0.speaker == micLabel }
            let labeledMic = assignSpeakers(transcript: micSegs, diarization: namedMic)
            // appSegs keep their original remoteSpeakerLabel tag.
            return (labeledMic + appSegs).sorted { $0.start < $1.start }
        }
    }
}

enum DiarizationError: LocalizedError {
    case notAvailable
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Diarization not available"
        case .notPrepared: "Offline diarization manager not prepared"
        }
    }
}
