import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct ReviewRequests {
    private nonisolated static func issue(_ id: Int, updated: String = "2026-01-01T00:00:00Z") -> String {
        """
        {"id": \(id), "number": \(id), "title": "PR \(id)", "body": null, "user": {"login": "x", "avatar_url": null, "type": "User"},
         "html_url": "https://github.com/a/b/pull/\(id)", "created_at": "2026-01-01T00:00:00Z", "updated_at": "\(updated)",
         "pull_request": null, "repository_url": "https://api.github.com/repos/a/b"}
        """
    }

    private func request(_ id: Int) -> GHIssue {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(GHIssue.self, from: Data(Self.issue(id).utf8))
    }

    /// A store signed in, past its first sync, whose review search is answered by `handler`.
    private func store(_ handler: @escaping StubbedGitHub.Handler) -> Store {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.settings.didInitialReviewSync = true
        s.gh.session = StubbedGitHub.session(handler)
        return s
    }

    private nonisolated static func page(_ request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
    }

    @Test func requestsPastTheFirstPageAreListed() async {
        let first = "[" + (1...100).map { Self.issue($0) }.joined(separator: ",") + "]"
        let second = "[" + (101...130).map { Self.issue($0) }.joined(separator: ",") + "]"
        let s = store { request in
            .init(200, #"{"total_count": 130, "incomplete_results": false, "items": \#(Self.page(request) == "1" ? first : second)}"#)
        }
        await s.syncReviewRequests()
        #expect(s.items.filter { $0.kind == .reviewRequested }.count == 130)
    }

    @Test func aLaterPageFailingKeepsTheRequestsAlreadyFetched() async {
        let first = "[" + (1...100).map { Self.issue($0) }.joined(separator: ",") + "]"
        let s = store { request in
            if Self.page(request) == "1" { return .init(200, #"{"total_count": 101, "incomplete_results": false, "items": \#(first)}"#) }
            return .init(500, #"{"message": "Timed out"}"#)
        }
        s.applyReviewRequests([request(200)], complete: true)
        await s.syncReviewRequests()
        #expect(s.items.filter { $0.kind == .reviewRequested }.count == 101)
        // Nothing the failed page might have held is taken for gone: a request that was there stays.
        #expect(s.items.allSatisfy { $0.state.isOpen })
    }

    @Test func aRequestOffThePagesReadIsNotMarkedAddressed() {
        let s = store { _ in .init(500, "") }
        s.applyReviewRequests([request(1), request(2)], complete: true)
        s.applyReviewRequests([request(2)], complete: false)
        #expect(s.items.first { $0.id == "rr#1" }?.state == .unread)
        // Only a search that listed everything can say it left.
        s.applyReviewRequests([request(2)], complete: true)
        #expect(s.items.first { $0.id == "rr#1" }?.state == .addressed)
    }

    @Test func aSearchGitHubCutShortIsNotComplete() async {
        let s = store { _ in .init(200, #"{"total_count": 1, "incomplete_results": true, "items": [\#(Self.issue(2))]}"#) }
        s.applyReviewRequests([request(1), request(2)], complete: true)
        await s.syncReviewRequests()
        #expect(s.items.first { $0.id == "rr#1" }?.state == .unread)
    }

    @Test func aPartialFirstSyncIsStillTheFirst() {
        let s = store { _ in .init(500, "") }
        s.settings.didInitialReviewSync = false
        s.applyReviewRequests([request(1)], complete: false)
        #expect(!s.settings.didInitialReviewSync)
        s.applyReviewRequests([request(1)], complete: true)
        #expect(s.settings.didInitialReviewSync)
    }
}
