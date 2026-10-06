import Foundation
import os
import Testing
@testable import Lookout

/// What the syncing's health says (DESIGN.md 5.9, 10.8): every enabled source is in it, and what is gone is not.
@MainActor
@Suite struct SyncHealth {
    private nonisolated static func reply(_ status: Int, _ body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private nonisolated static func issue(_ id: Int, updated: String = "2026-01-01T00:00:00Z") -> String {
        """
        {"id": \(id), "number": \(id), "title": "PR \(id)", "body": null, "user": {"login": "x", "avatar_url": null, "type": "User"},
         "html_url": "https://github.com/a/b/pull/\(id)", "created_at": "2026-01-01T00:00:00Z", "updated_at": "\(updated)",
         "pull_request": null, "repository_url": "https://api.github.com/repos/a/b"}
        """
    }

    @Test func pollsThatCantReachGitHubKeepTheTokenTheyHaveInsteadOfFindingOneEachTime() async {
        let s = Store.unsaved()
        let asks = OSAllocatedUnfairLock(initialState: 0)
        s.resolveToken = { asks.withLock { $0 += 1 }; return ("token", .environment) }
        s.keychainWrite = { _, _ in true }
        s.interceptRefresh = {}
        // Offline: finding a token reads the Keychain and may run gh, which every poll would do at rest.
        s.gh.transport = { _ in throw URLError(.notConnectedToInternet) }
        for _ in 0..<3 { await s.pollAll() }
        #expect(asks.withLock { $0 } == 1 && s.me == nil && s.gh.token == "token")
        // GitHub refuses it: another is looked for, on the next poll.
        s.gh.transport = { _ in SyncHealth.reply(401, #"{"message": "Bad credentials"}"#) }
        await s.pollAll()
        #expect(asks.withLock { $0 } == 1 && s.gh.token == nil)
        s.gh.transport = { _ in SyncHealth.reply(200, #"{"login": "me", "avatar_url": null, "type": "User"}"#) }
        await s.pollAll()
        #expect(asks.withLock { $0 } == 2 && s.me?.login == "me")
        // A token saved in Settings is looked for too.
        s.me = nil
        s.setToken("new")
        await s.pollAll()
        #expect(asks.withLock { $0 } == 3 && s.me != nil)
    }

    @Test func signedOutPollsLookForATokenEachTimeSoALoginIsNoticed() async {
        let s = Store.unsaved()
        let asks = OSAllocatedUnfairLock(initialState: 0)
        s.resolveToken = { asks.withLock { $0 += 1 }; return nil }
        for _ in 0..<2 { await s.pollAll() }
        #expect(asks.withLock { $0 } == 2 && s.authError == SignInFailure.missingToken)
    }

    @Test func stoppingAFailedRepositoryClearsItsFault() {
        let s = Store.unsaved()
        s.repos = [RepoConfig(fullName: "a/one"), RepoConfig(fullName: "a/two")]
        s.repoErrors = ["a/one": "Forbidden"]
        #expect(s.syncFault(stale: false) == .partial)
        s.removeRepo(s.repos[0])
        #expect(s.repoErrors.isEmpty && s.syncFault(stale: false) == nil)
    }

    @Test func aRequestThatOutlivesItsRepositoryPublishesNoFault() async {
        let s = Store.unsaved(signedInAs: "me")
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
        let s = Store.unsaved(signedInAs: "me")
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

    @Test func aCIChecksOwnFailureIsInTheHealthAndSoIsItsRecovery() async {
        let s = Store.unsaved(signedInAs: "me")
        s.repos = [RepoConfig(fullName: "a/x")]
        nonisolated(unsafe) var offline = true
        let answer = ciStatus(.success, sha: "s1")
        s.ciFetch = { _ in
            if offline { throw GitHubError(message: "The Internet connection appears to be offline") }
            return answer
        }
        // Check now with no network: the repository is not healthy.
        await s.checkCI("a/x")
        #expect(s.repoErrors["a/x"] == "The Internet connection appears to be offline" && s.syncFault(stale: false) == .partial)
        // A retry that gets through clears it, without waiting for the next poll.
        offline = false
        await s.checkCI("a/x")
        #expect(s.repoErrors.isEmpty && s.syncFault(stale: false) == nil)
    }

    @Test func aCIThatAnswersDoesNotClearTheConversationsFailure() async {
        let s = Store.unsaved(signedInAs: "me")
        s.settings.reviewRequests = false
        s.repos = [RepoConfig(fullName: "a/x")]
        let answer = ciStatus(.success, sha: "s1")
        s.ciFetch = { _ in answer }
        s.gh.transport = { _ in SyncHealth.reply(500, #"{"message": "Server error"}"#) }
        await s.pollAll()
        #expect(s.repoErrors["a/x"] != nil)
        await s.checkCI("a/x")
        #expect(s.repoErrors["a/x"] != nil)
    }

    @Test func theConversationsHealthIsPublishedWithCIOffToo() async {
        let s = Store.unsaved(signedInAs: "me")
        s.settings.reviewRequests = false
        var repo = RepoConfig(fullName: "a/x")
        repo.events.remove(.ciMain)
        s.repos = [repo]
        let offline = OSAllocatedUnfairLock(initialState: true)
        s.gh.transport = { _ in
            offline.withLock { $0 } ? SyncHealth.reply(500, #"{"message": "Server error"}"#) : SyncHealth.reply(200, "[]")
        }
        await s.pollAll()
        #expect(s.repoErrors["a/x"] != nil && s.syncFault(stale: false) == .partial)
        // The next poll that gets through clears it, with no CI check to do it.
        offline.withLock { $0 = false }
        await s.pollAll()
        #expect(s.repoErrors.isEmpty && s.syncFault(stale: false) == nil)
    }

    @Test func aLaterReviewPageFailingKeepsTheRequestsAlreadyFetched() async {
        let s = Store.unsaved(signedInAs: "me")
        s.settings.didInitialReviewSync = true
        let page1 = "[" + (1...100).map { Self.issue($0) }.joined(separator: ",") + "]"
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

    @Test func aSearchThatOutlivesTheSwitchAddsNothingAndSaysNothing() async {
        let s = Store.unsaved(signedInAs: "me")
        s.settings.didInitialReviewSync = true
        s.gh.transport = { _ in
            // Review requests is turned off while the page is out.
            await MainActor.run { s.settings.reviewRequests = false }
            return SyncHealth.reply(200, #"{"total_count": 1, "incomplete_results": true, "items": [\#(Self.issue(1))]}"#)
        }
        await s.syncReviewRequests()
        #expect(s.items.isEmpty && s.pulse == 0 && !s.reviewRequestsIncomplete)
        // Nor does one that fails.
        s.settings.reviewRequests = true
        s.gh.transport = { _ in
            await MainActor.run { s.settings.reviewRequests = false }
            return SyncHealth.reply(500, #"{"message": "Timed out"}"#)
        }
        await s.syncReviewRequests()
        #expect(s.reviewRequestsError == nil && s.items.isEmpty)
    }

    @Test func aFirstSearchThatIsCutShortStillArmsTheNotificationsForWhatComesLater() async {
        let s = Store.unsaved(signedInAs: "me")
        // GitHub cuts the first search short: the baseline is what it listed.
        s.gh.transport = { _ in SyncHealth.reply(200, #"{"total_count": 5, "incomplete_results": true, "items": [\#(Self.issue(1))]}"#) }
        await s.syncReviewRequests()
        #expect(s.settings.didInitialReviewSync && s.reviewRequestsIncomplete && s.pulse == 0)
        // Backlog that turns up late (last touched before the baseline) is quiet; a request made since is news.
        let fresh = Self.issue(3, updated: "2999-01-01T00:00:00Z")
        s.gh.transport = { _ in SyncHealth.reply(200, #"{"total_count": 5, "incomplete_results": true, "items": [\#(Self.issue(1)), \#(Self.issue(2)), \#(fresh)]}"#) }
        await s.syncReviewRequests()
        #expect(s.items.filter { $0.kind == .reviewRequested }.count == 3 && s.pulse == 1)
        #expect(s.items.first { $0.id == "rr#2" }?.createdAt == s.items.first { $0.id == "rr#1" }?.createdAt)
        // A complete search has listed everything: the baseline is no longer needed.
        s.gh.transport = { _ in SyncHealth.reply(200, #"{"total_count": 3, "incomplete_results": false, "items": [\#(Self.issue(1)), \#(Self.issue(2)), \#(fresh)]}"#) }
        await s.syncReviewRequests()
        #expect(s.settings.reviewBaselineAt == nil && !s.reviewRequestsIncomplete)
    }

    @Test func anIncompleteReviewSearchIsOneFaultOnEverySurface() {
        let s = Store.unsaved(signedInAs: "me")
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
        let s = Store.unsaved(signedInAs: "me")
        s.repos = [RepoConfig(fullName: "a/b")]
        let now = Date()
        s.lastSync = now
        s.ci = ["a/b": ciStatus(.success, sha: "s1", checkedAt: now.addingTimeInterval(-3 * 3600))]
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
