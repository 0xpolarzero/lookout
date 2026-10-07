import Carbon
import Foundation
import SwiftUI
import Testing
@testable import Lookout

@MainActor
@Suite struct InboxCauses {
    private func healthy() -> Store {
        let s = Store.unsaved(signedInAs: "me")
        s.repos = [RepoConfig(fullName: "a/b")]
        s.lastSync = Date()
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
        s.settings.reviewRequests = false
        #expect(s.inboxEmpty(.bots) == .noRepos)
        s.repos = [RepoConfig(fullName: "a/b")]
        s.lastSync = nil
        #expect(s.inboxEmpty(.needsYou) == .firstSync)
    }

    @Test func reviewRequestsAloneAreSomethingWatched() {
        let s = healthy()
        s.repos = []
        // Review requests need no repository: the ordinary empty state, and their failures are told.
        #expect(s.settings.reviewRequests && s.inboxEmpty(.needsYou) == .caughtUp)
        s.reviewRequestsError = "API rate limit exceeded"
        #expect(s.inboxEmpty(.needsYou) == .nothingNew && s.inboxNotice() == .reviewRequestsFailed)
        s.reviewRequestsError = nil
        s.reviewRequestsIncomplete = true
        #expect(s.inboxNotice() == .reviewRequestsCut)
        s.reviewRequestsIncomplete = false
        s.lastSync = nil
        #expect(s.inboxEmpty(.needsYou) == .firstSync)
        // Switched off as well, nothing is checked for.
        s.settings.reviewRequests = false
        #expect(s.inboxEmpty(.needsYou) == .noRepos && s.inboxNotice() == nil)
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

    @Test func specialKeysMapByName() {
        #expect(Shortcut(keyCode: UInt16(kVK_LeftArrow)).menuShortcut == KeyboardShortcut(.leftArrow, modifiers: []))
        #expect(Shortcut(keyCode: UInt16(kVK_PageDown), modifiers: [.command]).menuShortcut == KeyboardShortcut(.pageDown, modifiers: .command))
        #expect(Shortcut(keyCode: UInt16(kVK_Home)).menuShortcut == KeyboardShortcut(.home, modifiers: []))
        #expect(Shortcut(keyCode: UInt16(kVK_ANSI_KeypadEnter)).menuShortcut == KeyboardShortcut(.return, modifiers: []))
        #expect(Shortcut(keyCode: UInt16(kVK_ForwardDelete)).menuShortcut == KeyboardShortcut(.deleteForward, modifiers: []))
    }

    @Test func aKeyWithNoMenuEquivalentIsNotATranslatedLetter() {
        // F1 is not "f", Page Up is not "p", a cleared binding is nothing.
        #expect(Shortcut(keyCode: UInt16(kVK_F1)).menuShortcut == nil)
        #expect(Shortcut(keyCode: UInt16(kVK_F10), modifiers: [.shift]).menuShortcut == nil)
        #expect(Shortcut.unassigned.menuShortcut == nil)
    }

    @Test func modifierTapsAndMouseButtonsHaveNone() {
        #expect(Shortcut(keyCode: 54).menuShortcut == nil)
        #expect(Shortcut.mouse(3).menuShortcut == nil)
    }
}

@Suite struct PollInterval {
    @Test func lowPowerModeDoublesTheIntervalOpenOrNot() {
        #expect(Store.pollInterval(base: 60, hubOpen: false, lowPower: false) == 60)
        #expect(Store.pollInterval(base: 60, hubOpen: true, lowPower: false) == 30)
        #expect(Store.pollInterval(base: 60, hubOpen: false, lowPower: true) == 120)
        #expect(Store.pollInterval(base: 60, hubOpen: true, lowPower: true) == 60)
        // An interval already under 30 s is not stretched by the hub opening.
        #expect(Store.pollInterval(base: 20, hubOpen: true, lowPower: false) == 20)
    }
}

/// DESIGN.md 5.4: the count of rows below and the header's hairline follow the list as it scrolls (a geometry preference
/// is not sent again when a scroll view scrolls, so they read the scroll view's own offset).
@MainActor
@Suite struct InboxPaging {
    @Test func scrollingToTheEndEmptiesTheCountBelowAndRaisesTheHairline() async throws {
        let store = Store()
        Demo.populate(store, .inboxMany)
        let hub = HubState()
        hub.pinned = true
        let view = LookoutHub(store: store, ui: UIState(persists: false, edge: .right), hub: hub, maxLength: 700, openLength: 700,
                              maxWidth: 900, barLength: 700)
            .frame(width: 900, height: 800, alignment: .topLeading)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow.offscreen(hosting, size: CGSize(width: 900, height: 800))
        defer { window.close() }
        try await eventually { hub.inbox.hiddenBelow > 0 }
        hosting.settle()
        #expect(hub.inbox.hiddenBelow > 0 && !hub.inbox.scrolled)
        let scroll = try #require(hosting.first(NSScrollView.self))
        let clip = scroll.contentView
        let document = try #require(scroll.documentView)
        let far = document.frame.height - clip.bounds.height
        clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? far : 0))
        scroll.reflectScrolledClipView(clip)
        try await eventually { hub.inbox.scrolled && hub.inbox.hiddenBelow == 0 }
        #expect(hub.inbox.scrolled && hub.inbox.hiddenBelow == 0)
    }
}

@MainActor
@Suite struct SnoozeExpiry {
    @Test func aSnoozeEndsForWhatReadsItAtItsDeadline() async throws {
        let store = Store.unsaved()
        store.settings.snoozeUntil = Date().addingTimeInterval(0.3)
        let flag = Flag()
        withObservationTracking { _ = store.isSnoozed } onChange: { flag.set() }
        #expect(store.isSnoozed)
        // The banner and the Notifications row, which read it, are told once the time has passed (a busy run may be late).
        try await eventually { flag.value }
        #expect(flag.value && !store.isSnoozed)
    }

    @Test func resumingEarlyLeavesNothingToFire() async throws {
        let store = Store.unsaved()
        store.settings.snoozeUntil = Date().addingTimeInterval(0.3)
        store.snooze(for: nil)
        let revision = store.snoozeRevision
        try await Task.sleep(for: .seconds(0.7))
        #expect(store.snoozeRevision == revision)
    }
}
