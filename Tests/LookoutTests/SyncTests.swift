import Foundation
import Testing
import UserNotifications
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
        s.notifier.onPost = { posted.ids.append($0.identifier) }
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

    @Test func relevanceIsFetchedForEveryNumberOfASync() async {
        let (s, _) = store()
        let now = Date()
        // Comments on 45 different threads, all mine: the five lowest numbers used to be left out and dropped.
        let comments = (1...45).map { comment(100 + $0, on: $0, by: "them", at: now.addingTimeInterval(-600)) }
        StubGitHub.reset([
            "/repos/a/r/issues": { _ in [] },
            "/repos/a/r/issues/comments": { _ in comments },
            "/repos/a/r/pulls/comments": { _ in [] },
            "/graphql": threads,
        ])
        try? await s.syncConversations("a/r")
        #expect(s.items.count == 45)
        #expect(StubGitHub.paths.filter { $0 == "/graphql" }.count == 2)
    }

    @Test func threadsGraphQLCouldntAnswerAreKeptNotDropped() async {
        let (s, _) = store()
        let now = Date().addingTimeInterval(-600)
        StubGitHub.reset([
            "/repos/a/r/issues": { _ in [] },
            "/repos/a/r/issues/comments": { _ in (1...3).map { comment(100 + $0, on: $0, by: "them", at: now) } },
            "/repos/a/r/pulls/comments": { _ in [] },
            // Thread 1 answered (mine), 2 reported as an error, 3 left out: only 1 is known.
            "/graphql": { _ in [
                "data": ["repository": [
                    "n1": ["title": "One", "author": ["login": "me"], "comments": ["nodes": []], "reviews": ["nodes": []]],
                    "n2": NSNull(),
                ]],
                "errors": [["type": "NOT_FOUND", "path": ["repository", "n2"], "message": "gone"]],
            ] },
        ])
        try? await s.syncConversations("a/r")
        #expect(s.items.map(\.id).sorted() == ["a/r#c#101", "a/r#c#102", "a/r#c#103"])
        #expect(s.items.sorted { $0.number < $1.number }.map(\.forYou) == [true, nil, nil])
    }

    @Test func aThreadWhoseHistoryWasCutOffIsKept() async {
        let (s, _) = store()
        StubGitHub.reset([
            "/repos/a/r/issues": { _ in [] },
            "/repos/a/r/issues/comments": { _ in [comment(1, on: 7, by: "them", at: Date().addingTimeInterval(-600))] },
            "/repos/a/r/pulls/comments": { _ in [] },
            // Someone else's thread whose comment list has earlier pages I can't see.
            "/graphql": { _ in ["data": ["repository": ["n7": [
                "title": "Seven", "author": ["login": "other"],
                "comments": ["pageInfo": ["hasPreviousPage": true], "nodes": []], "reviews": ["nodes": []],
            ]]]] },
        ])
        try? await s.syncConversations("a/r")
        #expect(s.items.map(\.forYou) == [nil])
    }

    @Test func anErrorWithoutAPathLeavesTheWholeBatchUnknown() async {
        let (s, _) = store()
        StubGitHub.reset([
            "/repos/a/r/issues": { _ in [] },
            "/repos/a/r/issues/comments": { _ in [comment(1, on: 7, by: "them", at: Date().addingTimeInterval(-600))] },
            "/repos/a/r/pulls/comments": { _ in [] },
            "/graphql": { body in
                var json = threads(body) as! [String: Any]
                json["errors"] = [["type": "RESOURCE_LIMITS_EXCEEDED", "message": "slow down"]]
                return json
            },
        ])
        try? await s.syncConversations("a/r")
        #expect(s.items.map(\.forYou) == [nil])
    }

    // MARK: Review requests

    private func request(_ id: Int, number: Int = 5) -> [String: Any] {
        ["id": id, "number": number, "title": "Fix it", "body": "", "user": user("them"),
         "html_url": "https://github.com/a/r/pull/\(number)", "repository_url": "https://api.github.com/repos/a/r",
         "created_at": stamp(Date()), "updated_at": stamp(Date()), "pull_request": ["url": "https://api.github.com/repos/a/r/pulls/\(number)"]]
    }

    /// Polls with `open` as the search result (`total` is what GitHub says exists, if more than it returned).
    private func poll(_ s: Store, _ open: [[String: Any]], total: Int? = nil) async {
        StubGitHub.reset(["/search/issues": { _ in
            ["items": open, "total_count": total ?? open.count, "incomplete_results": false]
        }])
        await s.syncReviewRequests()
    }

    private func reviewStore() -> (Store, posted: Box) {
        let (s, posted) = store()
        s.settings.didInitialReviewSync = true
        return (s, posted)
    }

    @Test func aRequestThatWentAwayAfterDoneComesBackUnread() async {
        let (s, posted) = reviewStore()
        await poll(s, [request(1)])
        #expect(posted.ids == ["rr#1"])
        s.discard(s.items[0])
        await poll(s, [request(1)])  // still requested: Done sticks
        #expect(s.items.first?.state == .discarded)
        #expect(posted.ids == ["rr#1"])
        await poll(s, [])  // I reviewed it
        await poll(s, [request(1)])  // and was asked again
        #expect(s.items.map(\.state) == [.unread])
        #expect(posted.ids == ["rr#1", "rr#1"])
    }

    @Test func aRequestThatWentAwayAfterBeingAnsweredComesBackUnread() async {
        let (s, posted) = reviewStore()
        await poll(s, [request(1)])
        await poll(s, [])
        #expect(s.items.first?.state == .addressed)
        await poll(s, [request(1)])
        #expect(s.items.map(\.state) == [.unread])
        #expect(posted.ids == ["rr#1", "rr#1"])
    }

    @Test func aDoneRequestStillRequestedOutlivesPruning() async {
        let (s, posted) = reviewStore()
        await poll(s, [request(1)])
        s.discard(s.items[0])
        s.items[0].createdAt = Date().addingTimeInterval(-90 * 86400)
        s.prune()  // nothing listed it yet since launch: can't tell it's gone
        #expect(s.items.count == 1)
        await poll(s, [request(1)])
        s.prune()
        #expect(s.items.map(\.state) == [.discarded])
        #expect(posted.ids == ["rr#1"])
        await poll(s, [])  // gone: forgotten
        #expect(s.items.isEmpty)
    }

    @Test func aTruncatedSearchDoesNotMakeRequestsDisappear() async {
        let (s, posted) = reviewStore()
        await poll(s, [request(1)])
        s.discard(s.items[0])
        await poll(s, [request(2)], total: 2)  // request 1 just didn't fit in the page
        #expect(s.items.first { $0.id == "rr#1" }?.state == .discarded)
        await poll(s, [request(1)], total: 1)
        #expect(s.items.first { $0.id == "rr#1" }?.state == .discarded)
        #expect(posted.ids == ["rr#1", "rr#2"])
    }

    // MARK: Removing a repo

    private func item(_ id: String, _ repo: String, _ kind: EventKind) -> InboxItem {
        InboxItem(id: id, repo: repo, kind: kind, number: 1, title: "t", snippet: "", author: "x", avatar: nil,
                  authorIsApp: false, url: URL(string: "https://github.com/\(repo)/issues/1")!, createdAt: Date(), state: .unread)
    }

    @Test func removingARepoWithdrawsItsBanners() {
        let (s, _) = store()
        s.items = [item("a/r#c#1", "a/r", .issueComment), item("rr#9", "a/r", .reviewRequested), item("b/q#c#2", "b/q", .issueComment)]
        var withdrawn: [String] = []
        s.notifier.onRemove = { withdrawn += $0 }
        s.removeRepo(s.repos[0])
        #expect(s.items.map(\.id) == ["rr#9", "b/q#c#2"])
        #expect(withdrawn == ["a/r#c#1"])
    }

    private func request(_ id: String) -> UNNotificationRequest {
        UNNotificationRequest(identifier: id, content: UNMutableNotificationContent(), trigger: nil)
    }

    @Test func removingARepoWithdrawsCIBannersStillWaitingToShow() {
        let (s, _) = store()
        s.notifier.lookup = { $0([request("https://github.com/a/r/commit/abc"), request("https://github.com/b/q/commit/def")]) }
        var withdrawn: [String] = []
        s.notifier.onRemove = { withdrawn += $0 }
        s.removeRepo(s.repos[0])
        #expect(withdrawn == ["https://github.com/a/r/commit/abc"])
    }

    @Test func aBulkSummaryIsWithdrawnWithItsRepoAndOpensTheInbox() async {
        let (s, _) = store(allComments: true)
        var requests: [UNNotificationRequest] = []
        s.notifier.onPost = { requests.append($0) }
        let now = Date()
        StubGitHub.reset([
            "/repos/a/r/issues": { _ in [] },
            "/repos/a/r/issues/comments": { _ in (1...5).map { comment($0, on: $0, by: "them", at: now.addingTimeInterval(-600)) } },
            "/repos/a/r/pulls/comments": { _ in [] },
            "/graphql": threads,
        ])
        try? await s.syncConversations("a/r")
        // Five arrivals make one summary, which says which repos it covers.
        #expect(requests.count == 1)
        let summary = requests[0]
        #expect(summary.identifier.hasPrefix(Notifier.summaryPrefix))
        #expect(Notifier.belongs(summary, to: "a/r"))
        #expect(!Notifier.belongs(summary, to: "a/other"))

        s.notifier.lookup = { $0([summary, self.request("unrelated")]) }
        var withdrawn: [String] = []
        s.notifier.onRemove = { withdrawn += $0 }
        s.removeRepo(s.repos[0])
        #expect(withdrawn.contains(summary.identifier))
        #expect(!withdrawn.contains("unrelated"))

        var opened = 0
        s.onOpenInbox = { opened += 1 }
        s.openNotification(id: summary.identifier, url: "")
        #expect(opened == 1)
    }

    @Test func ciBannersAreToldApartByRepo() {
        #expect(Notifier.isCI("https://github.com/a/r/commit/abc", of: "a/r"))
        #expect(!Notifier.isCI("https://github.com/a/r2/commit/abc", of: "a/r"))
        #expect(!Notifier.isCI("a/r#c#1", of: "a/r"))
    }
}
