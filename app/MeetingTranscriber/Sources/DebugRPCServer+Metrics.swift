#if !APPSTORE
    import Foundation

    extension DebugRPCServer {
        /// `GET /metrics` handler: cumulative CPU/RAM/instruction counters of
        /// this process — driver scripts (e2e-cpu-load.sh) diff two snapshots
        /// to get average load over a window. Line-cap split from `route`.
        static func metricsResponse() -> HTTPResponse {
            guard let metrics = RPCResourceMetrics.captureCurrent(),
                  let json = try? JSONEncoder().encode(metrics)
            else {
                return HTTPResponse(
                    status: 500, reason: "Internal Server Error",
                    body: Data("rusage unavailable\n".utf8), contentType: "text/plain",
                )
            }
            return HTTPResponse.ok(body: json, contentType: "application/json")
        }
    }
#endif
