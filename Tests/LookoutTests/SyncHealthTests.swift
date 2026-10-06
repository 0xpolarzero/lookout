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
}
