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
        hub.keyboardSelection = nil
        hub.pinned = false
        hub.hovering = false
        onClose()
    }

    /// Returns whether the key was handled. Typing in a text field is left alone, except Esc.
    func key(_ event: NSEvent) -> Bool {
        let editing = event.window?.firstResponder is NSText
        if editing, event.keyCode != UInt16(kVK_Escape) { return false }
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        let shortcut = Shortcut(event)
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            if editing { event.window?.makeFirstResponder(nil) }
            else if hub.menuKeys, !hub.expanded { closeMenu() }
            else if !hub.query.isEmpty { setQuery("") }
            else if hub.page != .main { hub.back() }
            else if hub.focus != nil { LookoutHub.animate(LookoutHub.refocus) { hub.focus = nil } }
            else { close() }
            return true
        }
        // A focused control takes its own Return and Space (the Tab ring, DESIGN.md 6.2): a row's pick or the menu's
        // highlight is not what it does.
        if hub.controlHasFocus, flags.isEmpty, [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space].contains(Int(event.keyCode)) { return false }
        if flags == .command, event.charactersIgnoringModifiers == "," {
            hub.go(.settings)
            return true
        }
        if shortcut == store.shortcut(.refresh) { store.refreshNow(); return true }
        // ⌘1, ⌘2, ⌘3 give the Inbox, CI or Sessions all the room (again: back); ⌘0 gives every section its room back.
        // By key position, so they hold on an AZERTY keyboard, where the digits are shifted.
        if flags == .command, hub.expanded, hub.page == .main, let focus = Self.focusKey(event.keyCode) {
            if let section = focus { hub.toggleFocus(section) } else if hub.focus != nil { LookoutHub.animate(LookoutHub.refocus) { hub.focus = nil } }
            rehome()
            return true
        }
        if hub.menuKeys, !hub.expanded { return menuKey(event, flags: flags) }
        guard hub.expanded, hub.page == .main else { return false }
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
            let down = event.keyCode == 125
            let i = targets.firstIndex(of: hub.selection ?? "") ?? (down ? -1 : targets.count)
            let next = min(max(i + (down ? 1 : -1), 0), targets.count - 1)
            if targets.indices.contains(next) { select(targets[next]) }
            return true
        }
        if shortcut == store.shortcut(.markAllRead), hub.shows(.inbox) {
            LookoutHub.animate { store.markAllRead(hub.filter) }
            return true
        }
        // Row commands only act on a row that is showing: a pick in a section that shrank is not one.
        guard let selection = hub.selection, targets.contains(selection) else { return false }
        let id = String(selection.dropFirst(2))
        if selection.hasPrefix("i:"), let item = store.items.first(where: { $0.id == id }) {
            if shortcut == store.shortcut(.openItem) { store.open(item) }
            else if shortcut == store.shortcut(.toggleRead) { item.state == .unread ? store.markRead(item) : store.markUnread(item) }
            else if shortcut == store.shortcut(.discard) {
                let i = targets.firstIndex(of: selection) ?? 0
                if targets.indices.contains(i + 1) { select(targets[i + 1]) }
                LookoutHub.animate { item.state.isOpen ? store.discard(item) : store.restore(item) }
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

    /// The controls menu has the keyboard (DESIGN.md 4.7): ↑↓ walk its rows, Return or Space does the picked one.
    private func menuKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.isEmpty else { return false }
        let rows = ControlsRow.listed(store)
        switch Int(event.keyCode) {
        case kVK_DownArrow, kVK_UpArrow:
            // Round, as NSMenu's.
            let i = rows.firstIndex(of: hub.menuPick) ?? 0
            hub.menuPick = rows[(i + (Int(event.keyCode) == kVK_DownArrow ? 1 : rows.count - 1)) % rows.count]
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            hub.perform(hub.menuPick, store: store)
        default:
            return false
        }
        return true
    }

    /// Esc: the menu goes, and the keyboard goes back to where it was.
    private func closeMenu() {
        hub.section = nil
        onClose()
    }

    /// What a ⌘-digit asks of the section focus: a section, or nil for ⌘0. Outer nil: not a focus key.
    private static func focusKey(_ keyCode: UInt16) -> HubSection?? {
        switch Int(keyCode) {
        case kVK_ANSI_1: .some(.inbox)
        case kVK_ANSI_2: .some(.ci)
        case kVK_ANSI_3: .some(.agents)
        case kVK_ANSI_0: .some(nil)
        default: nil
        }
    }

    /// Every row the arrows walk through, top to bottom: inbox items, then sessions; only those of the sections that
    /// are showing (a focused section hides the others' rows).
    func targets() -> [String] {
        (hub.shows(.inbox) ? store.hubItems(hub).map { "i:" + $0.id } : [])
            + (hub.shows(.agents) ? store.hubSessions(hub).map { "a:" + $0.id } : [])
    }

    /// After the focus moved by key: with the pick gone from view, the focused section's first row is the pick, so the
    /// keys keep working where you are.
    private func rehome() {
        guard hub.selection == nil, hub.focus != nil, let first = targets().first else { return }
        select(first)
    }

    /// A new search picks its first result, so ↩ opens it straight away.
    private func setQuery(_ query: String) {
        LookoutHub.animate {
            hub.query = query
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
