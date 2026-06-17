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

        /// Route the versioned automation surface. The query string is already
        /// stripped from `path` by the caller. Resources:
        /// - `POST /v1/jobs` — enqueue file paths, returns created job IDs
        /// - `GET  /v1/jobs/<id>` — job status (live or persisted terminal record)
        /// - `GET  /v1/jobs/<id>/naming` — pending speaker-naming choice
        /// - `POST /v1/jobs/<id>/naming` — confirm speaker names `{mapping}`
        /// - `POST /v1/jobs/<id>/naming/skip` — skip naming for one job
        func routeV1(_ request: HTTPRequest, path: String) -> HTTPResponse {
            // The caller (DebugRPCServer.route) already gated on the `/v1/jobs`
            // prefix, so comps[0..1] are always ["v1", "jobs"]; the count checks
            // below just keep indexing safe.
            let comps = path.split(separator: "/").map(String.init)

            if request.method == "POST", comps.count == 2 {
                return enqueueResponse(body: request.body)
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
                return skipJobNaming(jobID) ? HTTPResponse.ok() : HTTPResponse.notFound()
            }
            return HTTPResponse.notFound()
        }

        private func enqueueResponse(body: Data) -> HTTPResponse {
            guard let p = try? JSONDecoder().decode(EnqueueFilesPayload.self, from: body),
                  !p.paths.isEmpty
            else { return HTTPResponse.badRequest() }
            let ids = enqueueReturningIDs(p.paths.map { URL(fileURLWithPath: $0) })
            guard let body = try? JSONEncoder().encode(["jobIDs": ids.map(\.uuidString)]) else {
                return HTTPResponse.badRequest()
            }
            return HTTPResponse.ok(body: body, contentType: "application/json")
        }

        private func confirmNamingResponse(_ jobID: UUID, body: Data) -> HTTPResponse {
            guard let p = try? JSONDecoder().decode(ConfirmNamingPayload.self, from: body) else {
                return HTTPResponse.badRequest()
            }
            return confirmNaming(jobID, p.mapping) ? HTTPResponse.ok() : HTTPResponse.notFound()
        }

        /// JSON-encode `dto` (404 if nil, 400 if encoding fails).
        private func encodedOrNotFound(_ dto: (some Encodable)?) -> HTTPResponse {
            guard let dto else { return HTTPResponse.notFound() }
            guard let body = try? JSONEncoder().encode(dto) else { return HTTPResponse.badRequest() }
            return HTTPResponse.ok(body: body, contentType: "application/json")
        }
    }
#endif
