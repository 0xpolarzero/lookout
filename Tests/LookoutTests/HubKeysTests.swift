import AppKit
import Carbon
import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct HubKeysRouting {
    private let store = Store()
    private let hub = HubState()
    private let keys: HubKeys

    init() {
        store.persists = false
        store.repoUndo.announce = { _ in }
        keys = HubKeys(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
        store.items = [InboxItem(id: "one", repo: "a/one", kind: .issueComment, number: 1, title: "t", snippet: "", author: "x", avatar: nil,
                                 authorIsApp: false, url: URL(string: "https://github.com/a/one")!, createdAt: Date(), state: .read)]
        hub.pinned = true
        hub.selection = "i:one"
    }

    private func commandZ() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false,
                         keyCode: UInt16(kVK_ANSI_Z))!
    }

    @Test func commandZUndoesWhenNothingIsBoundToIt() {
        var reverted = false
        store.repoUndo.push("Stopped watching a/one") { reverted = true }
        #expect(keys.key(commandZ()))
        #expect(reverted)
        // Nothing left to undo: the key is not taken.
        #expect(!keys.key(commandZ()))
    }

    @Test func aBindingOnCommandZRunsInsteadOfUndo() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command]), for: .toggleRead)
        var reverted = false
        store.repoUndo.push("Stopped watching a/one") { reverted = true }
        #expect(keys.key(commandZ()))
        #expect(store.items[0].state == .unread)
        #expect(!reverted)
        #expect(store.repoUndo.entries.count == 1)
    }

    @Test func aBindingOnCommandZWithNothingSelectedFallsBackToUndo() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command]), for: .toggleRead)
        hub.selection = nil
        var reverted = false
        store.repoUndo.push("Stopped watching a/one") { reverted = true }
        #expect(keys.key(commandZ()))
        #expect(reverted)
        #expect(!keys.key(commandZ()))
    }
}
