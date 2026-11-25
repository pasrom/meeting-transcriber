import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum MCPOAuthHTTP {
    static func send(_ request: URLRequest, _ readBody: Bool) async throws -> MCPOAuthResponse {
        let configuration = URLSessionConfiguration.ephemeral
        let timeout = min(request.timeoutInterval, TimeInterval(ContextLimits.operationSeconds))
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        #if canImport(Darwin)
            let (bytes, received) = try await session.bytes(for: request)
            response = received
            var buffer = Data()
            if readBody {
                for try await byte in bytes {
                    guard buffer.count < ContextLimits.wire else { throw ContextFailure.limit }
                    buffer.append(byte)
                }
            }
            data = buffer
        #else
            (data, response) = try await session.data(for: request)
            guard data.count <= ContextLimits.wire else { throw ContextFailure.limit }
        #endif
        guard let http = response as? HTTPURLResponse else { throw MCPOAuthError.discovery }
        return MCPOAuthResponse(status: http.statusCode, challenge: http.value(forHTTPHeaderField: "WWW-Authenticate"), body: data)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest, completionHandler: @Sendable (URLRequest?) -> Void,
        ) {
            completionHandler(nil)
        }
    }
}
