#if !APPSTORE
    import Foundation

    /// Response-only envelope for the `/v1` job-status endpoints: the persisted
    /// `JobStatusDTO` plus an optional inline `transcript`, flattened onto the
    /// same JSON object so the transcript is a top-level sibling of the status
    /// fields (issue #431). Kept as a distinct type from `JobStatusDTO` so the
    /// persisted/base shape can never carry — and never accidentally persist —
    /// transcript text; the text is attached only at response-render time.
    struct JobStatusResponse: Codable, Equatable {
        let status: JobStatusDTO
        let transcript: String?

        init(_ status: JobStatusDTO, transcript: String?) {
            self.status = status
            self.transcript = transcript
        }

        private enum CodingKeys: String, CodingKey { case transcript }

        init(from decoder: any Decoder) throws {
            status = try JobStatusDTO(from: decoder)
            transcript = try decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(String.self, forKey: .transcript)
        }

        func encode(to encoder: any Encoder) throws {
            try status.encode(to: encoder) // flattens the status fields into this object
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(transcript, forKey: .transcript)
        }
    }

    /// `/v1` automation-API routing, line-cap split from `DebugRPCServer.route`.
    extension DebugRPCServer {
        // Internal (not private): the legacy `/action/enqueueFiles` route in
        // DebugRPCServer.swift decodes it too.
        struct EnqueueFilesPayload: Decodable {
            let paths: [String]
        }

        private struct ConfirmNamingPayload: Decodable {
            let mapping: [String: String]
        }

        private struct TranscribePayload: Decodable {
            let path: String
            let maxWaitSeconds: Double?
        }

        /// Default / hard-cap blocking-transcribe wait (seconds).
        private static let defaultTranscribeWaitSeconds: Double = 600
        private static let maxTranscribeWaitSeconds: Double = 1800

        /// Whether the request target opted into an inline transcript via
        /// `?include=transcript`. Comma-separated include values are honoured
        /// (`?include=protocol,transcript`); the value match is case-insensitive.
        nonisolated static func wantsInlineTranscript(target: String) -> Bool {
            // Honour every `include=` param and each comma-separated value
            // within them (`?include=protocol&include=transcript` and
            // `?include=protocol,transcript` both opt in).
            HTTPRequest.queryValues(target: target, key: "include")
                .flatMap { $0.split(separator: ",") }
                .contains { $0.lowercased() == "transcript" }
        }

        /// Route the versioned automation surface. The query string is already
        /// stripped from `path` by the caller. Resources:
        /// - `POST /v1/transcribe` — enqueue one file, block until terminal
        /// - `POST /v1/jobs` — enqueue file paths, returns created job IDs
        /// - `GET  /v1/jobs/<id>` — job status (live or persisted terminal record)
        /// - `GET  /v1/jobs/<id>/naming` — pending speaker-naming choice
        /// - `POST /v1/jobs/<id>/naming` — confirm speaker names `{mapping}`
        /// - `POST /v1/jobs/<id>/naming/skip` — skip naming for one job
        /// - `GET  /v1/watch` — watching status
        /// - `POST /v1/watch` — start/stop/toggle watching `{action}`
        /// - `GET  /v1/record` — microphone-recording status
        /// - `POST /v1/record` — start/stop/toggle a microphone recording `{action}`
        func routeV1(_ request: HTTPRequest, path: String) async -> HTTPResponse {
            let idempotencyKey = request.headers["idempotency-key"]
            // `path` is query-stripped; read the opt-in off the raw target.
            let includeTranscript = Self.wantsInlineTranscript(target: request.path)
            if request.method == "POST", path == "/v1/transcribe" {
                return await transcribeResponse(
                    body: request.body, idempotencyKey: idempotencyKey, includeTranscript: includeTranscript,
                )
            }
            // Matched before the `/v1/jobs` component split below, which assumes
            // comps[0..1] == ["v1", "jobs"]. No `Idempotency-Key` handling: the
            // operation is already idempotent, and that header exists here only
            // to stop duplicate *job creation*.
            if let response = await controlResourceResponse(request, path: path) { return response }
            // The caller (DebugRPCServer.route) already gated on the `/v1/jobs`
            // prefix, so comps[0..1] are always ["v1", "jobs"]; the count checks
            // below just keep indexing safe.
            let comps = path.split(separator: "/").map(String.init)

            if request.method == "POST", comps.count == 2 {
                return enqueueResponse(body: request.body, idempotencyKey: idempotencyKey)
            }

            guard comps.count >= 3, let jobID = UUID(uuidString: comps[2]) else {
                return HTTPResponse.notFound()
            }
            let sub = Array(comps.dropFirst(3))

            if sub.isEmpty, request.method == "GET" {
                guard let dto = jobStatus(jobID) else { return HTTPResponse.notFound() }
                return encodedStatus(dto, includeTranscript: includeTranscript)
            }
            if sub == ["naming"], request.method == "GET" {
                return encodedOrNotFound(namingStatus(jobID))
            }
            if sub == ["naming"], request.method == "POST" {
                return confirmNamingResponse(jobID, body: request.body)
            }
            if sub == ["naming", "skip"], request.method == "POST" {
                return skipJobNaming(jobID) ? HTTPResponse.ok() : namingFailureStatus(jobID)
            }
            return HTTPResponse.notFound()
        }

        /// The paths `controlResourceResponse` claims. `DebugRPCServer.route`
        /// reads the same set to decide what to hand to `routeV1`, so a third
        /// resource is added in one place: splitting the two lists is how a new
        /// resource ends up answering 404 with its handler sitting right there.
        static let controlResourcePaths: Set<String> = ["/v1/watch", "/v1/record"]

        /// The two lifecycle resources — watching and microphone recording —
        /// which share a shape: GET reads the status, POST applies an action and
        /// answers with the state it settled into. Nil when `path` is neither, so
        /// the caller falls through to the `/v1/jobs` routing below.
        ///
        /// Matched here, before that routing splits the path into components and
        /// assumes it starts `["v1", "jobs"]`. Neither takes an
        /// `Idempotency-Key`: both are already idempotent, and that header exists
        /// on this API only to stop duplicate *job creation*.
        private func controlResourceResponse(
            _ request: HTTPRequest, path: String,
        ) async -> HTTPResponse? {
            guard Self.controlResourcePaths.contains(path) else { return nil }
            switch (path, request.method) {
            case ("/v1/watch", "GET"): return jsonResponse(watchStatus())
            case ("/v1/watch", "POST"): return await watchControlResponse(body: request.body)
            case ("/v1/record", "GET"): return jsonResponse(recordStatus())
            case ("/v1/record", "POST"): return await recordControlResponse(body: request.body)
            default: return HTTPResponse.notFound()
            }
        }

        /// JSON-encode a status payload with a caller-chosen code. Both control
        /// resources answer GET and POST with the *same* body shape, so a client
        /// parses one thing, and the code carries what the call achieved.
        ///
        /// Not snapshotted atomically with that outcome: the body is built after
        /// the action's `await` resumes, so a stop landing in between is
        /// reflected. Still better than making the client refetch, which races
        /// the same way and costs a round trip.
        private func jsonResponse(
            _ payload: some Encodable, status: Int = 200, reason: String = "OK",
        ) -> HTTPResponse {
            guard let body = try? JSONEncoder().encode(payload) else {
                return HTTPResponse.internalServerError()
            }
            return HTTPResponse(status: status, reason: reason, body: body, contentType: "application/json")
        }

        /// Failure status for confirm/skip naming: 409 when the job exists but
        /// isn't awaiting naming (wrong state), 404 when the job id is unknown.
        private func namingFailureStatus(_ jobID: UUID) -> HTTPResponse {
            jobStatus(jobID) != nil ? HTTPResponse.conflict() : HTTPResponse.notFound()
        }

        // MARK: - /v1/watch

        /// Apply a watch action and report the state it settled into.
        ///
        /// 409 for `.blocked` because `toggleWatching` silently refuses while a
        /// manual recording owns the loop; a refusal that looks like success is
        /// exactly the failure mode a remote key must not have. 503 for
        /// `.failed` — the request was accepted but the state did not converge,
        /// which is a different problem from being told no.
        private func watchControlResponse(body: Data) async -> HTTPResponse {
            guard let payload = try? JSONDecoder().decode(WatchActionPayload.self, from: body) else {
                return HTTPResponse.badRequest()
            }
            switch await watchControl(payload.action) {
            case .changed, .unchanged: return jsonResponse(watchStatus())
            case .blocked: return jsonResponse(watchStatus(), status: 409, reason: "Conflict")
            case .failed: return jsonResponse(watchStatus(), status: 503, reason: "Service Unavailable")
            }
        }

        // MARK: - /v1/record

        /// Apply a record action and report the state it settled into.
        ///
        /// The extra code over `/v1/watch` is 412. A `start` that cannot capture
        /// anything — "No Microphone" is set, or the microphone permission is
        /// denied or broken — is not a transient failure to retry (503) and not
        /// somebody else holding the loop (409). It stays refused until a switch
        /// is flipped, and the body says which one: `noMic` and
        /// `microphoneHealthy` tell the two apart.
        ///
        /// The contrast with `/v1/watch` is deliberate: a denied microphone
        /// answers `200` there, because app audio still records without it. Here
        /// nothing would, so 200 would be a lie.
        private func recordControlResponse(body: Data) async -> HTTPResponse {
            guard let payload = try? JSONDecoder().decode(RecordActionPayload.self, from: body) else {
                return HTTPResponse.badRequest()
            }
            switch await recordControl(payload.action) {
            case .changed, .unchanged: return jsonResponse(recordStatus())
            case .blocked: return jsonResponse(recordStatus(), status: 409, reason: "Conflict")
            case .refused: return jsonResponse(recordStatus(), status: 412, reason: "Precondition Failed")
            case .failed: return jsonResponse(recordStatus(), status: 503, reason: "Service Unavailable")
            }
        }

        private func enqueueResponse(body: Data, idempotencyKey: String?) -> HTTPResponse {
            guard let p = try? JSONDecoder().decode(EnqueueFilesPayload.self, from: body),
                  !p.paths.isEmpty
            else { return HTTPResponse.badRequest() }
            // Repeat with a seen key → the original jobIDs, no new job.
            if let key = idempotencyKey, let existing = idempotency.lookup(key) {
                return jobIDsResponse(existing)
            }
            let ids = enqueueReturningIDs(p.paths.map { URL(fileURLWithPath: $0) })
            if let key = idempotencyKey { idempotency.remember(key, ids) }
            return jobIDsResponse(ids)
        }

        private func jobIDsResponse(_ ids: [UUID]) -> HTTPResponse {
            guard let body = try? JSONEncoder().encode(["jobIDs": ids.map(\.uuidString)]) else {
                return HTTPResponse.badRequest()
            }
            return HTTPResponse.ok(body: body, contentType: "application/json")
        }

        private func transcribeResponse(
            body: Data, idempotencyKey: String?, includeTranscript: Bool,
        ) async -> HTTPResponse {
            guard let p = try? JSONDecoder().decode(TranscribePayload.self, from: body), !p.path.isEmpty
            else { return HTTPResponse.badRequest() }
            // Repeat with a seen key → the existing job's current status, no new
            // job. Falls through to a fresh run if that job has fully vanished.
            if let key = idempotencyKey, let existing = idempotency.lookup(key)?.first,
               let dto = jobStatus(existing) {
                return statusResponse(for: dto, includeTranscript: includeTranscript)
            }
            let requested = p.maxWaitSeconds ?? Self.defaultTranscribeWaitSeconds
            let wait = min(max(0, requested), Self.maxTranscribeWaitSeconds)
            let result = await transcribe(URL(fileURLWithPath: p.path), wait)
            if let key = idempotencyKey, let jobID = result.jobID { idempotency.remember(key, [jobID]) }
            switch result {
            case .noFile:
                return HTTPResponse.badRequest()

            case let .completed(dto):
                return statusResponse(for: dto, includeTranscript: includeTranscript)

            case let .timedOut(dto):
                guard let dto else { return HTTPResponse.badRequest() }
                return statusResponse(for: dto, includeTranscript: includeTranscript)
            }
        }

        /// Map a job status to its HTTP response: 200 with the DTO once terminal,
        /// 202 (still running; client polls GET /v1/jobs/<id>) otherwise. When the
        /// caller opted into `?include=transcript`, the terminal 200 carries the
        /// transcript text inline (the 202 path has no transcript yet).
        private func statusResponse(for dto: JobStatusDTO, includeTranscript: Bool) -> HTTPResponse {
            guard !dto.state.isTerminal else {
                return encodedStatus(dto, includeTranscript: includeTranscript)
            }
            guard let body = try? JSONEncoder().encode(dto) else { return HTTPResponse.badRequest() }
            return HTTPResponse(status: 202, reason: "Accepted", body: body, contentType: "application/json")
        }

        /// Encode a job status as a 200 — the single choke point that decides
        /// between the plain `JobStatusDTO` and the transcript-carrying
        /// `JobStatusResponse` based on the `?include=transcript` opt-in.
        private func encodedStatus(_ dto: JobStatusDTO, includeTranscript: Bool) -> HTTPResponse {
            guard includeTranscript else { return encodedOrNotFound(dto) }
            return encodedOrNotFound(JobStatusResponse(dto, transcript: readTranscript(dto)))
        }

        /// Read the transcript file at `dto.transcriptPath`, or nil when it is
        /// absent or unreadable — so opting in never turns a finished job into a
        /// failure, and a still-running job (no transcript yet) omits the field.
        private func readTranscript(_ dto: JobStatusDTO) -> String? {
            guard let path = dto.transcriptPath else { return nil }
            return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        }

        private func confirmNamingResponse(_ jobID: UUID, body: Data) -> HTTPResponse {
            guard let p = try? JSONDecoder().decode(ConfirmNamingPayload.self, from: body) else {
                return HTTPResponse.badRequest()
            }
            return confirmNaming(jobID, p.mapping) ? HTTPResponse.ok() : namingFailureStatus(jobID)
        }

        /// JSON-encode `dto` (404 if nil, 400 if encoding fails).
        private func encodedOrNotFound(_ dto: (some Encodable)?) -> HTTPResponse {
            guard let dto else { return HTTPResponse.notFound() }
            guard let body = try? JSONEncoder().encode(dto) else { return HTTPResponse.badRequest() }
            return HTTPResponse.ok(body: body, contentType: "application/json")
        }
    }
#endif
