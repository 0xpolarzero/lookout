import Foundation
import Testing
@testable import Lookout

/// What the syncing's health says (DESIGN.md 5.9, 10.8): every enabled source is in it, and what is gone is not.
@MainActor
@Suite struct SyncHealth {
    private nonisolated static func reply(_ status: Int, _ body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private nonisolated static func issue(_ id: Int) -> String {
        """
        {"id": \(id), "number": \(id), "title": "PR \(id)", "body": null, "user": {"login": "x", "avatar_url": null, "type": "User"},
         "html_url": "https://github.com/a/b/pull/\(id)", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
         "pull_request": null, "repository_url": "https://api.github.com/repos/a/b"}
        """
    }

    @Test func stoppingAFailedRepositoryClearsItsFault() {
        let s = Store()
        s.persists = false
        s.repos = [RepoConfig(fullName: "a/one"), RepoConfig(fullName: "a/two")]
        s.repoErrors = ["a/one": "Forbidden"]
        #expect(s.syncFault(stale: false) == .partial)
        s.removeRepo(s.repos[0])
        #expect(s.repoErrors.isEmpty && s.syncFault(stale: false) == nil)
    }

    @Test func aRequestThatOutlivesItsRepositoryPublishesNoFault() async {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.settings.reviewRequests = false
        let repo = RepoConfig(fullName: "a/one")
        s.repos = [repo]
        // The repository is stopped while its first request is in flight, and that request then fails.
        s.gh.transport = { _ in
            await MainActor.run { s.removeRepo(repo) }
            return SyncHealth.reply(500, #"{"message": "Server error"}"#)
        }
        await s.pollAll()
        #expect(s.repoErrors.isEmpty)
    }

    @Test func anAnswerThatArrivesAfterTheRepositoryWasStoppedLeavesNothingInTheInbox() async {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.settings.reviewRequests = false
        var repo = RepoConfig(fullName: "a/one")
        repo.events = [.issueOpened]
        s.repos = [repo]
        let fresh = ISO8601DateFormatter().string(from: Date())
        let issue = """
            [{"id": 7, "number": 7, "title": "Late", "body": null, "user": {"login": "x", "avatar_url": null, "type": "User"},
              "html_url": "https://github.com/a/one/issues/7", "created_at": "\(fresh)", "updated_at": "\(fresh)", "pull_request": null}]
            """
        // Stop watching while the issues request is out; it then answers with a new issue.
        s.gh.transport = { request in
            if request.url?.path.hasSuffix("/issues") == true {
                await MainActor.run { s.removeRepo(repo) }
                return SyncHealth.reply(200, issue)
            }
            if request.url?.path.hasSuffix("/comments") == true { return SyncHealth.reply(200, "[]") }
            return SyncHealth.reply(500, #"{"message": "Not here"}"#)
        }
        let pulse = s.pulse
        await s.pollAll()
        #expect(s.repos.isEmpty && s.items.isEmpty && s.repoErrors.isEmpty)
        #expect(s.pulse == pulse)
    }

    @Test func aLaterReviewPageFailingKeepsTheRequestsAlreadyFetched() async {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.settings.didInitialReviewSync = true
        let page1 = "[" + (1...100).map(Self.issue).joined(separator: ",") + "]"
        s.gh.transport = { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            if page == "1" { return SyncHealth.reply(200, #"{"total_count": 101, "incomplete_results": false, "items": \#(page1)}"#) }
            return SyncHealth.reply(500, #"{"message": "Timed out"}"#)
        }
        await s.syncReviewRequests()
        #expect(s.items.filter { $0.kind == .reviewRequested }.count == 100)
        #expect(s.reviewRequestsError != nil && s.syncFault(stale: false) == .reviewRequests)
        // Nothing the failed page might have held is taken for gone: a request that was there stays.
        #expect(s.items.allSatisfy { $0.state.isOpen })
    }

    @Test func anIncompleteReviewSearchIsOneFaultOnEverySurface() {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.repos = [RepoConfig(fullName: "a/b")]
        s.lastSync = Date()
        #expect(s.syncFault(stale: false) == nil && s.inboxNotice() == nil)
        s.reviewRequestsIncomplete = true
        #expect(s.syncFault(stale: false) == .reviewRequestsCut)
        #expect(s.inboxNotice() == .reviewRequestsCut && s.inboxEmpty(.needsYou) == .nothingNew)
        #expect(SyncLine(s, now: Date()).text == SyncFault.reviewRequestsCut.phrase && SyncLine(s, now: Date()).isFault)
        #expect(SyncFault.reviewRequestsCut.tint == Theme.amber)
        // A search that failed outright is the louder fault; one that is switched off is none.
        s.reviewRequestsError = "Timed out"
        #expect(s.syncFault(stale: false) == .reviewRequests)
        s.reviewRequestsError = nil
        s.settings.reviewRequests = false
        #expect(s.syncFault(stale: false) == nil)
    }

    @Test func aSyncThatLeftCIBehindIsNotHealthy() {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.repos = [RepoConfig(fullName: "a/b")]
        let now = Date()
        s.lastSync = now
        s.ci = ["a/b": CIStatus(state: .success, branch: "main", sha: "s1", url: nil, failing: [], checkedAt: now.addingTimeInterval(-3 * 3600),
                                title: nil, updatedAt: now.addingTimeInterval(-3 * 3600))]
        // The inbox was checked a moment ago; CI's answer is three hours old. One health, on every surface.
        #expect(!s.isStale(at: now) && s.isCIStale(at: now))
        #expect(s.syncFault(stale: s.isStale(at: now), ciStale: s.isCIStale(at: now)) == .ciStale)
        #expect(s.inboxEmpty(.needsYou, now: now) == .nothingNew)
        let line = SyncLine(s, now: now)
        #expect(line.text == SyncFault.ciStale.phrase && line.isFault)
        // Checking CI again makes it healthy; the deadlines the gear waits on follow the answers and the interval.
        s.ci["a/b"]?.checkedAt = now
        #expect(s.syncFault(stale: false, ciStale: s.isCIStale(at: now)) == nil)
        let before = s.staleDeadlines
        s.settings.pollInterval = 300
        #expect(s.staleDeadlines != before && s.staleDeadlines.allSatisfy { $0 > now.addingTimeInterval(800) })
    }
}
