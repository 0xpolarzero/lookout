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
        s.keychainWrite = { _, _ in true }
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

    @Test func aTokenSuppliedWhileOfflineReplacesTheSignInProblemWithTheSyncOne() async {
        let s = store(token: nil)
        await s.pollAll()
        #expect(s.authError != nil && !s.unreachable)
        // The replacement can't be tried, which says nothing of the old problem.
        s.resolveToken = { ("new", .keychain) }
        answer(s) { _ in throw URLError(.notConnectedToInternet) }
        s.setToken("new")
        await waitUntil { s.unreachable && !s.isSyncing }
        #expect(s.authError == nil && s.unreachable && s.gh.token == "new")
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
        await waitUntil { s.me?.login == "b" && !s.isSyncing }
        #expect(s.me?.login == "b" && s.gh.token == "B" && s.authError == nil)
    }

    @Test func aResetLearnedByARefreshByHandBringsTheNextCheckForwardToIt() async {
        let s = store()
        s.me = GHUser(login: "me", avatarUrl: nil, type: nil)
        s.repos = [RepoConfig(fullName: "a/one")]
        // Before the refresh by hand there's budget to spare. During it every request finds it spent, the reset a few
        // seconds after that request (as GitHub's always is when nothing is left: never one already passed, whatever the
        // machine's speed). After it, a request is the loop's own, and counts once the reset has passed.
        struct Phase { var manual = false; var manualAsked = 0; var reset: Date?; var woken = 0 }
        let phase = OSAllocatedUnfairLock(initialState: Phase())
        answer(s) { _ in
            let (spent, reset) = phase.withLock { p -> (Bool, Date?) in
                if p.manual {
                    p.manualAsked += 1
                    p.reset = Date(timeIntervalSince1970: Date().addingTimeInterval(5).timeIntervalSince1970.rounded(.up))
                    return (true, p.reset)
                }
                guard let reset = p.reset else { return (false, nil) }
                if Date() >= reset { p.woken += 1 }
                return (Date() < reset, reset)
            }
            var headers = ["x-ratelimit-resource": "core", "x-ratelimit-remaining": spent ? "0" : "4000"]
            if let reset { headers["x-ratelimit-reset"] = String(Int(reset.timeIntervalSince1970)) }
            return .init(200, "[]", headers: headers)
        }
        // Checking every minute: the loop is asleep for most of one when the refresh by hand finds the budget spent.
        s.restartPolling()
        defer { s.stopPolling() }
        await waitUntil { s.lastSync != nil && !s.isSyncing }
        phase.withLock { $0.manual = true }
        s.refreshNow()
        // The refresh by hand has asked (and found the budget spent) and is over.
        await waitUntil { phase.withLock { $0.manualAsked } > 0 && !s.isSyncing }
        #expect(phase.withLock { $0.manualAsked } > 0)
        phase.withLock { $0.manual = false }
        // The loop's own next check would be a minute after that sync; the reset brings it forward (to the reset, or at once
        // if the refresh was so slow the reset passed meanwhile). The watchdog ends ten seconds short of the minute, which is
        // what tells the two apart.
        await waitUntil(within: 50) { phase.withLock { $0.woken } > 0 }
        #expect(phase.withLock { $0.woken } > 0)
    }

    @Test func aResetThatPassedDuringASlowRefreshIsCheckedOnceNotOverAndOver() async {
        let s = store()
        s.me = GHUser(login: "me", avatarUrl: nil, type: nil)
        s.repos = [RepoConfig(fullName: "a/one")]
        // Checking every hour: whatever the observation below takes on a slow runner, no scheduled check falls inside it, so
        // any check it sees is an immediate one.
        s.settings.pollInterval = 3600
        // The refresh by hand finds the budget spent, its answer held until that reset has passed; then GitHub can't be
        // reached (no rate headers: the spent budget and its reset are what the client keeps).
        struct Phase { var manual = false; var reset: Date?; var offline = false; var after = 0 }
        let phase = OSAllocatedUnfairLock(initialState: Phase())
        let gate = StubbedGitHub.Gate()
        // `after` counts the polls begun once the held answer is let go: each poll begins with the repo's issues (the rest of
        // the held poll's own requests come after its issues, and aren't counted).
        answer(s) { req in
            let now = phase.withLock { p -> (spent: Bool, reset: Date?, offline: Bool) in
                if p.offline {
                    if req.url?.path == "/repos/a/one/issues" { p.after += 1 }
                    return (false, nil, true)
                }
                guard p.manual else { return (false, nil, false) }
                p.reset = Date(timeIntervalSince1970: Date().addingTimeInterval(1).timeIntervalSince1970.rounded(.up))
                return (true, p.reset, false)
            }
            if now.offline { throw URLError(.notConnectedToInternet) }
            guard now.spent, let reset = now.reset else { return .init(200, "[]") }
            return .init(200, "[]", headers: ["x-ratelimit-resource": "core", "x-ratelimit-remaining": "0",
                                              "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970))], gate: gate)
        }
        s.restartPolling()
        defer { s.stopPolling() }
        await waitUntil { s.lastSync != nil && !s.isSyncing }
        phase.withLock { $0.manual = true }
        s.refreshNow()
        await waitUntil { gate.held > 0 }
        // The reset passes while the answer is held.
        await waitUntil { phase.withLock { $0.reset }.map { Date() > $0 } ?? false }
        phase.withLock { $0.manual = false; $0.offline = true }
        gate.open()
        // One check at once for that reset: it fails offline.
        await waitUntil { phase.withLock { $0.after } > 0 && !s.isSyncing }
        #expect(phase.withLock { $0.after } == 1)
        // Then the loop goes back to its interval: no check after check (any would come within a few turns).
        for _ in 0..<100 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(phase.withLock { $0.after } == 1)
    }
}
