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
}
