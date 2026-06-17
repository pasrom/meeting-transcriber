#if !APPSTORE
    import Foundation

    /// `/v1` automation-API routing, line-cap split from `DebugRPCServer.route`.
    extension DebugRPCServer {
        /// Route the versioned automation surface. `POST /v1/jobs` enqueues the
        /// given file paths and returns the created job IDs; `GET /v1/jobs/<id>`
        /// returns a job's status (live or persisted terminal record). The query
        /// string is already stripped from `path` by the caller.
        func routeV1(_ request: HTTPRequest, path: String) -> HTTPResponse {
            switch (request.method, path) {
            case ("POST", "/v1/jobs"):
                guard let p = try? JSONDecoder().decode(EnqueueFilesPayload.self, from: request.body),
                      !p.paths.isEmpty
                else { return HTTPResponse.badRequest() }
                let ids = enqueueReturningIDs(p.paths.map { URL(fileURLWithPath: $0) })
                guard let body = try? JSONEncoder().encode(["jobIDs": ids.map(\.uuidString)]) else {
                    return HTTPResponse.badRequest()
                }
                return HTTPResponse.ok(body: body, contentType: "application/json")

            case ("GET", _) where path.hasPrefix("/v1/jobs/"):
                let idString = String(path.dropFirst("/v1/jobs/".count))
                guard let uuid = UUID(uuidString: idString), let dto = jobStatus(uuid) else {
                    return HTTPResponse.notFound()
                }
                guard let body = try? JSONEncoder().encode(dto) else { return HTTPResponse.badRequest() }
                return HTTPResponse.ok(body: body, contentType: "application/json")

            default:
                return HTTPResponse.notFound()
            }
        }
    }
#endif
