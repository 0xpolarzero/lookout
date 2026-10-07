import Foundation
import os
import Testing
@testable import Lookout

/// What the store says of GitHub being unreachable or refusing the token, and what it does about finding a token meanwhile.
@MainActor
@Suite struct SyncHealth {
    nonisolated private static let user = StubbedGitHub.Reply(200, #"{"login": "me", "avatar_url": null, "type": "User"}"#)

    private func store(asks: OSAllocatedUnfairLock<Int>? = nil, token: String? = "token") -> Store {
        let s = Store()
        s.persists = false
        s.settings.reviewRequests = false
        s.resolveToken = {
            asks?.withLock { $0 += 1 }
            return token.map { ($0, .environment) }
        }
        // Never the real Keychain.
        s.keepToken = { _ in }
        return s
    }

    private func answer(_ s: Store, _ handler: @escaping StubbedGitHub.Handler) {
        s.gh.session = StubbedGitHub.session(handler)
    }

    @Test func pollsThatCantReachGitHubKeepTheTokenTheyHaveInsteadOfFindingOneEachTime() async {
        let asks = OSAllocatedUnfairLock(initialState: 0)
        let s = store(asks: asks)
        // Offline: finding a token reads the Keychain and may run gh, which every poll would do at rest.
        answer(s) { _ in throw URLError(.notConnectedToInternet) }
        for _ in 0..<3 { await s.pollAll() }
        #expect(asks.withLock { $0 } == 1 && s.me == nil && s.gh.token == "token")
        // GitHub refuses it: another is looked for, at the next poll.
        answer(s) { _ in .init(401, #"{"message": "Bad credentials"}"#) }
        await s.pollAll()
        #expect(asks.withLock { $0 } == 1 && s.gh.tokenRejected)
        answer(s) { _ in Self.user }
        await s.pollAll()
        #expect(asks.withLock { $0 } == 2 && s.me?.login == "me")
        // A token saved in Settings is looked for too.
        s.setToken("new")
        while s.me == nil || s.isSyncing { await Task.yield() }
        #expect(asks.withLock { $0 } == 3 && s.me != nil)
    }

    @Test func aFirstLookThatCantReachGitHubIsASyncProblemNotASignInOne() async {
        let s = store()
        answer(s) { _ in throw URLError(.notConnectedToInternet) }
        await s.pollAll()
        #expect(s.authError == nil && s.unreachable && s.me == nil)
        // Through at the next poll: the sync is healthy again.
        answer(s) { _ in Self.user }
        await s.pollAll()
        #expect(s.me?.login == "me" && !s.unreachable)
        // A token GitHub refuses is still a sign-in problem.
        s.me = nil
        answer(s) { _ in .init(401, #"{"message": "Bad credentials"}"#) }
        await s.pollAll()
        #expect(s.authError != nil && !s.unreachable)
    }

    @Test func aTokenSavedWhileAnotherIsBeingSignedInWithWinsAndTheOldAnswerIsDropped() async {
        let s = store()
        s.gh.token = nil
        let tokens = OSAllocatedUnfairLock(initialState: ["A", "B"])
        s.resolveToken = { (tokens.withLock { $0.removeFirst() }, .keychain) }
        let gate = StubbedGitHub.Gate()
        // Token A's answer is held until the user has saved B in Settings.
        answer(s) { request in
            let isA = request.value(forHTTPHeaderField: "Authorization") == "Bearer A"
            let body = #"{"login": "\#(isA ? "a" : "b")", "avatar_url": null, "type": "User"}"#
            return .init(200, body, gate: isA ? gate : nil)
        }
        let poll = Task { await s.pollAll() }
        while gate.held == 0 { await Task.yield() }
        s.setToken("B")
        // The refresh asked for meanwhile waits for this poll, and runs once it is over.
        gate.open()
        await poll.value
        #expect(s.me == nil || s.me?.login == "b")
        for _ in 0..<500 where s.me?.login != "b" || s.isSyncing { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(s.me?.login == "b" && s.gh.token == "B" && s.authError == nil)
    }

    @Test func aResetLearnedByARefreshByHandBringsTheNextCheckForwardToIt() async {
        let s = store()
        s.me = GHUser(login: "me", avatarUrl: nil, type: nil)
        s.repos = [RepoConfig(fullName: "a/one")]
        let reset = Date(timeIntervalSince1970: Date().addingTimeInterval(2).timeIntervalSince1970.rounded(.up))
        let exhausted = OSAllocatedUnfairLock(initialState: false)
        let afterReset = OSAllocatedUnfairLock(initialState: 0)
        answer(s) { _ in
            let spent = exhausted.withLock { $0 } && Date() < reset
            if exhausted.withLock({ $0 }), !spent { afterReset.withLock { $0 += 1 } }
            return .init(200, "[]", headers: [
                "x-ratelimit-resource": "core", "x-ratelimit-remaining": spent ? "0" : "4000",
                "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970)),
            ])
        }
        // Checking every minute: the loop is asleep for most of one when the refresh by hand finds the budget spent.
        s.restartPolling()
        defer { s.stopPolling() }
        while s.lastSync == nil || s.isSyncing { try? await Task.sleep(for: .milliseconds(10)) }
        exhausted.withLock { $0 = true }
        s.refreshNow()
        for _ in 0..<600 where afterReset.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(afterReset.withLock { $0 } > 0)
    }
}
