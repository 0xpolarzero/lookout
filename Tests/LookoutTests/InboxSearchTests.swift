import AppKit
import Carbon
import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct InboxSearch {
    private func item(_ id: String, title: String) -> InboxItem {
        InboxItem(id: id, repo: "a/b", kind: .issueComment, number: 1, title: title, snippet: "", author: "x", avatar: nil,
                  authorIsApp: false, url: URL(string: "https://github.com/a/b")!, createdAt: Date(), state: .unread)
    }

    /// A store with two items, a hub that is open on the search, and the keys, with opening reported not done.
    private func rig() -> (store: Store, hub: HubState, keys: HubKeys, opened: Opened) {
        let store = Store()
        store.persists = false
        store.items = [item("1", title: "Format ranges"), item("2", title: "Crash on wake")]
        let opened = Opened()
        store.interceptOpen = { opened.titles.append($0) }
        let hub = HubState()
        hub.pinned = true
        hub.inbox.searchFocused = true
        return (store, hub, HubKeys(store: store, ui: UIState(), hub: hub), opened)
    }

    final class Opened { var titles: [String] = [] }

    private func key(_ code: Int, in window: NSWindow? = nil) -> NSEvent { Self.keyEvent(code, in: window) }

    /// A key press with no modifiers; its characters are the ones the key types.
    static func keyEvent(_ code: Int, in window: NSWindow? = nil) -> NSEvent {
        let typed = code == kVK_Space ? " " : code == kVK_Delete ? "\u{7f}" : "\r"
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                windowNumber: window?.windowNumber ?? 0, context: nil, characters: typed,
                                charactersIgnoringModifiers: typed, isARepeat: false, keyCode: UInt16(code))!
    }

    // MARK: Results and the pick

    @Test func returnOpensTheVisibleResult() {
        let r = rig()
        r.hub.query = "format"
        r.hub.selection = "i:1"
        #expect(r.keys.key(key(kVK_Return)))
        #expect(r.opened.titles == ["Open on GitHub · Format ranges"])
    }

    @Test func returnDoesNotOpenARowTheTypingHasFilteredOut() {
        let r = rig()
        r.hub.query = "format"
        r.hub.selection = "i:1"
        // The field's own edits don't go through the keys: the pick is still the row that has since gone.
        r.hub.query = "no match"
        #expect(!r.keys.key(key(kVK_Return)))
        #expect(r.opened.titles.isEmpty)
        #expect(r.store.items[0].state == .unread)
    }

    @Test func theResultsChangingMovesThePickToWhatIsShown() {
        let r = rig()
        let ui = UIState()
        r.hub.query = "crash"
        r.hub.selection = "i:1"
        r.hub.reconcileSelection(among: r.store.hubTargets(r.hub), ui: ui)
        #expect(r.hub.selection == "i:2")
        // Still shown: it stays, whatever came first.
        r.hub.query = "a"
        r.hub.reconcileSelection(among: r.store.hubTargets(r.hub), ui: ui)
        #expect(r.hub.selection == "i:2")
        r.hub.query = "no match"
        r.hub.reconcileSelection(among: r.store.hubTargets(r.hub), ui: ui)
        #expect(r.hub.selection == nil)
    }

    // MARK: The configured Open shortcut

    /// A window whose field editor has the keyboard, as it does while the search field is focused.
    private func editing() -> (window: NSWindow, text: NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        let text = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(text)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        window.makeFirstResponder(text)
        return (window, text)
    }

    private func press(_ code: Int, _ typed: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: UInt16(code))!
    }

    @Test func aReboundOpenShortcutOpensTheResultFromTheField() {
        let r = rig()
        let (window, _) = editing()
        defer { window.orderOut(nil) }
        r.hub.query = "format"
        r.hub.selection = "i:1"
        r.store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_O), modifiers: .command), for: .openItem)
        #expect(r.keys.key(press(kVK_ANSI_O, "o", .command, in: window)))
        #expect(r.opened.titles == ["Open on GitHub · Format ranges"])
        // Return still opens it, and another combination is the field's.
        #expect(r.keys.key(press(kVK_Return, "\r", [], in: window)))
        #expect(r.opened.titles.count == 2)
        #expect(!r.keys.key(press(kVK_ANSI_P, "p", .command, in: window)))
        #expect(r.opened.titles.count == 2)
    }

    @Test func anOpenShortcutThatIsALetterStaysTheFieldsToType() {
        let r = rig()
        let (window, _) = editing()
        defer { window.orderOut(nil) }
        r.hub.query = "format"
        r.hub.selection = "i:1"
        r.store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_O)), for: .openItem)
        #expect(!r.keys.key(press(kVK_ANSI_O, "o", [], in: window)))
        #expect(r.opened.titles.isEmpty)
    }

    @Test func aReboundOpenShortcutDoesNotOpenARowTheTypingFilteredOut() {
        let r = rig()
        let (window, _) = editing()
        defer { window.orderOut(nil) }
        r.hub.query = "no match"
        r.hub.selection = "i:1"
        r.store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_O), modifiers: .command), for: .openItem)
        #expect(!r.keys.key(press(kVK_ANSI_O, "o", .command, in: window)))
        #expect(r.opened.titles.isEmpty)
    }

    @Test func anOpenTooltipTakesEscapeBeforeTheQuery() {
        let r = rig()
        r.hub.query = "swift"
        r.hub.selection = "i:1"
        let id = UUID()
        var closed = 0
        EscapeRoute.register(id) { closed += 1; EscapeRoute.unregister(id) }
        defer { EscapeRoute.unregister(id) }
        #expect(r.keys.key(key(kVK_Escape)))
        #expect(closed == 1 && r.hub.query == "swift")
        // With nothing open, Esc clears the search as before.
        #expect(r.keys.key(key(kVK_Escape)))
        #expect(r.hub.query.isEmpty)
    }

    // MARK: Focused controls

    @Test func aFocusedControlKeepsSpaceAndReturn() {
        let r = rig()
        // Tab went from the field to Clear: the field no longer has focus.
        r.hub.inbox.searchFocused = false
        r.hub.query = "swift"
        r.hub.selection = "i:1"
        let id = UUID()
        r.hub.controls.set(id, focused: true)
        defer { r.hub.controls.set(id, focused: false) }
        #expect(!r.keys.key(key(kVK_Space)))
        #expect(!r.keys.key(key(kVK_Return)))
        #expect(r.hub.query == "swift")
        #expect(r.opened.titles.isEmpty)
        #expect(r.store.items[0].state == .unread)
        // Other keys are still the hub's: typing goes on searching.
        let typed = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: UInt16(kVK_ANSI_X))!
        #expect(r.keys.key(typed))
        #expect(r.hub.query == "swiftx")
        // Focus gone: Space is the search's again, Return opens the pick.
        r.hub.controls.set(id, focused: false)
        #expect(r.keys.key(key(kVK_Space)))
        #expect(r.hub.query == "swiftx ")
    }

    @Test func spaceTogglesReadOnAPickedRowWhenNoControlHasFocus() {
        let r = rig()
        r.hub.inbox.searchFocused = false
        r.hub.selection = "i:1"
        #expect(r.keys.key(key(kVK_Space)))
        #expect(r.store.items[0].state == .read)
    }

    // MARK: Composing

    @Test func anInputMethodComposingKeepsItsKeys() {
        let r = rig()
        r.hub.query = "format"
        r.hub.selection = "i:1"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        let text = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(text)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        window.makeFirstResponder(text)
        text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text.hasMarkedText())
        for code in [kVK_Return, kVK_Escape, kVK_DownArrow, kVK_UpArrow] {
            #expect(!r.keys.key(key(code, in: window)))
        }
        #expect(r.opened.titles.isEmpty)
        #expect(r.hub.selection == "i:1")
        #expect(r.hub.query == "format")
        // Committed: the keys are Lookout's again.
        text.unmarkText()
        #expect(r.keys.key(key(kVK_Return, in: window)))
        #expect(r.opened.titles.count == 1)
        window.orderOut(nil)
    }

    @Test func onlyTypingMovesTheCaretAfterItsFirstCharacter() {
        let r = rig()
        r.hub.inbox.searchFocused = false
        let typed = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: UInt16(kVK_ANSI_X))!
        #expect(r.keys.key(typed))
        #expect(r.hub.inbox.caretAtEnd)
        // The field took it (or the search ended): a later focus, from a click in the query, is its own.
        r.hub.inbox.caretAtEnd = false
        r.hub.beginSearch()
        #expect(!r.hub.inbox.caretAtEnd)
        r.hub.inbox.startSearch(seeded: true)
        r.hub.inbox.endSearch()
        #expect(!r.hub.inbox.caretAtEnd)
    }

    // MARK: Result groups

    @Test func theSummaryCountsBothGroupsEvenAtNone() {
        let r = rig()
        let view = LookoutHub(store: r.store, ui: UIState(), hub: r.hub)
        r.hub.query = "format"
        // Sessions off: only the inbox is searched.
        #expect(view.searchCount == "1 item")
        #expect(!view.searchGroups)
        r.store.agents.enabled = true
        #expect(view.searchCount == "1 item · 0 sessions")
        #expect(view.searchGroups)
        // The inbox found something, the sessions nothing: the Sessions header says so on its own line, and the inbox has the
        // whole body.
        #expect(view.agentsStatus?.text == "0 · No sessions match")
        #expect(view.searchSpansBody && view.showsSessions)
        r.hub.query = "no match at all"
        #expect(view.searchCount == "No match")
        // Both empty: one "No match" and no Sessions section under it, not a line in each group.
        #expect(view.searchFoundNothing && !view.searchSpansBody && !view.showsSessions)
        #expect(view.agentsStatus == nil)
    }

    // MARK: Starting

    @Test func searchingFromAFocusedSectionOrAPeekShowsTheCombinedResults() {
        let hub = HubState()
        hub.focus = .ci
        hub.section = .inbox
        #expect(!hub.pinned)
        hub.beginSearch()
        #expect(hub.pinned)
        #expect(hub.focus == nil)
        #expect(hub.inbox.searchOpen)
    }
}

@MainActor
@Suite struct InboxSignedOut {
    @Test func aSignInProblemReplacesTheListEvenWithRowsRetained() {
        let s = Store()
        s.persists = false
        s.repos = [RepoConfig(fullName: "a/b")]
        s.lastSync = Date()
        s.items = [InboxItem(id: "1", repo: "a/b", kind: .issueComment, number: 1, title: "Cached", snippet: "", author: "x",
                             avatar: nil, authorIsApp: false, url: URL(string: "https://github.com/a/b")!, createdAt: Date(),
                             state: .unread)]
        #expect(s.inboxReplacement == nil)
        s.authError = "Bad credentials"
        #expect(s.list(.needsYou).count == 1)
        #expect(s.inboxReplacement == .signedOut)
        #expect(s.inboxEmpty(.needsYou) == .signedOut)
        s.authError = nil
        #expect(s.inboxReplacement == nil)
    }

    @Test func rowsThatAreNotDrawnAreNeitherTargetsNorResults() {
        let s = Store()
        s.persists = false
        // No CI: its rows are targets too, and this is about the inbox's.
        var repo = RepoConfig(fullName: "a/b")
        repo.events.remove(.ciMain)
        s.repos = [repo]
        s.lastSync = Date()
        s.items = [InboxItem(id: "1", repo: "a/b", kind: .issueComment, number: 1, title: "Cached", snippet: "", author: "x",
                             avatar: nil, authorIsApp: false, url: URL(string: "https://github.com/a/b")!, createdAt: Date(),
                             state: .unread)]
        let hub = HubState()
        hub.pinned = true
        #expect(s.hubTargets(hub) == ["i:1"])
        s.authError = "Bad credentials"
        #expect(s.hubTargets(hub).isEmpty)
        hub.query = "cached"
        #expect(s.hubItems(hub).isEmpty)
        // Down, then Return: nothing to open or to mark read.
        var opened: [String] = []
        s.interceptOpen = { opened.append($0) }
        hub.selection = "i:1"
        let keys = HubKeys(store: s, ui: UIState(), hub: hub)
        #expect(!keys.key(InboxSearch.keyEvent(kVK_Return)))
        #expect(opened.isEmpty)
        #expect(s.items[0].state == .unread)
        // Signed in again: the same rows are back.
        s.authError = nil
        #expect(s.hubItems(hub).count == 1)
    }
}
