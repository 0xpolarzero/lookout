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
        store.persists = false
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

    @Test func typingInTheHubOpensTheFieldAndHandsItTheKey() {
        let before = hub.focusRequest
        let z = key(kVK_ANSI_Z, [], "z")
        #expect(keys.key(z))
        // The field types it (so it is not read here): the query is still empty until the field has the keyboard.
        #expect(hub.query.isEmpty && hub.searchOpen && hub.caretAtEnd && hub.focusRequest == before + 1)
        #expect(hub.pendingKeys == [z])
    }

    @Test func aDeadKeyStartsTheSearchToo() {
        // The event of a dead key carries no characters; the layout says it is one.
        keys.isDeadKey = { $0.keyCode == UInt16(kVK_ANSI_E) }
        let before = hub.focusRequest
        let dead = key(kVK_ANSI_E, .option, "")
        #expect(keys.key(dead) && hub.searchOpen && hub.pendingKeys == [dead] && hub.focusRequest == before + 1)
        // Not a key that types nothing (an arrow, F-keys), nor a command chord.
        hub.endSearch()
        #expect(!press(kVK_ANSI_A, .option, "") && !press(kVK_ANSI_E, .command, "") && !hub.searchOpen && hub.pendingKeys.isEmpty)
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

    @Test func aReturnOrEnterBoundToAnotherActionDoesThatInsteadOfOpening() {
        let (window, _) = editingWindow("zig")
        defer { window.close() }
        searching("zig")
        let target = keys.targets().first { $0.hasPrefix("i:") }!
        keys.select(target)
        let item = store.items.first { "i:" + $0.id == target }!
        let was = item.state
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_KeypadEnter)), for: .toggleRead)
        #expect(press(kVK_ANSI_KeypadEnter, [], "\r", in: window))
        #expect(store.items.first { $0.id == item.id }?.state != was && log.opened.isEmpty)
        #expect(press(kVK_ANSI_KeypadEnter, [], "\r", in: window))
        #expect(store.items.first { $0.id == item.id }?.state == was && log.opened.isEmpty)
        // Return, still Open's, opens.
        #expect(press(kVK_Return, [], "\r", in: window) && log.opened.count == 1)
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

    @Test func typingWithTheSearchClosedPutsTheKeysInTheFieldInOrder() async throws {
        let ui = UIState(persists: false, edge: .right)
        let (window, host) = mounted(InboxSearchField(hub: hub, ui: ui, store: store, count: "1 item"))
        defer { window.close() }
        await settle()
        unfocus(window)
        // Two keys, the second before the field has the keyboard: both are the field's, in order.
        #expect(press(kVK_ANSI_Z, [], "z", in: window) && press(kVK_ANSI_I, [], "i", in: window))
        #expect(hub.query.isEmpty && hub.searchOpen && hub.pendingKeys.count == 2)
        focus(host, in: window)
        hub.typePendingKeys()
        await settle()
        #expect(hub.query == "zi" && hub.pendingKeys.isEmpty)
        #expect(hub.selection != nil && hub.selection == store.hubTargets(hub).first)
    }

    @Test func aDeadKeyWithTheSearchClosedReachesTheFieldEditor() async throws {
        // An accent key carries no characters, so it can't be typed for the field: the event itself goes to it. (Composing
        // the accent is the text system's, which a synthetic event can't drive: the layout and the field are native.)
        let ui = UIState(persists: false, edge: .right)
        let (window, host) = mounted(InboxSearchField(hub: hub, ui: ui, store: store, count: ""))
        defer { window.close() }
        await settle()
        unfocus(window)
        let dead = try #require(Self.deadKeyEvent(in: window), "the current layout has no dead key")
        #expect(dead.characters == "" && !hub.searchOpen)
        #expect(keys.key(dead) && hub.searchOpen && hub.pendingKeys == [dead])
        focus(host, in: window)
        hub.typePendingKeys()
        #expect(hub.pendingKeys.isEmpty)
    }

    /// The state before the first key: the field not focused, though SwiftUI may have focused it as it was shown.
    private func unfocus(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        hub.searchFocused = false
    }

    /// The field's focus, which SwiftUI only gives in a key window (the test's is not one): given by hand, as it would be,
    /// and the keys it takes then taken by hand too (the field does it when its focus changes).
    private func focus(_ host: NSView, in window: NSWindow) {
        window.makeFirstResponder(host.first(NSTextField.self))
    }

    /// Lets what SwiftUI and the field defer to the next turns of the main queue happen.
    private func settle() async {
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// An event of a key that is a dead key on the current layout, found as the system finds it.
    private static func deadKeyEvent(in window: NSWindow) -> NSEvent? {
        let probe = HubKeys(store: Store(), ui: UIState(persists: false, edge: .right), hub: HubState())
        for flags in [NSEvent.ModifierFlags(), .option] {
            for code in 0..<50 {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
                if probe.isDeadKey(event) { return event }
            }
        }
        return nil
    }

    /// A window showing `view` with the search field's editor up, as the hub does.
    private func mounted<V: View>(_ view: V) -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: view.frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        for _ in 0..<30 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded() }
        return (window, host)
    }

    @Test func backspaceOffTheFieldEditsTheQueryAndEndsItWhenEmpty() {
        hub.query = "zi"
        hub.searchOpen = true
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
