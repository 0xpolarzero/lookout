import AppKit
import Carbon
import SwiftUI

/// The hub's keys, the same in the app and the playground.
@MainActor
final class HubKeys {
    let store: Store
    let ui: UIState
    let hub: HubState
    /// Unpinned and closed from the keyboard (Esc): the app hands focus back.
    var onClose: () -> Void = {}

    init(store: Store, ui: UIState, hub: HubState) {
        self.store = store
        self.ui = ui
        self.hub = hub
    }

    /// The keep-open key: opens (and keeps open), or closes.
    func toggleTap() {
        if HotKeys.debug { NSLog("Lookout keys: tap, pinned %d", hub.pinned ? 1 : 0) }
        if hub.pinned { close() } else { hub.pinned = true }
    }

    func close() {
        // Closing leaves any page: the hub opens on the main view next time.
        hub.go(.main)
        hub.query = ""
        hub.inbox.endSearch()
        hub.keyboardSelection = nil
        hub.pinned = false
        hub.hovering = false
        onClose()
    }

    /// Returns whether the key was handled. Typing in a text field is left alone, except Esc.
    func key(_ event: NSEvent) -> Bool {
        if hub.inbox.searchFocused, hub.page == .main, let handled = searchKey(event) { return handled }
        let editing = event.window?.firstResponder is NSText
        if editing, event.keyCode != UInt16(kVK_Escape) { return false }
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        let shortcut = Shortcut(event)
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            if editing { event.window?.makeFirstResponder(nil) }
            else if !hub.query.isEmpty { setQuery("") }
            else if hub.page != .main { hub.back() }
            else if hub.focus != nil { LookoutHub.animate(LookoutHub.refocus) { hub.focus = nil } }
            else { close() }
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "," {
            hub.go(.settings)
            return true
        }
        if shortcut == store.shortcut(.refresh) { store.refreshNow(); return true }
        if flags == .command, event.charactersIgnoringModifiers == "z" { return store.undoLast() }
        guard hub.expanded, hub.page == .main else { return false }
        if flags == .command, event.charactersIgnoringModifiers == "f" {
            hub.inbox.startSearch()
            return true
        }
        // Typing searches: letters and digits start it, Space and ⌫ edit it once it has started.
        if event.keyCode == UInt16(kVK_Delete), flags.isEmpty, !hub.query.isEmpty {
            setQuery(String(hub.query.dropLast()))
            return true
        }
        if flags.subtracting(.shift).isEmpty, let typed = event.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }),
           !(typed == " " && hub.query.isEmpty) {
            setQuery(hub.query + typed)
            return true
        }
        let targets = targets()
        if event.keyCode == 125 || event.keyCode == 126, flags.isEmpty {
            move(down: event.keyCode == 125, in: targets)
            return true
        }
        if shortcut == store.shortcut(.markAllRead) {
            LookoutHub.animate { store.markAllRead(hub.filter) }
            return true
        }
        guard let selection = hub.selection else { return false }
        let id = String(selection.dropFirst(2))
        if selection.hasPrefix("i:"), let item = store.items.first(where: { $0.id == id }) {
            if shortcut == store.shortcut(.openItem) { store.open(item) }
            else if shortcut == store.shortcut(.toggleRead) { item.state == .unread ? store.markRead(item) : store.markUnread(item) }
            else if shortcut == store.shortcut(.discard) {
                let i = targets.firstIndex(of: selection) ?? 0
                if targets.indices.contains(i + 1) { select(targets[i + 1]) }
                LookoutHub.animate { item.state.isOpen ? store.done(item) : store.restore(item) }
            } else { return false }
            return true
        }
        if selection.hasPrefix("a:") {
            if shortcut == store.shortcut(.openItem) { store.openAgent(id) }
            else if shortcut == store.shortcut(.toggleRead) { store.toggleAgentRead(id) }
            else if shortcut == store.shortcut(.keepSession) { LookoutHub.animate { store.keepAgent(id) } }
            else if shortcut == store.shortcut(.removeSession) { LookoutHub.animate { store.dismissAgent(id) } }
            else { return false }
            return true
        }
        return false
    }

    /// Every row the arrows walk through, top to bottom: inbox items, then sessions.
    private func targets() -> [String] {
        store.hubItems(hub).map { "i:" + $0.id } + store.hubSessions(hub).map { "a:" + $0.id }
    }

    private func move(down: Bool, in targets: [String]) {
        let i = targets.firstIndex(of: hub.selection ?? "") ?? (down ? -1 : targets.count)
        let next = min(max(i + (down ? 1 : -1), 0), targets.count - 1)
        if targets.indices.contains(next) { select(targets[next]) }
    }

    /// A new search picks its first result, so ↩ opens it straight away.
    private func setQuery(_ query: String) {
        LookoutHub.animate {
            hub.query = query
            // The field shows while there is something in it, takes the focus, and goes with the query.
            if query.isEmpty { hub.inbox.endSearch() } else { hub.inbox.startSearch() }
            // Searching looks everywhere, and what you type shows in the inbox's header: nothing stays shrunk.
            if !query.isEmpty { hub.focus = nil }
        }
        if let first = targets().first { select(first) } else { hub.selection = nil; hub.keyboardSelection = nil; ui.drawerSelection = nil }
    }

    /// Picks a row from the keyboard: the lists follow it.
    func select(_ target: String) {
        hub.selection = target
        hub.requestScroll(target)
        ui.drawerSelection = target.hasPrefix("a:") ? String(target.dropFirst(2)) : nil
    }
}

// MARK: Search field

extension HubKeys {
    /// A key while the search field has focus: Esc clears and ends the search, ↑↓ and ↩ walk and open the results;
    /// everything else (typing, ⌫, Space, ⌘Z) is the field's own. nil leaves the key to the field.
    fileprivate func searchKey(_ event: NSEvent) -> Bool? {
        guard event.modifierFlags.intersection(Shortcut.relevant).isEmpty else { return nil }
        switch Int(event.keyCode) {
        case kVK_Escape:
            event.window?.makeFirstResponder(nil)
            setQuery("")
        case kVK_UpArrow, kVK_DownArrow:
            move(down: Int(event.keyCode) == kVK_DownArrow, in: targets())
        case kVK_Return:
            guard let selection = hub.selection else { return nil }
            let id = String(selection.dropFirst(2))
            if selection.hasPrefix("i:"), let item = store.items.first(where: { $0.id == id }) { store.open(item) }
            else if selection.hasPrefix("a:") { store.openAgent(id) }
            else { return nil }
        default:
            return nil
        }
        return true
    }
}
