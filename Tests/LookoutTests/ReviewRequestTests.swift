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

    @Test func aSearchThatOutlivesTheSwitchAddsNothing() async {
        let s = store { _ in .init(500, "") }
        // Review requests is turned off while the page is out.
        let gate = StubbedGitHub.Gate()
        s.gh.session = StubbedGitHub.session { _ in
            .init(200, #"{"total_count": 1, "incomplete_results": false, "items": [\#(Self.issue(1))]}"#, gate: gate)
        }
        let search = Task { await s.syncReviewRequests() }
        while gate.held == 0 { await Task.yield() }
        s.settings.reviewRequests = false
        gate.open()
        await search.value
        #expect(s.items.isEmpty)
        // Off and on again is a new switch too: what the old search brings back is not an answer to the new one.
        s.settings.reviewRequests = true
        let again = StubbedGitHub.Gate()
        s.gh.session = StubbedGitHub.session { _ in
            .init(200, #"{"total_count": 1, "incomplete_results": false, "items": [\#(Self.issue(2))]}"#, gate: again)
        }
        let second = Task { await s.syncReviewRequests() }
        while again.held == 0 { await Task.yield() }
        s.settings.reviewRequests = false
        s.settings.reviewRequests = true
        again.open()
        await second.value
        #expect(s.items.isEmpty)
        // The next one, begun after the switch, is.
        s.gh.session = StubbedGitHub.session { _ in
            .init(200, #"{"total_count": 1, "incomplete_results": false, "items": [\#(Self.issue(2))]}"#)
        }
        await s.syncReviewRequests()
        #expect(s.items.map(\.id) == ["rr#2"])
    }

    @Test func aFirstSearchThatIsCutShortStillArmsTheNotificationsForWhatComesLater() async {
        let s = store { _ in .init(200, #"{"total_count": 5, "incomplete_results": true, "items": [\#(Self.issue(1))]}"#) }
        s.settings.didInitialReviewSync = false
        // GitHub cuts the first search short: the baseline is what it listed.
        await s.syncReviewRequests()
        #expect(s.settings.didInitialReviewSync && s.settings.reviewBaselineAt != nil)
        // Backlog that turns up late (last touched before the baseline) is quiet; a request made since is news.
        let fresh = Self.issue(3, updated: "2999-01-01T00:00:00Z")
        s.gh.session = StubbedGitHub.session { _ in .init(200, #"{"total_count": 5, "incomplete_results": true, "items": [\#(Self.issue(1)), \#(Self.issue(2)), \#(fresh)]}"#) }
        await s.syncReviewRequests()
        let old = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01, what the fixtures were last touched
        #expect(s.items.first { $0.id == "rr#2" }?.createdAt == old)
        #expect(s.items.first { $0.id == "rr#3" }?.createdAt ?? old > old)
        // A complete search has listed everything: the baseline is no longer needed.
        s.gh.session = StubbedGitHub.session { _ in .init(200, #"{"total_count": 3, "incomplete_results": false, "items": [\#(Self.issue(1)), \#(Self.issue(2)), \#(fresh)]}"#) }
        await s.syncReviewRequests()
        #expect(s.settings.reviewBaselineAt == nil)
    }

    @Test func aCompleteFirstSearchLeavesNoBaseline() async {
        let s = store { _ in .init(200, #"{"total_count": 1, "incomplete_results": false, "items": [\#(Self.issue(1))]}"#) }
        s.settings.didInitialReviewSync = false
        await s.syncReviewRequests()
        #expect(s.settings.didInitialReviewSync && s.settings.reviewBaselineAt == nil)
    }
}
