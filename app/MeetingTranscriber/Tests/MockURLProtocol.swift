import Foundation

/// Test URL-loading shim: route a `URLSession` through this (set
/// `configuration.protocolClasses = [MockURLProtocol.self]`) and drive responses
/// via the static handlers. Set the relevant handler before the request and
/// clear all of them in tearDown.
final class MockURLProtocol: URLProtocol {
    // URLSession serialises protocol callbacks per task; the handler is set
    // before the request is started and cleared in tearDown. No real race.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    // When set, the request fails at the transport layer with this error
    // (mirrors a connection refused / DNS failure / dropped socket). Takes
    // precedence over `handler` so the generator's catch path is exercised.
    nonisolated(unsafe) static var errorHandler: ((URLRequest) -> any Error)?
    // When set, delivers a NON-HTTP `URLResponse` (takes precedence over
    // `handler`) so the generator's `response as? HTTPURLResponse` guard fails.
    nonisolated(unsafe) static var rawResponseHandler: ((URLRequest) -> (URLResponse, Data))?
    // When set, delivers the response + data but NEVER finishes loading —
    // simulates a stream that trickles/stalls forever (the struggling-LLM case),
    // so the generator's total-deadline can be exercised.
    nonisolated(unsafe) static var hangHandler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let errorHandler = Self.errorHandler {
            client?.urlProtocol(self, didFailWithError: errorHandler(request))
            return
        }
        if let rawResponseHandler = Self.rawResponseHandler {
            let (response, data) = rawResponseHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if let hangHandler = Self.hangHandler {
            let (response, data) = hangHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            // Intentionally never finish — the stream stalls; only a total
            // deadline (not the idle timeout) can end this.
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
