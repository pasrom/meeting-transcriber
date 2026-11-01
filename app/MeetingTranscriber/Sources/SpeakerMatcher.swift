// swiftlint:disable discouraged_optional_collection
// Optional `[Float]?` is intentional throughout this file: nil signals
// "no centroid yet" (legacy entries / dim-mismatch / empty input), which is
// semantically distinct from an empty embedding vector.
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerMatcher")

class SpeakerMatcher {
    private let dbPath: URL
    private let threshold: Float
    private let confidenceMargin: Float
    /// Recent-samples FIFO size (was 5 before centroid landed; 3 is enough as
    /// fallback because the centroid is the primary anchor now).
    static let maxRecentSamples = 3
    /// Minimum total speaking time (seconds) for an embedding to be folded
    /// into the centroid. Short snippets are still kept as fallback samples
    /// but don't pollute the running average.
    static let minSpeakingTimeForCentroid: TimeInterval = 3.0
    /// Process-wide lock for read-modify-write sequences against
    /// `speakers.json`. The RPC handlers, the pipeline-job confirmation
    /// path, the KnownVoices UI, and voice enrollment can all mutate the
    /// DB concurrently — without serialization, two writers can both load
    /// the same snapshot and the second `saveDB` silently overwrites the
    /// first. Reads stay unlocked: every code path reloads after a
    /// mutation anyway, and `replaceItemAt` already gives atomic file
    /// replacement at the FS level.
    private static let dbLock = NSLock()
    /// Last problem reported per DB path (see `shouldReport`). Process-wide
    /// because matchers are created per call; guarded by `dbLock`.
    nonisolated(unsafe) private static var problemReports: [URL: ProblemReport] = [:]

    /// Told when `mutateDB` could not use or write the DB, so the user learns
    /// their enrolled voices are not being kept. Deduplicated, and called
    /// after `dbLock` is released. Silent by default, like `WatchLoop`'s
    /// notifier: production builds matchers through `factory(dbPath:notifier:)`,
    /// which routes it to the app's one `AppNotifying`.
    private let onDBProblem: (DBProblem) -> Void
    /// Runs between the two reads of an undecodable DB, without `dbLock`
    /// held (see `rereadDelay`). Injected so tests neither wait nor race a
    /// timer.
    private let settleBeforeReread: () -> Void

    init(
        dbPath: URL? = nil,
        threshold: Float = 0.40,
        confidenceMargin: Float = 0.10,
        // First of the two closures, so a trailing closure binds to it.
        onDBProblem: @escaping (DBProblem) -> Void = { _ in },
        settleBeforeReread: @escaping () -> Void = { Thread.sleep(forTimeInterval: SpeakerMatcher.rereadDelay) },
    ) {
        self.dbPath = dbPath ?? AppPaths.speakersDB
        self.threshold = threshold
        self.confidenceMargin = confidenceMargin
        self.settleBeforeReread = settleBeforeReread
        self.onDBProblem = onDBProblem
        Self.migrateIfNeeded(dbPath: self.dbPath)
    }

    /// Atomic read-modify-write against `speakers.json`. Holds the
    /// process-wide DB lock for the duration of the closure so concurrent
    /// callers can't lose updates. Use this for every mutating operation;
    /// raw `loadDB` + `saveDB` paired by hand reintroduces the race.
    ///
    /// A DB that exists but cannot be used is never overwritten blind.
    /// Treating it as empty and saving would replace every enrolled voice
    /// with just this one change. A damaged DB is first copied aside
    /// unchanged (`quarantineDamagedDB`), and the block runs against the
    /// entries that could be salvaged (`.salvaged`; none if the file is not a
    /// JSON array). Only then is the new array swapped in by an atomic
    /// replace, so the original stays in place until the new file takes its
    /// path: a failed write leaves it untouched, and a reader never finds the
    /// path empty. A DB that failed to *read* may be intact, so it stays in
    /// place and nothing is written; so does a damaged one that cannot be
    /// copied. The block still runs in that case, because callers need its
    /// result; `persistence` says whether the change reached the disk.
    @discardableResult
    func mutateDB<R>(_ block: (inout [StoredSpeaker]) -> R) -> Mutation<R> {
        var mayQuarantine = false
        while true {
            let attempt = Self.dbLock.withLock { lockedMutate(block, mayQuarantine: mayQuarantine) }
            guard let (mutation, problem) = attempt else {
                // Undecodable on the first read. Wait outside the lock, so
                // other writers are not held up, then read it once more.
                settleBeforeReread()
                mayQuarantine = true
                continue
            }
            // Outside the lock: the callback posts a notification and may call
            // back into a matcher, and `dbLock` is not recursive.
            if let problem { onDBProblem(problem) }
            return mutation
        }
    }

    /// The body of `mutateDB`, run with `dbLock` held. Returns the problem to
    /// report, already deduplicated, for the caller to report after unlocking;
    /// or nil, without running `block`, when the DB is undecodable and
    /// `mayQuarantine` is false (see `rereadDelay`).
    private func lockedMutate<R>(
        _ block: (inout [StoredSpeaker]) -> R, mayQuarantine: Bool,
    ) -> (Mutation<R>, DBProblem?)? {
        let outcome = Self.readDB(at: dbPath)
        // The problem already reported for this very file, if it has not
        // changed since: it was left in place, or its write failed after the
        // copy. Such a file has stopped changing.
        let known = Self.problemReports[dbPath].flatMap { $0.file == FileState(of: dbPath) ? $0.problem : nil }
        // Only a file that is not even a JSON array can be a sync tool caught
        // mid-write, and one already reported need not be waited on again by
        // the (mostly main-actor) callers.
        if case .undecodable = outcome, !mayQuarantine, known == nil {
            return nil
        }
        var plan = Self.writePlan(for: outcome)
        // The copy must exist before anything is written: the entries a
        // salvage drops survive only in it. An unchanged file whose write
        // failed already has one, so a write that keeps failing makes no more.
        var copiedTo: URL?
        if let damage = plan.damage {
            copiedTo = Self.existingCopy(after: known, of: dbPath)
                ?? Self.quarantineDamagedDB(at: dbPath, damage: damage)
            if copiedTo == nil { plan.writable = false }
        }
        var stored = plan.stored
        let value = block(&stored)

        let persistence: Persistence
        let problem: DBProblem?
        if plan.writable {
            do {
                try Self.writeDB(stored, to: dbPath)
                persistence = .saved
                problem = copiedTo.flatMap { plan.damage?.problem(copiedTo: $0) }
                Self.problemReports[dbPath] = nil
            } catch {
                // The atomic replace never happened, so the original is still
                // in place, untouched; the copy stays too, is named, and is
                // reused by the next attempt while the file is unchanged.
                logger.error("Failed to save speaker DB: \(error.localizedDescription, privacy: .public)")
                persistence = .writeFailed
                problem = .saveFailed(copiedTo: copiedTo)
            }
        } else {
            persistence = .dbUnavailable
            problem = .leftInPlace
        }
        let toReport = problem.flatMap { Self.shouldReport($0, at: dbPath, reports: &Self.problemReports) ? $0 : nil }
        let replaced = persistence == .saved ? copiedTo : nil
        return (Mutation(value: value, persistence: persistence, replacedCorruptDB: replaced), toReport)
    }

    /// Classify the DB on disk without the re-read `mutateDB` does. See
    /// `ReadOutcome`.
    func readDB() -> ReadOutcome {
        Self.readDB(at: dbPath)
    }

    /// Reset old pyannote-format speakers.json (incompatible embeddings).
    /// Old format: `{ "name": [[float]] }` dict.
    /// New format: `[{ "name": str, "embedding": [float] }]` array.
    static func migrateIfNeeded(dbPath: URL) {
        guard let data = try? Data(contentsOf: dbPath) else { return }

        // Fast path: the current array format ('[') needs no migration. Skip the
        // full JSONSerialization parse for it — this runs on every SpeakerMatcher
        // init, so re-parsing the whole DB each time is pure overhead, and
        // concurrent inits parsing the same file is a TSan-hostile NSJSONReader
        // frame. saveDB writes JSONEncoder output, which always begins with '['.
        // Only the legacy dict format falls through to the parse + backup below.
        guard data.first != UInt8(ascii: "[") else { return }

        guard let json = try? JSONSerialization.jsonObject(with: data) else { return }
        // Old format is a dictionary, new format is an array
        if json is [String: Any] {
            let backup = dbPath.deletingLastPathComponent()
                .appendingPathComponent("speakers.json.bak")
            try? FileManager.default.moveItem(at: dbPath, to: backup)
        }
    }

    /// Match diarization embeddings against stored speakers.
    /// Distance uses `min(cosineDistance over [centroid] + recent samples)`
    /// — the centroid is treated as one additional anchor alongside the
    /// recent-samples FIFO, never replacing them. This preserves the
    /// previous algorithm's behaviour on identical-sample queries while
    /// adding the centroid's drift-resistance for free.
    func match(embeddings: [String: [Float]]) -> [String: String] {
        matchVerbose(embeddings: embeddings).mapValues(\.assignedName)
    }

    /// Per-label match result. Reuses `TopCandidate` so the matcher and the
    /// JSONL log share one shape — eliminates a field-by-field re-pack at the
    /// call site.
    struct VerboseMatch {
        /// Real speaker name when the threshold + margin checks pass; the
        /// label itself otherwise.
        let assignedName: String
        /// Candidates sorted by `hybrid` ascending; empty if the DB is empty.
        let topCandidates: [TopCandidate]
    }

    /// Match each label against the stored DB, returning the top candidates
    /// with their per-anchor distances.
    func matchVerbose(embeddings: [String: [Float]], topK: Int = 3)
        -> [String: VerboseMatch] {
        // Synthetic entries (RPC `seedSpeaker`) carry random embeddings —
        // letting them participate in matching would let any caller with
        // RPC access poison auto-naming. Drop them before scoring.
        let stored = loadDB().filter { !$0.isSynthetic }
        var result: [String: VerboseMatch] = [:]
        var usedNames: Set<String> = []

        let sorted = embeddings.sorted { $0.key < $1.key }

        for (label, embedding) in sorted {
            let scored = stored
                .filter { !usedNames.contains($0.name) }
                .map { speaker -> TopCandidate in
                    let sampleDist = speaker.embeddings
                        .map { Self.cosineDistance(embedding, $0) }.min()
                        ?? Float.greatestFiniteMagnitude
                    let centroidDist = speaker.centroid.map { vec in
                        Self.cosineDistance(embedding, vec)
                    }
                    return TopCandidate(
                        name: speaker.name, sample: sampleDist, centroid: centroidDist,
                    )
                }
                .sorted { $0.hybrid < $1.hybrid }

            let best = scored.first
            let second = scored.count > 1 ? scored[1] : nil
            let assignedName: String
            if let best,
               best.hybrid < threshold,
               (second?.hybrid ?? .greatestFiniteMagnitude) - best.hybrid >= confidenceMargin {
                assignedName = best.name
                usedNames.insert(best.name)
            } else {
                assignedName = label
            }
            Self.logMatchDecision(
                label: label, best: best, second: second,
                assigned: assignedName,
                thresholds: (distance: threshold, margin: confidenceMargin),
            )
            result[label] = VerboseMatch(
                assignedName: assignedName, topCandidates: Array(scored.prefix(topK)),
            )
        }

        return result
    }

    /// Distance from a query embedding to a stored speaker.
    /// Computes `min(cosineDistance over [centroid] + recent samples)`.
    /// For legacy entries (no centroid persisted), the recent-samples FIFO
    /// is the sole anchor — which is identical to the pre-centroid algorithm.
    static func distance(query: [Float], speaker: StoredSpeaker) -> Float {
        var anchors = speaker.embeddings
        if let c = speaker.centroid { anchors.append(c) }
        return anchors.map { cosineDistance(query, $0) }.min() ?? .greatestFiniteMagnitude
    }

    /// Element-wise mean of a non-empty list of equal-length embedding
    /// vectors. Returns nil for an empty input or for vectors of mixed
    /// dimensionality (we never produce mixed-dim arrays in normal flow,
    /// but we don't trust historical entries).
    static func meanEmbedding(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let dim = first.count
        guard vectors.allSatisfy({ $0.count == dim }) else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        for vec in vectors {
            for i in 0 ..< dim {
                sum[i] += vec[i]
            }
        }
        let n = Float(vectors.count)
        return sum.map { $0 / n }
    }

    /// Update an existing centroid with a new sample using a running average:
    /// `new = (centroid * count + sample) / (count + 1)`. Returns nil if the
    /// sample dimensionality doesn't match the centroid (we never let a bad
    /// sample corrupt the centroid).
    static func updateCentroid(
        current: [Float]?, count: Int, with sample: [Float],
    ) -> (centroid: [Float], count: Int)? {
        guard !sample.isEmpty else { return nil }
        guard let current, !current.isEmpty else {
            return (sample, 1)
        }
        guard current.count == sample.count else { return nil }
        let n = Float(count)
        let total = n + 1
        var updated = [Float](repeating: 0, count: current.count)
        for i in 0 ..< current.count {
            updated[i] = (current[i] * n + sample[i]) / total
        }
        return (updated, count + 1)
    }

    /// Update speaker DB with confirmed names and their embeddings.
    /// - Embeddings from speakers with at least `minSpeakingTimeForCentroid`
    ///   seconds of speaking time are folded into the running-mean `centroid`
    ///   (the primary match anchor).
    /// - All confirmed embeddings are appended to the recent-samples FIFO
    ///   (max `maxRecentSamples`) regardless of duration, so a borderline
    ///   centroid match can be rescued by a fallback sample distance.
    /// - `lastUsed` / `useCount` are bumped on every confirmation.
    /// - An embedding with a NaN/Inf value (FluidAudio emits these for short
    ///   or silent segments) is skipped like a missing one. Folded into the
    ///   running-mean centroid it would turn it NaN for good, and the plain
    ///   JSON encoder cannot write it, which used to drop the other labels of
    ///   the same confirmation too. The outcome names it so the caller can
    ///   tell the user that voice was not learned.
    @discardableResult
    func updateDB(
        mapping: [String: String],
        embeddings: [String: [Float]],
        speakingTimes: [String: TimeInterval] = [:],
        now: Date = Date(),
    ) -> ConfirmationOutcome {
        let mutation = mutateDB { stored -> (applied: Set<String>, unusable: Set<String>) in
            var applied: Set<String> = []
            var unusable: Set<String> = []
            for (label, name) in mapping {
                guard name != label, let embedding = embeddings[label] else { continue }
                guard embedding.allSatisfy(\.isFinite) else {
                    logger.warning("Skipping non-finite embedding for \(label, privacy: .public)")
                    unusable.insert(name)
                    continue
                }
                applied.insert(name)
                let duration = speakingTimes[label] ?? 0

                if let idx = stored.firstIndex(where: { $0.name == name }) {
                    stored[idx] = Self.applyConfirmation(
                        to: stored[idx],
                        embedding: embedding,
                        duration: duration,
                        now: now,
                    )
                } else {
                    stored.append(Self.newSpeaker(
                        name: name, embedding: embedding, duration: duration, now: now,
                    ))
                }
            }
            return (applied, unusable)
        }
        return ConfirmationOutcome(
            stored: mutation.saved ? mutation.value.applied.sorted() : [],
            // A name another label of the same confirmation did teach is not
            // missing.
            unusableVoice: mutation.value.unusable.subtracting(mutation.value.applied).sorted(),
            persistence: mutation.persistence,
        )
    }

    /// Pure helper: fold a confirmed embedding into an existing `StoredSpeaker`.
    /// Centroid is updated only when `duration >= minSpeakingTimeForCentroid`.
    /// FIFO of recent samples is bumped unconditionally.
    static func applyConfirmation(
        to speaker: StoredSpeaker, embedding: [Float], duration: TimeInterval, now: Date,
    ) -> StoredSpeaker {
        var samples = speaker.embeddings
        samples.append(embedding)
        if samples.count > maxRecentSamples {
            samples.removeFirst(samples.count - maxRecentSamples)
        }

        let qualifies = duration >= minSpeakingTimeForCentroid
        // Seed the centroid from the existing sample list on first qualifying
        // confirmation after a v3 schema upgrade. Subsequent confirmations
        // run the normal incremental update.
        let seedCentroid = speaker.centroid ?? meanEmbedding(speaker.embeddings)
        let seedCount = speaker.centroid != nil
            ? speaker.centroidSampleCount
            : (seedCentroid != nil ? speaker.embeddings.count : 0)

        let nextCentroid: [Float]?
        let nextCount: Int
        if qualifies, let updated = updateCentroid(
            current: seedCentroid, count: seedCount, with: embedding,
        ) {
            nextCentroid = updated.centroid
            nextCount = updated.count
        } else {
            nextCentroid = seedCentroid
            nextCount = seedCount
        }

        return StoredSpeaker(
            name: speaker.name,
            embeddings: samples,
            centroid: nextCentroid,
            centroidSampleCount: nextCount,
            lastUsed: now,
            useCount: speaker.useCount + 1,
        )
    }

    /// Pure helper: build a fresh `StoredSpeaker` from a single confirmation.
    static func newSpeaker(
        name: String, embedding: [Float], duration: TimeInterval, now: Date,
    ) -> StoredSpeaker {
        let qualifies = duration >= minSpeakingTimeForCentroid
        return StoredSpeaker(
            name: name,
            embeddings: [embedding],
            centroid: qualifies ? embedding : nil,
            centroidSampleCount: qualifies ? 1 : 0,
            lastUsed: now,
            useCount: 1,
        )
    }

    /// Pure helper: combine `src` into `dst`. Used by both rename-collision
    /// and explicit merge.
    static func merged(into dst: StoredSpeaker, from src: StoredSpeaker) -> StoredSpeaker {
        var samples = dst.embeddings + src.embeddings
        if samples.count > maxRecentSamples {
            samples.removeFirst(samples.count - maxRecentSamples)
        }
        let combined = mergeCentroids(
            a: dst.centroid, aCount: dst.centroidSampleCount,
            b: src.centroid, bCount: src.centroidSampleCount,
        )
        let centroid = combined.centroid ?? meanEmbedding(samples)
        let lastUsed: Date? = switch (dst.lastUsed, src.lastUsed) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
        return StoredSpeaker(
            name: dst.name,
            embeddings: samples,
            centroid: centroid,
            centroidSampleCount: combined.count,
            lastUsed: lastUsed,
            useCount: dst.useCount + src.useCount,
            // Stay synthetic only when both sides are synthetic. Merging a
            // real entry in promotes the result back to real.
            isSynthetic: dst.isSynthetic && src.isSynthetic,
        )
    }

    /// Pure helper: weighted-average two centroids. Returns nil centroid if
    /// both inputs are nil. Dimension mismatches yield the larger-count side
    /// (we never let a dim-mismatched merge corrupt the centroid).
    static func mergeCentroids(
        a: [Float]?, aCount: Int, b: [Float]?, bCount: Int,
    ) -> (centroid: [Float]?, count: Int) {
        switch (a, b) {
        case (nil, nil):
            return (nil, aCount + bCount)

        case let (a?, nil):
            return (a, aCount + bCount)

        case let (nil, b?):
            return (b, aCount + bCount)

        case let (a?, b?):
            guard a.count == b.count, !a.isEmpty else {
                return aCount >= bCount ? (a, aCount + bCount) : (b, aCount + bCount)
            }
            let total = Float(max(aCount + bCount, 1))
            let aw = Float(aCount) / total
            let bw = Float(bCount) / total
            var merged = [Float](repeating: 0, count: a.count)
            for i in 0 ..< a.count {
                merged[i] = a[i] * aw + b[i] * bw
            }
            return (merged, aCount + bCount)
        }
    }

    /// Stored speakers for read-only use. An unreadable DB reads as empty
    /// here, a partly undecodable one as the entries that can be salvaged,
    /// and either is left in place; only `mutateDB` copies it aside, under
    /// the lock, before it would write.
    func loadDB() -> [StoredSpeaker] {
        readDB().usableSpeakers
    }

    /// Names of all stored speakers, ordered for picker display: most recently
    /// used first, then by `useCount` descending, then alphabetically. Speakers
    /// without `lastUsed` (legacy entries) are sorted alphabetically at the end.
    /// This is the source-of-truth ordering for the "Known voices" row.
    func allSpeakerNames() -> [String] {
        Self.rankByRecency(speakers: loadDB()).map(\.name)
    }

    /// Sort stored speakers for picker display. Pure for testability.
    /// Tier order:
    /// 1. Speakers with `lastUsed != nil`, most recent first.
    /// 2. Within that group, ties (same timestamp) broken by `useCount` desc.
    /// 3. Speakers without `lastUsed` come last, alphabetically.
    static func rankByRecency(speakers: [StoredSpeaker]) -> [StoredSpeaker] {
        let used = speakers.filter { $0.lastUsed != nil }
        let unused = speakers.filter { $0.lastUsed == nil }
        let sortedUsed = used.sorted { lhs, rhs in
            let l = lhs.lastUsed ?? .distantPast
            let r = rhs.lastUsed ?? .distantPast
            if l != r { return l > r }
            if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let sortedUnused = unused.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return sortedUsed + sortedUnused
    }

    /// Write the DB unconditionally, logging a failure. Skips the lock and
    /// every safeguard in `mutateDB`, so production writes go through that.
    func saveDB(_ speakers: [StoredSpeaker]) {
        do {
            try Self.writeDB(speakers, to: dbPath)
        } catch {
            logger.error("Failed to save speaker DB: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pre-assign participant names to unmatched speakers by speaking time.
    /// When unmatched remote speaker count == unmatched participant count,
    /// assign by descending speaking time order.
    /// This is a heuristic — the naming popup lets users correct mistakes.
    ///
    /// - Parameters:
    ///   - mapping: Current label → name mapping (from `match()`)
    ///   - speakingTimes: Speaking time per label
    ///   - participants: Meeting participant names (e.g. from Teams)
    ///   - excludeLabels: Labels to exclude (e.g. mic speaker already identified)
    /// - Returns: Updated mapping with participants pre-assigned
    static func preMatchParticipants(
        mapping: [String: String],
        speakingTimes: [String: TimeInterval],
        participants: [String],
        excludeLabels: Set<String> = [],
    ) -> [String: String] {
        // Find unmatched labels: name equals raw label (not yet named) and not excluded
        let unmatchedLabels = mapping.keys.filter { label in
            mapping[label] == label && !excludeLabels.contains(label)
        }

        // Find unused participants: not already assigned as a value in mapping
        let usedNames = Set(mapping.values)
        let unusedParticipants = participants.filter { !usedNames.contains($0) }

        // Only assign when counts match exactly
        guard unmatchedLabels.count == unusedParticipants.count,
              !unmatchedLabels.isEmpty else {
            return mapping
        }

        // Sort unmatched labels by speaking time descending
        let sortedLabels = unmatchedLabels.sorted { a, b in
            (speakingTimes[a] ?? 0) > (speakingTimes[b] ?? 0)
        }

        var updated = mapping
        for (label, participant) in zip(sortedLabels, unusedParticipants) {
            updated[label] = participant
        }

        return updated
    }

    /// Cosine distance: 0 = identical, 2 = opposite.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0 ..< a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 2 }
        return 1 - dot / denom
    }
}

// swiftlint:enable discouraged_optional_collection
