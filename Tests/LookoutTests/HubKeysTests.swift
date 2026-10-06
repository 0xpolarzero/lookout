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
        store.undoStack.announce = { _ in }
        keys = HubKeys(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
        store.items = [InboxItem(id: "one", repo: "a/one", kind: .issueComment, number: 1, title: "t", snippet: "", author: "x", avatar: nil,
                                 authorIsApp: false, url: URL(string: "https://github.com/a/one")!, createdAt: Date(), state: .read)]
        hub.pinned = true
        hub.selection = "i:one"
    }

    private func commandZ() -> NSEvent { keyDown(kVK_ANSI_Z, .command, "z") }

    @Test func commandZUndoesWhenNothingIsBoundToIt() {
        var reverted = false
        store.registerUndo("Stopped watching a/one", in: .controls) { reverted = true }
        #expect(keys.key(commandZ()))
        #expect(reverted)
        // Nothing left to undo: the key is not taken.
        #expect(!keys.key(commandZ()))
    }

    @Test func aBindingOnCommandZRunsInsteadOfUndo() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command]), for: .toggleRead)
        var reverted = false
        store.registerUndo("Stopped watching a/one", in: .controls) { reverted = true }
        #expect(keys.key(commandZ()))
        #expect(store.items[0].state == .unread)
        #expect(!reverted)
        #expect(store.undoStack.entries.count == 1)
    }

    @Test func aBindingOnCommandZWithNothingSelectedFallsBackToUndo() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command]), for: .toggleRead)
        hub.selection = nil
        var reverted = false
        store.registerUndo("Stopped watching a/one", in: .controls) { reverted = true }
        #expect(keys.key(commandZ()))
        #expect(reverted)
        #expect(!keys.key(commandZ()))
    }

    @Test func anArrowBoundToAnActionActsInsteadOfSwitchingTabs() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_RightArrow)), for: .toggleRead)
        #expect(keys.key(keyDown(kVK_RightArrow)))
        #expect(store.items[0].state == .unread)
        #expect(hub.filter == .needsYou)
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_LeftArrow)), for: .discard)
        #expect(keys.key(keyDown(kVK_LeftArrow)))
        #expect(!store.items[0].state.isOpen)
    }

    @Test func unboundArrowsStillSwitchTheInboxTabs() {
        #expect(keys.key(keyDown(kVK_RightArrow)))
        #expect(hub.filter == .bots)
        #expect(keys.key(keyDown(kVK_LeftArrow)))
        #expect(hub.filter == .needsYou)
    }
}

/// DESIGN.md 6.2: what the user bound comes before the typing that searches and before the hub's own chords; the menu key
/// asks the picked row for its context menu.
@MainActor
@Suite struct HubKeysBindings {
    private let store = Store()
    private let hub = HubState()
    private let keys: HubKeys

    init() {
        store.persists = false
        store.undoStack.announce = { _ in }
        keys = HubKeys(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
        store.items = [InboxItem(id: "one", repo: "a/one", kind: .issueComment, number: 1, title: "t", snippet: "", author: "x", avatar: nil,
                                 authorIsApp: false, url: URL(string: "https://github.com/a/one")!, createdAt: Date(), state: .unread)]
        hub.pinned = true
        hub.selection = "i:one"
    }

    @discardableResult
    private func press(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String) -> Bool {
        keys.key(keyDown(code, flags, chars))
    }

    @Test func aLetterBoundToAnActionActsOnThePickedRowInsteadOfSearching() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_T)), for: .toggleRead)
        #expect(press(kVK_ANSI_T, [], "t"))
        #expect(store.items[0].state == .read && hub.query.isEmpty)
        // With Shift: a Shift-letter binding is the same.
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_Y), modifiers: [.shift]), for: .toggleRead)
        #expect(press(kVK_ANSI_Y, [.shift], "Y"))
        #expect(store.items[0].state == .unread && hub.query.isEmpty)
        // Unbound letters still search, and so does the bound one with nothing picked to act on.
        #expect(press(kVK_ANSI_Z, [], "z") && hub.query == "z")
        hub.query = ""
        hub.selection = nil
        #expect(press(kVK_ANSI_T, [], "t") && hub.query == "t")
    }

    @Test func aBindingOnACommandDigitRunsBeforeTheFocusChord() {
        store.agents.enabled = true
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command]), for: .toggleRead)
        #expect(press(kVK_ANSI_3, [.command], "3"))
        #expect(store.items[0].state == .read && hub.focus == nil)
        // With nothing picked the action has nothing to do: the chord is what is left, as ⌘Z leaves undo.
        hub.selection = nil
        #expect(press(kVK_ANSI_3, [.command], "3"))
        #expect(hub.focus == .agents)
    }

    @Test func theMenuKeyAsksThePickedRowForItsMenu() {
        #expect(press(kVK_ContextualMenu, [], ""))
        #expect(hub.rowMenuRequest?.target == "i:one")
        #expect(press(kVK_Return, [.control], "\r") && hub.rowMenuRequest?.seq == 2)
        #expect(press(kVK_F10, [.shift], ""))
        // Nothing picked, nothing to open; and New session has no menu of its own to open this way.
        hub.selection = nil
        #expect(!press(kVK_ContextualMenu, [], ""))
        hub.selection = "s:new"
        #expect(!press(kVK_ContextualMenu, [], ""))
    }

    @Test func theMenuChordsLeaveAFocusedControlAlone() {
        let control = UUID()
        hub.controls.set(control, focused: true)
        #expect(!press(kVK_ContextualMenu, [], ""))
        #expect(!press(kVK_F10, [.shift], ""))
        #expect(!press(kVK_Return, [.control], "\r"))
        #expect(hub.rowMenuRequest == nil)
        // Once the ring lets go, the picked row's menu is theirs again.
        hub.controls.set(control, focused: false)
        #expect(press(kVK_ContextualMenu, [], "") && hub.rowMenuRequest?.target == "i:one")
    }

    @Test func aBindingOnAMenuChordActsInsteadOfOpeningTheMenu() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_Return), modifiers: [.control]), for: .toggleRead)
        #expect(press(kVK_Return, [.control], "\r"))
        #expect(store.items[0].state == .read && hub.rowMenuRequest == nil)
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_F10), modifiers: [.shift]), for: .discard)
        #expect(press(kVK_F10, [.shift], ""))
        #expect(!store.items[0].state.isOpen && hub.rowMenuRequest == nil)
    }

    @Test func aFocusedControlLetsGoOfTheRowCommandsAndTheArrowsTakeTheRowsBack() {
        let control = UUID()
        hub.controls.set(control, focused: true)
        // ⌫ and a bound letter are not the picked row's while the ring is on a control.
        #expect(!press(kVK_Delete, [], "\u{7F}"))
        #expect(store.items[0].state == .unread)
        // An arrow walks the rows again: the ring lets go (the control reports it when its focus goes).
        #expect(press(kVK_DownArrow, [], ""))
        hub.controls.set(control, focused: false)
        #expect(press(kVK_Delete, [], "\u{7F}"))
        #expect(!store.items[0].state.isOpen)
    }
}
