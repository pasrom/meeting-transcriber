#if !APPSTORE
    import Foundation

    /// What the `/v1` meeting-notes routes do, wired to `PipelineQueue` in
    /// `AppState.buildDebugRPCServer`. The defaults refuse, so a server built
    /// without them answers as if no job had notes to retry.
    struct MeetingNotesActions {
        /// `POST /v1/jobs/<id>/notes/retry`: whether the retry started.
        var retry: (UUID) -> Bool = { _ in false }
        /// `POST /v1/jobs/notes/retry`: the jobs whose retry started.
        var retryAll: () -> [UUID] = { [] }
    }

    /// `/v1` routes for meeting notes that could not be generated, kept apart
    /// from `DebugRPCServer+V1` like the other resources of their own.
    extension DebugRPCServer {
        /// Under `/v1/jobs/`, so `DebugRPCServer.route` already hands it to
        /// `routeV1`, which asks here before reading the third component as a
        /// job id.
        static let retryAllMeetingNotesPath = "/v1/jobs/notes/retry"

        /// - `POST /v1/jobs/<id>/notes/retry` — generate the job's notes again
        ///   from its saved transcript. 200 with the job's status once it is
        ///   queued; 409 when the job has no failed notes to retry, or the
        ///   retry refused (transcript unreadable, notes already there: the
        ///   job's warnings say which); 404 for an unknown id.
        /// - `POST /v1/jobs/notes/retry` — the same for every such job, 200 with
        ///   `{"jobIDs": [...]}` of the ones queued (empty when there were none).
        ///
        /// Nil for any other path, so `routeV1` carries on. No
        /// `Idempotency-Key`: a second call finds the job queued, not failed,
        /// and starts nothing.
        func meetingNotesResponse(_ request: HTTPRequest, path: String) -> HTTPResponse? {
            if path == Self.retryAllMeetingNotesPath {
                guard request.method == "POST" else { return HTTPResponse.notFound() }
                return Self.json(["jobIDs": meetingNotes.retryAll().map(\.uuidString)])
            }
            let comps = path.split(separator: "/").map(String.init)
            guard comps.count == 5, comps[0] == "v1", comps[1] == "jobs", comps[3...] == ["notes", "retry"],
                  let jobID = UUID(uuidString: comps[2]) else { return nil }
            guard request.method == "POST" else { return HTTPResponse.notFound() }
            guard jobStatus(jobID) != nil else { return HTTPResponse.notFound() }
            guard meetingNotes.retry(jobID), let dto = jobStatus(jobID) else { return HTTPResponse.conflict() }
            return Self.json(dto)
        }

        private static func json(_ payload: some Encodable) -> HTTPResponse {
            guard let body = try? JSONEncoder().encode(payload) else { return HTTPResponse.internalServerError() }
            return HTTPResponse.ok(body: body, contentType: "application/json")
        }
    }
#endif
