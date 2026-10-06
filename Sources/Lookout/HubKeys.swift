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

    /// Returns whether the key was handled. Typing in a text field is left alone, except Esc, and a focused control keeps
    /// Space and Return.
    func key(_ event: NSEvent) -> Bool {
        // An input method is composing in a text field: Esc, the arrows and Return are the composition's.
        if (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        if hub.inbox.searchFocused, hub.page == .main, let handled = searchKey(event) { return handled }
        // A focused control (Clear, More, Undo) takes Space and Return: they are not the search's or the row's.
        if hub.controls.isActive, event.modifierFlags.intersection(Shortcut.relevant).isEmpty,
           [kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) { return false }
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
        // A control the Tab ring is on takes Return and Space itself; they don't act on the row that is picked.
        if hub.controls.isActive, flags.isEmpty, [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space].contains(Int(event.keyCode)) {
            return false
        }
        if flags == .command, event.charactersIgnoringModifiers == "," {
            hub.go(.settings)
            return true
        }
        if shortcut == store.shortcut(.refresh) { store.refreshNow(); return true }
        if flags == .command, event.charactersIgnoringModifiers == "z" { return store.undoLast() }
        guard hub.expanded, hub.page == .main else { return false }
        if flags == .command, event.charactersIgnoringModifiers == "f" {
            hub.beginSearch()
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
        // Not over rows the list isn't showing (a sign-in problem replaces it).
        if shortcut == store.shortcut(.markAllRead) {
            if store.inboxReplacement == nil { LookoutHub.animate { store.markAllRead(hub.filter) } }
            return true
        }
        // Row commands act only on a row the lists show (a pick the search has since filtered out is not one).
        guard let selection = hub.selection, targets.contains(selection) else { return false }
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
        if selection.hasPrefix("c:") { return ciKey(event, id: id, flags: flags, shortcut: shortcut) }
        // The list's own rows ("+N more", New session).
        if selection.hasPrefix("s:") {
            // → on New session opens its menu of projects.
            if selection == "s:new", shortcut == Shortcut(keyCode: UInt16(kVK_RightArrow)) {
                hub.openProjectsMenu()
                return true
            }
            guard shortcut == store.shortcut(.openItem) else { return false }
            hub.activateSessionTarget(selection, store: store, ui: ui)
            return true
        }
        if selection.hasPrefix("a:") {
            if shortcut == store.shortcut(.openItem) { store.openAgent(id) }
            else if shortcut == store.shortcut(.toggleRead) { store.toggleAgentRead(id) }
            else if shortcut == store.shortcut(.keepSession) { LookoutHub.animate { store.keepAgent(id) } }
            else if shortcut == store.shortcut(.removeSession) { LookoutHub.animate { store.dismissAgent(id) } }
            else if shortcut == store.shortcut(.moveSessionUp) || shortcut == store.shortcut(.moveSessionDown) {
                let step = shortcut == store.shortcut(.moveSessionUp) ? -1 : 1
                // The row keeps the pick wherever it lands, and the list follows it.
                if store.canMoveAgent(id, by: step) {
                    LookoutHub.animate { store.moveAgent(id, by: step) }
                    select(selection)
                }
            } else { return false }
            return true
        }
        return false
    }

    /// Every row the arrows walk through, top to bottom: inbox items, CI, then sessions, then the list's own rows; only
    /// those on screen (a focused section shrinks the others).
    private func targets() -> [String] {
        (store.hubTargets(hub) + store.sessionExtraTargets(hub)).filter(hub.shows)
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
            // The field shows while there is something in it, and goes with the query.
            if query.isEmpty { hub.inbox.endSearch() }
        }
        if !query.isEmpty { hub.beginSearch(seeded: true) }
        hub.pick(targets().first, ui: ui)
    }

    /// Picks a row from the keyboard: the lists follow it.
    func select(_ target: String) { hub.pick(target, ui: ui) }
}

// MARK: Search field

extension HubKeys {
    /// A key while the search field has focus: Esc clears and ends the search, ↑↓ walk the results and ↩ or the
    /// configured Open shortcut opens one; everything else (typing, ⌫, Space, ⌘Z) is the field's own. nil leaves the
    /// key to the field.
    fileprivate func searchKey(_ event: NSEvent) -> Bool? {
        // Open is the user's to rebind, ⌘O included, which the field would otherwise swallow with the other
        // modifier combinations. A bare letter is still typed.
        if Shortcut(event) == store.shortcut(.openItem), !typesText(event) { return openResult() }
        guard event.modifierFlags.intersection(Shortcut.relevant).isEmpty else { return nil }
        switch Int(event.keyCode) {
        case kVK_Escape:
            event.window?.makeFirstResponder(nil)
            setQuery("")
        case kVK_UpArrow, kVK_DownArrow:
            move(down: Int(event.keyCode) == kVK_DownArrow, in: targets())
        case kVK_Return:
            return openResult()
        default:
            return nil
        }
        return true
    }

    /// Opens the pick, only if it is a row the results show: one the typing has since filtered out is not opened.
    private func openResult() -> Bool? {
        guard let selection = hub.selection, targets().contains(selection) else { return nil }
        let id = String(selection.dropFirst(2))
        if selection.hasPrefix("i:"), let item = store.items.first(where: { $0.id == id }) { store.open(item) }
        else if selection.hasPrefix("a:") { store.openAgent(id) }
        else { return nil }
        return true
    }

    /// Whether a field would put this key in its text: a printable character without ⌃⌥⌘.
    private func typesText(_ event: NSEvent) -> Bool {
        guard !Shortcut(event).hasCommandLikeModifier, let typed = event.characters, !typed.isEmpty else { return false }
        return typed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }
    }
}
