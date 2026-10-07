import Foundation
import Testing
@testable import Lookout

/// Answers that arrive after what they were asked for has changed.
@MainActor
@Suite struct SyncRace {
    private func store(_ repo: RepoConfig) -> Store {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.settings.reviewRequests = false
        s.repos = [repo]
        return s
    }

    @Test func anAnswerThatArrivesAfterTheRepoWasStoppedLeavesNothingInTheInbox() async {
        var repo = RepoConfig(fullName: "a/one")
        repo.events = [.issueOpened]
        let s = store(repo)
        let fresh = ISO8601DateFormatter().string(from: Date())
        let issue = """
            [{"id": 7, "number": 7, "title": "Late", "body": null, "user": {"login": "x", "avatar_url": null, "type": "User"},
              "html_url": "https://github.com/a/one/issues/7", "created_at": "\(fresh)", "updated_at": "\(fresh)", "pull_request": null}]
            """
        // Stop watching while the issues request is out; it then answers with a new issue.
        let gate = StubbedGitHub.Gate()
        s.gh.session = StubbedGitHub.session { request in
            if request.url?.path.hasSuffix("/issues") == true { return .init(200, issue, gate: gate) }
            if request.url?.path.hasSuffix("/comments") == true { return .init(200, "[]") }
            return .init(500, #"{"message": "Not here"}"#)
        }
        let poll = Task { await s.pollAll() }
        while gate.held == 0 { await Task.yield() }
        s.removeRepo(repo)
        gate.open()
        await poll.value
        #expect(s.repos.isEmpty && s.items.isEmpty)
    }

    @Test func anAnswerForARepoWatchedAgainIsAskedForAnew() async {
        var repo = RepoConfig(fullName: "a/one")
        repo.events = [.issueOpened]
        let s = store(repo)
        let fresh = ISO8601DateFormatter().string(from: Date())
        let issue = """
            [{"id": 7, "number": 7, "title": "Late", "body": null, "user": {"login": "x", "avatar_url": null, "type": "User"},
              "html_url": "https://github.com/a/one/issues/7", "created_at": "\(fresh)", "updated_at": "\(fresh)", "pull_request": null}]
            """
        // Only the issue's own request answers, and the repo is watched anew (a new `addedAt`) while it is out.
        let gate = StubbedGitHub.Gate()
        s.gh.session = StubbedGitHub.session { request in
            if request.url?.path.hasSuffix("/issues") == true { return .init(200, issue, gate: gate) }
            if request.url?.path.hasSuffix("/comments") == true { return .init(200, "[]") }
            return .init(500, #"{"message": "Not here"}"#)
        }
        let poll = Task { await s.pollAll() }
        while gate.held == 0 { await Task.yield() }
        s.removeRepo(repo)
        var again = repo
        again.addedAt = Date().addingTimeInterval(1)
        s.repos = [again]
        gate.open()
        await poll.value
        #expect(s.items.isEmpty)
    }

    @Test func stoppingAFailedRepoClearsItsFault() {
        let s = store(RepoConfig(fullName: "a/one"))
        s.repos.append(RepoConfig(fullName: "a/two"))
        s.repoErrors = ["a/one": "Forbidden"]
        s.removeRepo(s.repos[0])
        #expect(s.repoErrors.isEmpty)
    }

    @Test func aRequestThatOutlivesItsRepoPublishesNoFault() async {
        let repo = RepoConfig(fullName: "a/one")
        let s = store(repo)
        // The repo is stopped while its first request is in flight, and that request then fails.
        let gate = StubbedGitHub.Gate()
        s.gh.session = StubbedGitHub.session { _ in .init(500, #"{"message": "Server error"}"#, gate: gate) }
        let poll = Task { await s.pollAll() }
        while gate.held == 0 { await Task.yield() }
        s.removeRepo(repo)
        gate.open()
        await poll.value
        #expect(s.repoErrors.isEmpty)
    }

    /// Stops watching `repo` and watches it anew (a new `addedAt`), as one does while a request for it is out.
    private func watchAgain(_ s: Store, _ repo: RepoConfig) {
        s.removeRepo(repo)
        var again = repo
        again.addedAt = repo.addedAt.addingTimeInterval(1)
        s.repos = [again]
    }

    @Test func aLateFailureOfAStoppedAndWatchedAgainRepoIsNotItsFault() async {
        var repo = RepoConfig(fullName: "a/one")
        // Conversations only: a CI check the new watching starts is its own, and may fault on its own.
        repo.events = [.issueOpened]
        let s = store(repo)
        let gate = StubbedGitHub.Gate()
        s.gh.session = StubbedGitHub.session { _ in .init(500, #"{"message": "Server error"}"#, gate: gate) }
        let poll = Task { await s.pollAll() }
        while gate.held == 0 { await Task.yield() }
        watchAgain(s, repo)
        gate.open()
        await poll.value
        #expect(s.repoErrors.isEmpty)
    }

    @Test func aLateAnswerOfAStoppedAndWatchedAgainRepoDoesNotClearItsFault() async {
        var repo = RepoConfig(fullName: "a/one")
        // Conversations only: a CI check the new watching starts is its own, and may fault on its own.
        repo.events = [.issueOpened]
        let s = store(repo)
        let gate = StubbedGitHub.Gate()
        s.gh.session = StubbedGitHub.session { _ in .init(200, "[]", gate: gate) }
        let poll = Task { await s.pollAll() }
        while gate.held == 0 { await Task.yield() }
        watchAgain(s, repo)
        s.repoErrors["a/one"] = "Forbidden"
        gate.open()
        await poll.value
        #expect(s.repoErrors["a/one"] == "Forbidden")
    }
}
