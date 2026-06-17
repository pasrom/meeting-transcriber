#if !APPSTORE
    import Foundation

    /// Minimal HTTP/1.1 response serialization for `DebugRPCServer`.
    /// Line-cap split out of DebugRPCServer.swift — pure value type.
    struct HTTPResponse {
        let status: Int
        let reason: String
        let body: Data
        let contentType: String

        static func ok(body: Data, contentType: String) -> Self {
            Self(status: 200, reason: "OK", body: body, contentType: contentType)
        }

        /// 200 with the plain-text `ok\n` body used by fire-and-forget actions.
        static func ok() -> Self {
            ok(body: Data("ok\n".utf8), contentType: "text/plain")
        }

        static func notFound() -> Self {
            Self(status: 404, reason: "Not Found", body: Data(), contentType: "text/plain")
        }

        static func unauthorized() -> Self {
            Self(status: 401, reason: "Unauthorized", body: Data(), contentType: "text/plain")
        }

        static func forbidden() -> Self {
            Self(status: 403, reason: "Forbidden", body: Data(), contentType: "text/plain")
        }

        static func badRequest() -> Self {
            Self(status: 400, reason: "Bad Request", body: Data(), contentType: "text/plain")
        }

        func serialize() -> Data {
            var response = "HTTP/1.1 \(status) \(reason)\r\n"
            response += "Content-Type: \(contentType)\r\n"
            response += "Content-Length: \(body.count)\r\n"
            response += "Connection: close\r\n"
            response += "\r\n"
            var out = Data(response.utf8)
            out.append(body)
            return out
        }
    }
#endif
