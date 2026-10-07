import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
@testable import Lookout

/// The hub's keys against the search field, a real text field: what it keeps for typing, and what stays the hub's.
@MainActor
@Suite struct SearchFieldKeys {
    private let store = Store()
    private let hub = HubState()
    private let keys: HubKeys
    private let log = Log()

    final class Log {
        var opened: [String] = []
        var closed = 0
    }

    init() {
        Demo.populate(store, .agents)
        store.agents.expanded = true
        let log = log
        store.interceptOpen = { log.opened.append($0) }
        keys = HubKeys(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
        keys.onClose = { log.closed += 1 }
        hub.pinned = true
    }

    private func key(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "", in window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased(), isARepeat: false,
                         keyCode: UInt16(code))!
    }

    @discardableResult
    private func press(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "", in window: NSWindow? = nil) -> Bool {
        keys.key(key(code, flags, chars, in: window))
    }

    /// A window with a text field being edited, as the search field is: its field editor is the first responder.
    private func editingWindow(_ text: String = "") -> (window: NSWindow, field: NSTextField) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        field.stringValue = text
        window.contentView?.addSubview(field)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        window.makeFirstResponder(field)
        return (window, field)
    }

    /// The search as the field leaves it: the query typed, the field showing and focused.
    private func searching(_ query: String) {
        hub.query = query
        hub.searchOpen = true
        hub.searchFocused = true
    }

    @Test func typingInTheHubSeedsTheFieldAndAsksItForFocus() {
        let before = hub.focusRequest
        #expect(press(kVK_ANSI_Z, [], "z"))
        #expect(hub.query == "z" && hub.searchOpen && hub.caretAtEnd && hub.focusRequest == before + 1)
        // Its first result is picked, so Return opens it at once.
        #expect(hub.selection == keys.targets().first)
    }

    @Test func theFieldKeepsWhatItTypesAndTheKeysDoNotSearchOrActMeanwhile() {
        let (window, _) = editingWindow("zig")
        defer { window.close() }
        searching("zig")
        keys.select(keys.targets().first!)
        let unread = store.items.filter { $0.state == .unread }.count
        // Letters, Space, ⌫, the side arrows, ⌘Z and the discard key (⌫) are the field's own.
        #expect(!press(kVK_ANSI_A, [], "a", in: window))
        #expect(!press(kVK_Space, [], " ", in: window) && !press(kVK_Delete, [], "\u{7f}", in: window))
        #expect(!press(kVK_LeftArrow, [], "\u{F702}", in: window) && !press(kVK_ANSI_Z, .command, "z", in: window))
        #expect(hub.query == "zig" && store.items.filter { $0.state == .unread }.count == unread && log.opened.isEmpty)
    }

    @Test func theArrowsWalkTheResultsAndReturnOpensThePick() {
        let (window, _) = editingWindow("zig")
        defer { window.close() }
        searching("zig")
        let first = keys.targets().first!
        keys.select(first)
        #expect(press(kVK_DownArrow, [], "\u{F701}", in: window))
        #expect(hub.selection != first)
        #expect(press(kVK_Return, [], "\r", in: window))
        #expect(log.opened.count == 1)
    }

    @Test func returnOpensNothingOnceTheTypingFilteredThePickOut() {
        let (window, _) = editingWindow("zig")
        defer { window.close() }
        searching("zig")
        keys.select(keys.targets().first!)
        hub.query = "no such thing anywhere"
        #expect(!press(kVK_Return, [], "\r", in: window) && log.opened.isEmpty)
    }

    @Test func escapeClearsAndEndsTheSearchInOneStep() {
        let (window, field) = editingWindow("zig")
        defer { window.close() }
        searching("zig")
        hub.focus = .agents
        #expect(press(kVK_Escape, [], "\u{1b}", in: window))
        #expect(hub.query.isEmpty && !hub.searchOpen && !hub.searchFocused)
        #expect(window.firstResponder !== field.currentEditor())
        // Not the hub's close: it stays open, and so does the focus.
        #expect(hub.pinned && log.closed == 0 && hub.focus == .agents)
    }

    @Test func escapeEndsAnEmptyFieldToo() {
        let (window, _) = editingWindow()
        defer { window.close() }
        searching("")
        #expect(press(kVK_Escape, [], "\u{1b}", in: window) && !hub.searchOpen && hub.pinned)
    }

    @Test func keepAndRemoveActOnThePickedSessionWithTheFieldFocused() {
        let (window, _) = editingWindow("lcu")
        defer { window.close() }
        let session = store.agentRows.pending[0]
        searching(session.session.title)
        keys.select("a:" + session.id)
        #expect(keys.targets().contains("a:" + session.id))
        // ⌘K keeps it and ⌘⌫ hides it, the field's own ⌘⌫ (delete to the start of the line) notwithstanding.
        #expect(press(kVK_ANSI_K, .command, "k", in: window))
        #expect(store.agentRows.kept.contains { $0.id == session.id })
        #expect(press(kVK_Delete, .command, "\u{7f}", in: window))
        #expect(store.agents.entries.first { $0.id == session.id }?.hiddenAt != nil)
        // With nothing picked, or no action bound to the chord, they stay the field's.
        hub.selection = nil
        #expect(!press(kVK_ANSI_K, .command, "k", in: window) && !press(kVK_Delete, .command, "\u{7f}", in: window))
        keys.select(keys.targets().first { $0.hasPrefix("i:") } ?? "i:x")
        #expect(!press(kVK_ANSI_P, .command, "p", in: window))
    }

    @Test func markAllReadWorksWithTheFieldFocusedButTypingDoesNot() {
        let (window, _) = editingWindow()
        defer { window.close() }
        searching("")
        #expect(store.list(.needsYou).contains { $0.state == .unread })
        #expect(press(kVK_Space, .option, " ", in: window))
        #expect(!store.list(.needsYou).contains { $0.state == .unread })
        #expect(!press(kVK_Space, [], " ", in: window))
    }

    @Test func settingsChordsStayTheHubsInTheField() {
        let (window, _) = editingWindow()
        defer { window.close() }
        searching("zig")
        #expect(press(kVK_ANSI_Comma, .command, ",", in: window) && hub.page == .settings)
    }

    @Test func aKeyDuringCompositionIsTheInputMethods() {
        let (window, field) = editingWindow()
        defer { window.close() }
        let editor = field.currentEditor() as! NSTextView
        // An AZERTY dead key (´ then e) or an IME is mid-composition: Esc, Return and the arrows are its own.
        editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.hasMarkedText())
        searching("zig")
        keys.select(keys.targets().first!)
        #expect(!press(kVK_Escape, [], "\u{1b}", in: window) && !press(kVK_Return, [], "\r", in: window))
        #expect(!press(kVK_DownArrow, [], "\u{F701}", in: window))
        #expect(hub.query == "zig" && hub.searchOpen && log.opened.isEmpty)
    }

    @Test func offTheFieldTypingStillSearchesAndBackspaceEndsItWhenEmpty() {
        #expect(press(kVK_ANSI_Z, [], "z") && press(kVK_ANSI_I, [], "i"))
        #expect(hub.query == "zi")
        #expect(press(kVK_Delete, [], "\u{7f}") && hub.query == "z")
        #expect(press(kVK_Delete, [], "\u{7f}") && hub.query.isEmpty && !hub.searchOpen)
    }

    @Test func leavingTheHubEndsTheSearchToo() {
        searching("zig")
        keys.close()
        #expect(hub.query.isEmpty && !hub.searchOpen && !hub.searchFocused)
    }
}

/// The field itself, mounted: what is typed into it lands in the query, as it would from a paste or an input method.
@MainActor
@Suite struct SearchFieldView {
    @Test func whatTheFieldIsGivenLandsInTheQueryAndPicksTheFirstResult() throws {
        let store = Store()
        Demo.populate(store, .agents)
        let hub = HubState()
        hub.query = "z"
        hub.searchOpen = true
        let host = NSHostingView(rootView: InboxSearchField(hub: hub, ui: UIState(persists: false, edge: .right), store: store, count: "1 item")
            .frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded() }
        // A real text field, not drawn text.
        let field = try #require(host.first(NSTextField.self))
        #expect(field.isEditable && field.stringValue == "z")
        window.makeFirstResponder(field)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.moveToEndOfDocument(nil)
        editor.insertText("ig", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        #expect(hub.query == "zig")
        #expect(hub.selection != nil && hub.selection == store.hubTargets(hub).first)
    }
}

private extension NSView {
    /// The first view of `type` at or below this one.
    func first<V: NSView>(_ type: V.Type) -> V? {
        (self as? V) ?? subviews.lazy.compactMap { $0.first(type) }.first
    }
}
