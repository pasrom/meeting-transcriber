#if !APPSTORE
    import Foundation

    /// Minimal HTTP/1.1 request parsing for `DebugRPCServer`.
    /// Line-cap split out of DebugRPCServer.swift — pure value type.
    struct HTTPRequest: Equatable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
        }

        static func parse(_ data: Data) -> Self? {
            let separator = Data("\r\n\r\n".utf8)
            guard let separatorRange = data.range(of: separator) else { return nil }
            let headerData = data.subdata(in: 0 ..< separatorRange.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            let method = String(parts[0])
            let path = String(parts[1])

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                guard pieces.count == 2 else { continue }
                let key = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = pieces[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            // Reject a negative Content-Length before it reaches the body range:
            // `bodyStart ..< bodyStart + contentLength` would otherwise trap on
            // `lowerBound > upperBound`, aborting the process pre-auth.
            guard contentLength >= 0 else { return nil }
            let bodyStart = separatorRange.upperBound
            let availableBody = data.count - bodyStart
            guard availableBody >= contentLength else { return nil }
            let body = data.subdata(in: bodyStart ..< bodyStart + contentLength)
            return Self(method: method, path: path, headers: headers, body: body)
        }
    }
#endif
