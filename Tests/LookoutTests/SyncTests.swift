import Foundation
import Testing
@testable import Lookout

/// Answers GitHub requests from a table, so `sync` runs end to end without the network.
final class StubGitHub: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Data) -> Any] = [:]
    /// Paths requested, in order.
    nonisolated(unsafe) static var paths: [String] = []
    private static let lock = NSLock()

    static func reset(_ routes: [String: (Data) -> Any]) {
        lock.withLock {
            self.routes = routes
            paths = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(contentsOf: buffer[..<n])
            }
            stream.close()
        }
        let handler = Self.lock.withLock { () -> ((Data) -> Any)? in
            Self.paths.append(url.path)
            return Self.routes[url.path]
        }
        let json = handler?(body) ?? ["message": "unrouted"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let resp = HTTPURLResponse(url: url, statusCode: handler == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let iso = ISO8601DateFormatter()
private func stamp(_ date: Date) -> String { iso.string(from: date) }

private func user(_ login: String) -> [String: Any] {
    ["login": login, "avatar_url": "https://avatars.example/\(login)", "type": "User"]
}

private func comment(_ id: Int, on number: Int, by login: String, at date: Date, body: String = "hello") -> [String: Any] {
    ["id": id, "body": body, "user": user(login), "html_url": "https://github.com/a/r/issues/\(number)#issuecomment-\(id)",
     "created_at": stamp(date), "updated_at": stamp(date), "issue_url": "https://api.github.com/repos/a/r/issues/\(number)"]
}

/// Thread lookups: each requested number is an issue I opened, so its comments are for me.
private func threads(_ body: Data) -> Any {
    let query = (try? JSONSerialization.jsonObject(with: body) as? [String: String])?["query"] ?? ""
    var repo: [String: Any] = [:]
    for part in query.components(separatedBy: ": issueOrPullRequest").dropLast() {
        let n = part.split(separator: " ").last.map(String.init) ?? ""
        repo[n] = ["title": "Issue \(n.dropFirst())", "author": ["login": "me"],
                   "comments": ["nodes": []], "reviews": ["nodes": []]]
    }
    return ["data": ["repository": repo]]
}

@MainActor
@Suite(.serialized) struct Sync {
    init() { URLProtocol.registerClass(StubGitHub.self) }

    private func store(allComments: Bool = false) -> (Store, posted: Box) {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        var repo = RepoConfig(fullName: "a/r", allComments: allComments)
        repo.addedAt = Date().addingTimeInterval(-3600)
        s.repos = [repo]
        let posted = Box()
        s.notifier.onPost = { posted.ids.append($0) }
        return (s, posted)
    }

    final class Box { var ids: [String] = [] }

    @Test func aCommentIAnsweredBeforeThePollIsNotAnnounced() async {
        let (s, posted) = store(allComments: true)
        let now = Date()
        StubGitHub.reset([
            "/repos/a/r/issues": { _ in [] },
            "/repos/a/r/issues/comments": { _ in [
                comment(1, on: 7, by: "them", at: now.addingTimeInterval(-600)),
                comment(2, on: 7, by: "me", at: now.addingTimeInterval(-300)),
            ] },
            "/repos/a/r/pulls/comments": { _ in [] },
            "/graphql": threads,
        ])
        try? await s.syncConversations("a/r")
        #expect(s.items.map(\.id) == ["a/r#c#1"])
        #expect(s.items.first?.state == .addressed)
        #expect(posted.ids.isEmpty)
    }

    @Test func aCommentStillWaitingIsAnnounced() async {
        let (s, posted) = store(allComments: true)
        StubGitHub.reset([
            "/repos/a/r/issues": { _ in [] },
            "/repos/a/r/issues/comments": { _ in [comment(1, on: 7, by: "them", at: Date().addingTimeInterval(-600))] },
            "/repos/a/r/pulls/comments": { _ in [] },
            "/graphql": threads,
        ])
        try? await s.syncConversations("a/r")
        #expect(posted.ids == ["a/r#c#1"])
    }
}
