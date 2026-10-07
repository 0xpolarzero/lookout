import Foundation
import Testing
@testable import Lookout

/// Answers every GitHub request from `handler`, so the store can run without a network.
final class StubAuthGitHub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (URLRequest) -> (status: Int, body: String) = { _ in (200, "[]") }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubAuthGitHub.self]
        return URLSession(configuration: config)
    }
}

@MainActor
@Suite(.serialized) struct Auth {
    private func store(login: String = "me") -> Store {
        let s = Store()
        s.persists = false
        s.gh.session = StubAuthGitHub.session
        s.gh.token = "token"
        s.me = GHUser(login: login, avatarUrl: nil, type: nil)
        return s
    }

    private func serveRepo(_ name: String) {
        StubAuthGitHub.handler = { req in
            req.url?.path.lowercased() == "/repos/\(name)".lowercased() ? (200, #"{"full_name":"\#(name)","default_branch":"main"}"#) : (200, "[]")
        }
    }

    @Test func aRepoYouOwnStartsWithAllComments() async {
        let s = store()
        serveRepo("Me/tool")
        #expect(await s.addRepo("me/tool") == nil)
        #expect(s.repos.map(\.allComments) == [true])
    }

    @Test func someoneElsesRepoStartsWithOnlyCommentsForYou() async {
        let s = store()
        serveRepo("other/tool")
        #expect(await s.addRepo("other/tool") == nil)
        #expect(s.repos.map(\.allComments) == [false])
    }
}
