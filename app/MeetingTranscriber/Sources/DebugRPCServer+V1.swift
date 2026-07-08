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
            guard let query = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return false }
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, kv[0] == "include" else { continue }
                if kv[1].split(separator: ",").contains(where: { $0.lowercased() == "transcript" }) {
                    return true
                }
            }
            return false
        }

        /// Route the versioned automation surface. The query string is already
        /// stripped from `path` by the caller. Resources:
        /// - `POST /v1/transcribe` — enqueue one file, block until terminal
        /// - `POST /v1/jobs` — enqueue file paths, returns created job IDs
        /// - `GET  /v1/jobs/<id>` — job status (live or persisted terminal record)
        /// - `GET  /v1/jobs/<id>/naming` — pending speaker-naming choice
        /// - `POST /v1/jobs/<id>/naming` — confirm speaker names `{mapping}`
        /// - `POST /v1/jobs/<id>/naming/skip` — skip naming for one job
        func routeV1(_ request: HTTPRequest, path: String) async -> HTTPResponse {
            let idempotencyKey = request.headers["idempotency-key"]
            // `path` is query-stripped; read the opt-in off the raw target.
            let includeTranscript = Self.wantsInlineTranscript(target: request.path)
            if request.method == "POST", path == "/v1/transcribe" {
                return await transcribeResponse(
                    body: request.body, idempotencyKey: idempotencyKey, includeTranscript: includeTranscript,
                )
            }
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

        /// Failure status for confirm/skip naming: 409 when the job exists but
        /// isn't awaiting naming (wrong state), 404 when the job id is unknown.
        private func namingFailureStatus(_ jobID: UUID) -> HTTPResponse {
            jobStatus(jobID) != nil ? HTTPResponse.conflict() : HTTPResponse.notFound()
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
