import Carbon
import Foundation
import SwiftUI
import Testing
@testable import Lookout

@MainActor
@Suite struct InboxCauses {
    private func healthy() -> Store {
        let s = Store()
        s.persists = false
        s.repos = [RepoConfig(fullName: "a/b")]
        s.lastSync = Date()
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        return s
    }

    @Test func aSignInProblemComesFirst() {
        let s = healthy()
        s.authError = "No token"
        s.repos = []
        #expect(s.inboxEmpty(.needsYou) == .signedOut)
        #expect(s.inboxEmpty(.done) == .signedOut)
        #expect(s.inboxNotice() == nil)
    }

    @Test func nothingWatchedThenFirstSync() {
        let s = healthy()
        s.repos = []
        #expect(s.inboxEmpty(.bots) == .noRepos)
        s.repos = [RepoConfig(fullName: "a/b")]
        s.lastSync = nil
        #expect(s.inboxEmpty(.needsYou) == .firstSync)
    }

    @Test func allCaughtUpOnlyWhenSyncingIsHealthy() {
        let s = healthy()
        #expect(s.inboxEmpty(.needsYou) == .caughtUp)
        s.repoErrors = ["a/b": "Not found"]
        #expect(s.inboxEmpty(.needsYou) == .nothingNew)
        s.repoErrors = [:]
        s.rateRemaining = 0
        #expect(s.inboxEmpty(.needsYou) == .nothingNew)
        s.rateRemaining = 100
        s.lastSync = Date().addingTimeInterval(-s.settings.pollInterval * 4)
        #expect(s.inboxEmpty(.needsYou) == .nothingNew)
    }

    @Test func aFailedReviewRequestSearchIsNotAllCaughtUp() {
        let s = healthy()
        #expect(s.inboxEmpty(.needsYou) == .caughtUp)
        // The repositories synced; the other source didn't (its own rate limit, say).
        s.reviewRequestsError = "API rate limit exceeded"
        #expect(s.inboxEmpty(.needsYou) == .nothingNew)
        #expect(s.inboxNotice() == .reviewRequestsFailed)
        #expect(InboxNotice.reviewRequestsFailed.message == "Review requests didn't sync")
        // Bots and Done make no such claim.
        #expect(s.inboxEmpty(.bots) == .botsQuiet)
        // Not a source that is switched off, and it is forgotten once the search works again.
        s.settings.reviewRequests = false
        #expect(s.inboxEmpty(.needsYou) == .caughtUp)
        #expect(s.inboxNotice() == nil)
        s.settings.reviewRequests = true
        s.reviewRequestsError = nil
        #expect(s.inboxEmpty(.needsYou) == .caughtUp)
    }

    @Test func botsAndDoneSayWhatTheyAre() {
        let s = healthy()
        #expect(s.inboxEmpty(.bots) == .botsQuiet)
        #expect(s.inboxEmpty(.done) == .doneEmpty)
    }

    @Test func oneBannerAtATimeMostPressingFirst() {
        let s = healthy()
        #expect(s.inboxNotice() == nil)
        s.settings.snoozeUntil = Date().addingTimeInterval(600)
        #expect(s.inboxNotice() == .snoozed(until: s.settings.snoozeUntil!))
        s.rateRemaining = 0
        #expect(s.inboxNotice() == .rateLimited(until: nil))
        let reset = Date().addingTimeInterval(900)
        s.rateResetsAt = reset
        #expect(s.inboxNotice() == .rateLimited(until: reset))
        s.reviewRequestsError = "API rate limit exceeded"
        s.rateRemaining = 100
        #expect(s.inboxNotice() == .reviewRequestsFailed)
        s.rateRemaining = 0
        s.repoErrors = ["a/b": "Forbidden", "c/d": "Not found"]
        #expect(s.inboxNotice() == .reposFailed(2))
        #expect(InboxNotice.reposFailed(2).message == "2 repositories didn't sync")
        #expect(InboxNotice.reposFailed(1).message == "1 repository didn't sync")
    }

    @Test func aResetInThePastIsNotShown() {
        let s = healthy()
        s.rateRemaining = 0
        s.rateResetsAt = Date().addingTimeInterval(-5)
        #expect(s.inboxNotice() == .rateLimited(until: nil))
    }
}

@Suite struct MenuShortcuts {
    @Test func namedKeysAndLettersMapToMenuEquivalents() {
        #expect(Shortcut(keyCode: UInt16(kVK_Delete)).menuShortcut == KeyboardShortcut(.delete, modifiers: []))
        #expect(Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.option]).menuShortcut == KeyboardShortcut(.space, modifiers: .option))
        #expect(Shortcut(keyCode: UInt16(kVK_Return)).menuShortcut == KeyboardShortcut(.return, modifiers: []))
    }

    @Test func modifierTapsAndMouseButtonsHaveNone() {
        #expect(Shortcut(keyCode: 54).menuShortcut == nil)
        #expect(Shortcut.mouse(3).menuShortcut == nil)
    }
}
