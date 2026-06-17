#if !APPSTORE
    import Foundation

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
            if request.method == "POST", path == "/v1/transcribe" {
                return await transcribeResponse(body: request.body, idempotencyKey: idempotencyKey)
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
                return encodedOrNotFound(jobStatus(jobID))
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

        private func transcribeResponse(body: Data, idempotencyKey: String?) async -> HTTPResponse {
            guard let p = try? JSONDecoder().decode(TranscribePayload.self, from: body), !p.path.isEmpty
            else { return HTTPResponse.badRequest() }
            // Repeat with a seen key → the existing job's current status, no new
            // job. Falls through to a fresh run if that job has fully vanished.
            if let key = idempotencyKey, let existing = idempotency.lookup(key)?.first,
               let dto = jobStatus(existing) {
                return statusResponse(for: dto)
            }
            let requested = p.maxWaitSeconds ?? Self.defaultTranscribeWaitSeconds
            let wait = min(max(0, requested), Self.maxTranscribeWaitSeconds)
            let result = await transcribe(URL(fileURLWithPath: p.path), wait)
            if let key = idempotencyKey, let jobID = result.jobID { idempotency.remember(key, [jobID]) }
            switch result {
            case .noFile:
                return HTTPResponse.badRequest()

            case let .completed(dto):
                return statusResponse(for: dto)

            case let .timedOut(dto):
                guard let dto else { return HTTPResponse.badRequest() }
                return statusResponse(for: dto)
            }
        }

        /// Map a job status to its HTTP response: 200 with the DTO once terminal,
        /// 202 (still running; client polls GET /v1/jobs/<id>) otherwise.
        private func statusResponse(for dto: JobStatusDTO) -> HTTPResponse {
            guard !dto.state.isTerminal else { return encodedOrNotFound(dto) }
            guard let body = try? JSONEncoder().encode(dto) else { return HTTPResponse.badRequest() }
            return HTTPResponse(status: 202, reason: "Accepted", body: body, contentType: "application/json")
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
