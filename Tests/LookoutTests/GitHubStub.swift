import Foundation
import os

/// A GitHub that answers from a closure, so the client and the store run without a network. Each session has its own
/// closure (found by a header the session adds), so suites that use it don't have to run one at a time.
final class StubbedGitHub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// The answer is not given until this opens.
        var gate: Gate?

        init(_ status: Int = 200, _ body: String = "", headers: [String: String] = [:], gate: Gate? = nil) {
            self.status = status
            self.headers = headers
            self.body = Data(body.utf8)
            self.gate = gate
        }
    }

    /// Holds answers back, so one can land after something else happened.
    final class Gate: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (isOpen: false, waiting: [@Sendable () -> Void]()))

        /// How many answers are held.
        var held: Int { state.withLock { $0.waiting.count } }

        func open() {
            let waiting = state.withLock { state -> [@Sendable () -> Void] in
                state.isOpen = true
                defer { state.waiting = [] }
                return state.waiting
            }
            waiting.forEach { $0() }
        }

        fileprivate func hold(_ answer: @escaping @Sendable () -> Void) {
            let now = state.withLock { state -> Bool in
                if !state.isOpen { state.waiting.append(answer) }
                return state.isOpen
            }
            if now { answer() }
        }
    }

    typealias Handler = @Sendable (URLRequest) throws -> Reply

    private static let handlers = OSAllocatedUnfairLock(initialState: [String: Handler]())
    private static let header = "X-Stub-Id"

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        handlers.withLock { $0[id] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubbedGitHub.self]
        config.httpAdditionalHeaders = [header: id]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = request.value(forHTTPHeaderField: Self.header).flatMap { id in Self.handlers.withLock { $0[id] } }
        do {
            let reply = try handler.map { try $0(request) } ?? Reply(500)
            let answer: @Sendable () -> Void = { [self] in
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.body)
                client?.urlProtocolDidFinishLoading(self)
            }
            if let gate = reply.gate { gate.hold(answer) } else { answer() }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
