import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
@testable import Lookout

/// Done can be taken back: ⌘Z and the line's button, for 30 seconds, through polls and pruning.
@MainActor
@Suite(.hostsWindows) struct Undo {
    private func item(_ id: String, state: ItemState = .unread, age: TimeInterval = 60) -> InboxItem {
        InboxItem(id: id, repo: "a/one", kind: .issueComment, number: 1, title: "t \(id)", snippet: "", author: "x", avatar: nil,
                  authorIsApp: false, url: URL(string: "https://github.com/a/one")!, createdAt: Date().addingTimeInterval(-age),
                  state: state)
    }

    private func store(_ items: [InboxItem]) -> Store {
        let s = Store()
        s.persists = false
        s.repos = [RepoConfig(fullName: "a/one", allComments: true)]
        s.items = items
        s.undoStack.announce = { _ in }
        return s
    }

    private func state(_ s: Store, _ id: String) -> ItemState? { s.items.first { $0.id == id }?.state }

    @Test func undoPutsBackWhatDoneMovedWithItsReadState() {
        let s = store([item("1"), item("2", state: .read)])
        s.discard(s.items[0])
        s.discard(s.items[1])
        #expect(state(s, "1") == .discarded && state(s, "2") == .discarded)
        // Newest first, each as it was: unread stays unread.
        #expect(s.undoLast() && state(s, "2") == .read && state(s, "1") == .discarded)
        #expect(s.undoLast() && state(s, "1") == .unread)
        #expect(!s.undoLast())
    }

    @Test func undoLeavesAloneWhatChangedSince() {
        let s = store([item("1"), item("2")])
        s.discard(s.items[0])
        s.restore(s.items[0])  // already back, by hand
        s.markUnread(s.items[0])
        #expect(!s.undoLast() && state(s, "1") == .unread)
        // An entry whose item is gone is skipped for the one before it.
        s.discard(s.items[1])
        s.discard(s.items[0])
        s.removeItems { $0.id == "1" }
        #expect(s.undoLast() && state(s, "2") == .unread)
    }

    @Test func undoOnlyReachesBack30Seconds() {
        let s = store([item("1")])
        s.discard(s.items[0])
        #expect(!s.undoStack.undo(now: Date().addingTimeInterval(UndoStack.validFor + 1)) && state(s, "1") == .discarded)
    }

    @Test func undoSurvivesAPollsPruningOfOldDoneItems() {
        // Done for a fortnight would be pruned by the next poll; one just moved is held while Undo could bring it back.
        let s = store([item("old", age: 20 * 86400), item("older", state: .discarded, age: 20 * 86400)])
        s.discard(s.items[0])
        s.prune()
        #expect(state(s, "old") == .discarded && state(s, "older") == nil)
        #expect(s.undoLast() && state(s, "old") == .unread)
        // Once the half minute has passed, it is pruned like any other.
        s.discard(s.items[0])
        s.prune(now: Date().addingTimeInterval(UndoStack.validFor + 1))
        #expect(state(s, "old") == nil)
    }

    @Test func theItemCapLeavesAloneWhatUndoCouldBringBack() {
        let many = (0..<Store.itemCap + 5).map { item("n\($0)", age: Double($0) + 1) }
        let s = store(many)
        // The oldest of them is past the cap, and just moved to Done.
        let last = s.items.last!
        s.discard(last)
        s.prune()
        #expect(state(s, last.id) == .discarded)
        #expect(s.items.count == Store.itemCap + 1)
        #expect(s.undoLast() && state(s, last.id) == .unread)
    }

    @Test func theLineShowsThenGoesAndTheUndoStaysForCommandZ() async throws {
        let s = store([item("1")])
        let gate = Gate()
        s.undoStack.sleep = { _ in await gate.wait() }
        s.discard(s.items[0])
        #expect(s.undoStack.line?.message == "Moved to Done")
        gate.open()
        try await eventually { s.undoStack.line == nil }
        #expect(s.undoStack.line == nil && s.undoLast() && state(s, "1") == .unread)
    }

    @Test func commandZInTheHubUndoesButAFocusedFieldKeepsIt() {
        let s = store([item("1")])
        let hub = HubState()
        hub.pinned = true
        let keys = HubKeys(store: s, ui: UIState(persists: false, edge: .right), hub: hub)
        func press(in window: NSWindow? = nil) -> Bool {
            keys.key(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: window?.windowNumber ?? 0, context: nil, characters: "z",
                                      charactersIgnoringModifiers: "z", isARepeat: false, keyCode: UInt16(kVK_ANSI_Z))!)
        }
        s.discard(s.items[0])
        // The search field's ⌘Z is its own undo: its field editor has the keyboard.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        window.contentView?.addSubview(field)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        window.makeFirstResponder(field)
        defer { window.close() }
        hub.searchFocused = true
        hub.searchOpen = true
        #expect(!press(in: window))
        #expect(state(s, "1") == .discarded)
        hub.endSearch()
        window.makeFirstResponder(nil)
        #expect(press(in: window) && state(s, "1") == .unread)
        #expect(!press(in: window))
    }

    @Test func theFocusedUndoButtonKeepsSpaceAndReturn() throws {
        let s = store([item("1"), item("2")])
        let ui = UIState(persists: false, edge: .right)
        let hub = HubState()
        hub.pinned = true
        let keys = HubKeys(store: s, ui: ui, hub: hub)
        func press(_ code: Int, _ chars: String, in window: NSWindow) -> Bool {
            keys.key(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                      keyCode: UInt16(code))!)
        }
        s.discard(s.items[0])
        keys.select("i:2")
        // The line as the hub shows it, its Undo button on the Tab ring.
        let host = NSHostingView(rootView: LookoutHub(store: s, ui: ui, hub: hub).undoLine.frame(width: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60), styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded() }
        let undo = try #require(host.first(NSButton.self))
        #expect(window.makeFirstResponder(undo))
        // Space and Return are the button's: the picked row is not marked read, and the button still activates.
        #expect(!press(kVK_Space, " ", in: window) && !press(kVK_Return, "\r", in: window) && !press(kVK_ANSI_KeypadEnter, "\r", in: window))
        #expect(state(s, "2") == .unread && state(s, "1") == .discarded)
        undo.performClick(nil)
        #expect(state(s, "1") == .unread)
        // Off the button they are the hub's again.
        window.makeFirstResponder(nil)
        #expect(press(kVK_Space, " ", in: window) && state(s, "2") == .read)
    }
}

private extension NSView {
    /// The first view of `type` at or below this one.
    func first<V: NSView>(_ type: V.Type) -> V? {
        (self as? V) ?? subviews.lazy.compactMap { $0.first(type) }.first
    }
}

/// Holds a sleeper until the test lets it go.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Waits for `condition`, which something the test started brings about.
@MainActor private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
}
