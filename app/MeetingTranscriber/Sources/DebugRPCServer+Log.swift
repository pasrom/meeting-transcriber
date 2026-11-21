#if !APPSTORE
    import Foundation
    import OSLog

    /// One unified-log entry as `GET /log` returns it.
    struct RPCLogEntry: Encodable, Sendable {
        let date: Date
        /// `info`, `notice`, `error`, `fault` or `undefined`; `debug` only
        /// when debug logging was enabled for the process (a logging profile
        /// or `log config`), because the store does not keep debug entries
        /// otherwise (measured on macOS 27.2).
        let level: String
        let subsystem: String
        let category: String
        let message: String
    }

    /// The body of `GET /log`: the entries, oldest first, and whether `limit`
    /// cut older ones off.
    struct RPCLogResponse: Encodable {
        let entries: [RPCLogEntry]
        let truncated: Bool
    }

    /// The query parameters of `GET /log`.
    ///
    /// `since` is a number of seconds back from the moment the request is
    /// served, not a date: a driver script then needs no clock format and no
    /// agreement on time zones with the app, and the app's own clock decides
    /// the cutoff. `limit` is how many entries, at most, the response carries;
    /// the newest are kept.
    struct RPCLogQuery: Equatable {
        static let defaultSinceSeconds: TimeInterval = 300
        static let defaultLimit = 500
        /// Also bounds what a read holds in memory: the collector holds fewer
        /// than `2 * limit` entries while the reader walks the store.
        static let maxLimit = 5000

        let sinceSeconds: TimeInterval
        let limit: Int

        /// nil when a parameter is present and malformed: `since` must be a
        /// finite number of seconds, zero or more, and `limit` a whole number,
        /// one or more. A `limit` above `maxLimit` is lowered to it. A parameter
        /// with no value counts as absent, unknown ones are ignored, and for a
        /// repeated one the first value counts.
        static func parse(target: String) -> Self? {
            var since = defaultSinceSeconds
            if let raw = HTTPRequest.queryValues(target: target, key: "since").first {
                guard let value = Double(raw), value.isFinite, value >= 0 else { return nil }
                since = value
            }
            var limit = defaultLimit
            if let raw = HTTPRequest.queryValues(target: target, key: "limit").first {
                guard let value = Int(raw), value >= 1 else { return nil }
                limit = min(value, maxLimit)
            }
            return Self(sinceSeconds: since, limit: limit)
        }
    }

    /// Collects what `GET /log` returns from the entries a reader hands it:
    /// the app's own subsystems only, from `since` on, and of those the
    /// newest `limit`, oldest first. Filtered here as well as in the store
    /// query, because this is the tested guard and `OSLogStore.position(date:)`
    /// is reported to be ignored for the process scope on some releases;
    /// filtering before keeping is what stops a foreign or older entry from
    /// using up `limit`. Holds fewer than `2 * limit` entries at any time,
    /// however many it is handed: once it reaches that it drops the older
    /// half in one go, one copy per `limit` entries rather than per entry.
    struct RPCLogCollector {
        let since: Date
        let limit: Int
        private var held: [RPCLogEntry] = []
        private var accepted = 0

        mutating func add(_ entry: RPCLogEntry) {
            guard entry.date >= since, Self.isAppLogSubsystem(entry.subsystem) else { return }
            accepted += 1
            held.append(entry)
            if held.count >= 2 * limit { held.removeFirst(held.count - limit) }
            // The memory bound the type promises, checked where tests can trip
            // it without `held` being visible outside the type.
            assert(held.count < 2 * limit, "the collector outgrew its bound")
        }

        var response: RPCLogResponse {
            RPCLogResponse(entries: Array(held.suffix(limit)), truncated: accepted > limit)
        }

        /// `com.meetingtranscriber` and its children (`.audiotap`), not a
        /// lookalike such as `com.meetingtranscriberx`.
        static func isAppLogSubsystem(_ subsystem: String) -> Bool {
            subsystem == AppPaths.logSubsystem || subsystem.hasPrefix(AppPaths.logSubsystem + ".")
        }
    }

    extension DebugRPCServer {
        /// Hands `visit` the entries from `since` on, oldest first, one at a
        /// time, so the caller decides what to keep. The production reader is
        /// `osLogStoreReader`; tests inject their own.
        typealias LogReader = @Sendable (_ since: Date, _ visit: (RPCLogEntry) -> Void) throws -> Void

        /// `GET /log` handler. Debug only and deliberately not under `/v1`:
        /// log lines can carry meeting titles and participant names, so they
        /// get no stability contract that would invite outside clients.
        ///
        /// The store is read, filtered and encoded on a detached task, never
        /// on the main actor that serves the route: `getEntries` walks every
        /// entry of the process since `since`, which can take seconds in an
        /// app that has run for days, and up to `maxLimit` entries are
        /// encoded. One read at a time: a client that times out does not
        /// cancel its walk, so a polling driver would otherwise stack walks
        /// inside the app it is measuring. There is no timeout: a `getEntries`
        /// that never returned would keep this server answering 429 until the
        /// API is turned off and on again, which builds a new server; the hung
        /// walk stays parked on its thread, and a new server can start another
        /// one. Accepted for a debug route, since no hang has been seen. 400 on
        /// a malformed query and 429 while another read runs (the store is
        /// not read for either), 503 when the store cannot be opened or read.
        func logResponse(target: String) async -> HTTPResponse {
            guard let query = RPCLogQuery.parse(target: target) else { return HTTPResponse.badRequest() }
            guard !logReadInFlight else {
                return HTTPResponse(
                    status: 429, reason: "Too Many Requests",
                    body: Data("another log read is still running\n".utf8), contentType: "text/plain",
                )
            }
            logReadInFlight = true
            defer { logReadInFlight = false }
            let since = Date().addingTimeInterval(-query.sinceSeconds)
            let reader = logReader
            let outcome = await Task.detached(priority: .utility) { () -> Result<Data, any Error> in
                Result {
                    var collector = RPCLogCollector(since: since, limit: query.limit)
                    try reader(since) { collector.add($0) }
                    return try Self.logEncoder.encode(collector.response)
                }
            }.value
            switch outcome {
            case let .success(json):
                return HTTPResponse.ok(body: json, contentType: "application/json")

            case .failure(is EncodingError):
                return HTTPResponse.internalServerError()

            case let .failure(error):
                return HTTPResponse.serviceUnavailable(
                    "log store unavailable (\(DiagnosticExporter.errorCode(error)))\n",
                )
            }
        }

        /// This process's entries in the unified log. Needs a user that can
        /// read its own log store; where opening or reading the store throws,
        /// the route answers 503. That was observed once on the self-hosted CI
        /// runner (non-admin account, under AddressSanitizer, run
        /// 44952578295); the cause is not isolated. The diagnostics export
        /// walks the same store with its own reader (`DiagnosticExporter`).
        nonisolated static let osLogStoreReader: LogReader = { since, visit in
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(
                format: "subsystem == %@ OR subsystem BEGINSWITH %@",
                AppPaths.logSubsystem, AppPaths.logSubsystem + ".",
            )
            for entry in try store.getEntries(at: store.position(date: since), matching: predicate) {
                // Before `composedMessage`: formatting is the costly part, and
                // `position(date:)` may not have skipped the older entries.
                guard let log = entry as? OSLogEntryLog, log.date >= since else { continue }
                visit(RPCLogEntry(
                    date: log.date, level: levelName(log.level),
                    subsystem: log.subsystem, category: log.category, message: log.composedMessage,
                ))
            }
        }

        nonisolated private static func levelName(_ level: OSLogEntryLog.Level) -> String {
            switch level {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .error: "error"
            case .fault: "fault"
            case .undefined: "undefined"
            @unknown default: "undefined"
            }
        }

        nonisolated private static let logDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        /// ISO 8601 with fractional seconds: entries a few milliseconds apart
        /// stay distinguishable.
        nonisolated private static var logEncoder: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(date.formatted(logDateStyle))
            }
            return encoder
        }
    }
#endif
