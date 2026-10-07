import AppKit
import Carbon
import Foundation
import Testing
@testable import Lookout

/// What the user bound comes before the typing that starts a search.
@MainActor
@Suite struct HubKeysBindings {
    private let store = Store()
    private let hub = HubState()
    private let keys: HubKeys

    init() {
        store.persists = false
        keys = HubKeys(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
        store.items = [InboxItem(id: "one", repo: "a/one", kind: .issueComment, number: 1, title: "t", snippet: "", author: "x", avatar: nil,
                                 authorIsApp: false, url: URL(string: "https://github.com/a/one")!, createdAt: Date(), state: .unread)]
        hub.pinned = true
        hub.selection = "i:one"
    }

    @discardableResult
    private func press(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: UInt16(code))!
        return keys.key(event)
    }

    @Test func aLetterBoundToAnActionActsOnThePickedRowInsteadOfSearching() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_T)), for: .toggleRead)
        #expect(press(kVK_ANSI_T, [], "t"))
        #expect(store.items[0].state == .read && hub.query.isEmpty)
        // With Shift: a Shift-letter binding is the same.
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_Y), modifiers: [.shift]), for: .toggleRead)
        #expect(press(kVK_ANSI_Y, [.shift], "Y"))
        #expect(store.items[0].state == .unread && hub.query.isEmpty)
    }

    @Test func anUnboundLetterOrOneWithNothingPickedStillSearches() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_T)), for: .toggleRead)
        // The field types the key (it is handed over, not read here): the search is open and holds it.
        #expect(press(kVK_ANSI_Z, [], "z") && hub.searchOpen && hub.pendingKeys.count == 1)
        // A search that has typed something takes every letter, the bound one too.
        hub.query = "z"
        #expect(press(kVK_ANSI_T, [], "t") && hub.pendingKeys.count == 2 && store.items[0].state == .unread)
        hub.endSearch()
        hub.selection = nil
        #expect(press(kVK_ANSI_T, [], "t") && hub.searchOpen && hub.pendingKeys.count == 1)
    }

    @Test func spaceStillTypesInASearchThatHasStarted() {
        // Space is the default Mark read key: it acts on the picked row until a search has started, then it is a space.
        #expect(press(kVK_Space, [], " ") && store.items[0].state == .read)
        hub.query = "two"
        #expect(press(kVK_Space, [], " ") && hub.pendingKeys.last?.characters == " " && store.items[0].state == .read)
    }
}
