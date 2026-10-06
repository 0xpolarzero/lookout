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
        hub.endSearch()
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
        // What a field or overlay has open (a token, suggestions, a tooltip) is the first thing Esc closes, the search field's
        // focus included: a tooltip over a picked result goes before the query does.
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty, EscapeRoute.run() { return true }
        if hub.inbox.searchFocused, hub.page == .main, let handled = searchKey(event) { return handled }
        // A focused control (Clear, More, Undo) takes Space and Return: they are not the search's or the row's.
        if hub.controls.isActive, flags.isEmpty,
           [kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) { return false }
        let editing = event.window?.firstResponder is NSText
        let shortcut = Shortcut(event)
        // A field keeps what it types, and the chords it has no use for stay the hub's: Settings, Check now, the focus keys.
        if editing, event.keyCode != UInt16(kVK_Escape) { return chord(event, flags: flags, shortcut: shortcut, editing: true) }
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            // The Esc ladder, first match wins: what a field or overlay has open (above), the field itself, the controls
            // menu, the search, the page, the focused section, then the hub.
            if editing { event.window?.makeFirstResponder(nil) }
            else if hub.menuKeys, !hub.expanded { closeMenu() }
            // The search is only on the main view: a query left behind a page is not the next thing to clear.
            else if hub.page == .main, !hub.query.isEmpty || hub.inbox.searchOpen { setQuery("") }
            else if hub.page != .main { hub.back() }
            else if hub.focus != nil { LookoutHub.animate(LookoutHub.refocus) { hub.focus = nil } }
            else { close() }
            return true
        }
        // What the user bound comes first, even ⌘Z and the hub's own chords (⌘1, ⌘F, ⌘,): they are what is left of the key
        // when the action has nothing to act on (no row picked), as undo is.
        if isBound(shortcut), act(event, flags: flags, shortcut: shortcut) { return true }
        if chord(event, flags: flags, shortcut: shortcut) { return true }
        if act(event, flags: flags, shortcut: shortcut) { return true }
        return flags == .command && event.charactersIgnoringModifiers == "z" && store.undoLast()
    }

    /// Whether an in-hub action (not a global one) is bound to `shortcut`.
    func isBound(_ shortcut: Shortcut) -> Bool {
        ShortcutAction.allCases.contains { !$0.isGlobal && store.shortcut($0) == shortcut }
    }

    /// The hub's chords, which a text field has no use for and so doesn't keep: ⌘, ⌘R (and a Check now bound to another
    /// chord, never to a plain key, which the field would type) and ⌘1, ⌘2, ⌘3, ⌘0. False when the key is none of them.
    private func chord(_ event: NSEvent, flags: NSEvent.ModifierFlags, shortcut: Shortcut, editing: Bool = false) -> Bool {
        if flags == .command, event.charactersIgnoringModifiers == "," {
            hub.go(.settings)
            return true
        }
        if shortcut == store.shortcut(.refresh), !editing || shortcut.hasCommandLikeModifier { store.refreshNow(); return true }
        return focusChord(event, flags: flags)
    }

    /// ⌘1, ⌘2, ⌘3 give the Inbox, CI or Sessions all the room (again: back); ⌘0 gives every section its room back.
    /// By key position, so they hold on an AZERTY keyboard, where the digits are shifted.
    private func focusChord(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags == .command, hub.expanded, hub.page == .main, let focus = Self.focusKey(event.keyCode) else { return false }
        if let section = focus { hub.toggleFocus(section) } else if hub.focus != nil { LookoutHub.animate(LookoutHub.refocus) { hub.focus = nil } }
        rehome()
        return true
    }

    /// The configured actions, and the typing that searches. False when the key is none of them.
    private func act(_ event: NSEvent, flags: NSEvent.ModifierFlags, shortcut: Shortcut) -> Bool {
        // ← and → switch the Settings pane that is open.
        if hub.page == .settings, flags.isEmpty, let step = Self.horizontalStep(event.keyCode) {
            switchPane(by: step)
            return true
        }
        if hub.menuKeys, !hub.expanded { return menuKey(event, flags: flags) }
        guard hub.expanded, hub.page == .main else { return false }
        let bound = isBound(shortcut)
        // Typing searches: letters and digits start it, Space and ⌫ edit it once it has started (⌫ is a focused control's
        // while the ring is on one: Clear, More).
        if event.keyCode == UInt16(kVK_Delete), flags.isEmpty, !hub.query.isEmpty, !hub.controls.isActive {
            setQuery(String(hub.query.dropLast()))
            return true
        }
        let targets = targets()
        // A configured action comes before the arrows' own meaning: Right bound to "Mark read / unread" does that.
        if [kVK_DownArrow, kVK_UpArrow].contains(Int(event.keyCode)), flags.isEmpty, !bound {
            // The arrows walk the rows, so a control the Tab ring was on lets go: Space and Return are the pick's again.
            if hub.controls.isActive { event.window?.makeFirstResponder(nil) }
            move(down: Int(event.keyCode) == kVK_DownArrow, in: targets)
            return true
        }
        if flags.isEmpty, !bound, let step = Self.horizontalStep(event.keyCode), horizontal(step, in: targets, event: event, shortcut: shortcut) { return true }
        // Check now needs no row, so a plain letter bound to it is its own and not the search's.
        if shortcut == store.shortcut(.refresh) { store.refreshNow(); return true }
        // Not over rows the list isn't showing (a sign-in problem replaces it, a focused section hides the inbox).
        if shortcut == store.shortcut(.markAllRead), hub.shows(.inbox) {
            if store.inboxReplacement == nil { LookoutHub.animate { store.markAllRead(hub.filter) } }
            return true
        }
        if rowCommand(shortcut, targets: targets, event: event, flags: flags) { return true }
        // The menu key's chords are the last of the keys' own meanings: one bound to an action is that action's.
        if Self.opensRowMenu(event, flags: flags) { return openRowMenu() }
        // What no action took: ⌘F, and typing, which starts the search (a letter someone bound to an action is that action's,
        // while a row is picked to act on).
        if searchChord(event, flags: flags) { return true }
        if flags.subtracting(.shift).isEmpty, let typed = Self.printable(event), !(typed == " " && hub.query.isEmpty) {
            setQuery(hub.query + typed)
            return true
        }
        return false
    }

    /// What a key types, when it is printable text (not a control character or a function key).
    private static func printable(_ event: NSEvent) -> String? {
        guard let typed = event.characters, !typed.isEmpty,
              typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return nil }
        return typed
    }

    /// ⌘F: starts the search.
    private func searchChord(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags == .command, event.charactersIgnoringModifiers == "f" else { return false }
        hub.beginSearch()
        return true
    }

    /// What the bound actions do to the row that is picked. Row commands act only on a row the lists show: a pick the search
    /// has since filtered out, or one in a section that shrank, is not one. False when `shortcut` is none of them.
    private func rowCommand(_ shortcut: Shortcut, targets: [String], event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        // A control the Tab ring is on is the one being driven: the keys are not the picked row's meanwhile.
        guard !hub.controls.isActive, let selection = hub.selection, targets.contains(selection) else { return false }
        let id = String(selection.dropFirst(2))
        if selection.hasPrefix("i:"), let item = store.items.first(where: { $0.id == id }) {
            if shortcut == store.shortcut(.openItem) { store.open(item) }
            else if shortcut == store.shortcut(.toggleRead) { item.state == .unread ? store.markRead(item) : store.markUnread(item) }
            else if shortcut == store.shortcut(.discard) {
                if let next = Self.neighbour(of: selection, in: targets) { select(next) }
                LookoutHub.animate { item.state.isOpen ? store.done(item) : store.restore(item) }
            } else { return false }
            return true
        }
        if selection.hasPrefix("c:") { return ciKey(event, id: id, flags: flags, shortcut: shortcut) }
        // The list's own rows ("+N more", New session).
        if selection.hasPrefix("s:") {
            guard shortcut == store.shortcut(.openItem) else { return false }
            hub.activateSessionTarget(selection, store: store, ui: ui)
            return true
        }
        if selection.hasPrefix("a:") {
            if shortcut == store.shortcut(.openItem) { store.openAgent(id) }
            else if shortcut == store.shortcut(.toggleRead) { store.toggleAgentRead(id) }
            else if shortcut == store.shortcut(.keepSession) { LookoutHub.animate { store.keepAgent(id) } }
            else if shortcut == store.shortcut(.removeSession) {
                LookoutHub.animate { store.dismissAgent(id) }
                // A row that left the list takes the pick to its neighbour (one search shows hidden stays, and keeps it).
                if !self.targets().contains(selection), let next = Self.neighbour(of: selection, in: targets) { select(next) }
            }
            else if shortcut == store.shortcut(.moveSessionUp) || shortcut == store.shortcut(.moveSessionDown) {
                let step = shortcut == store.shortcut(.moveSessionUp) ? -1 : 1
                // The row keeps the pick wherever it lands, and the list follows it.
                if hub.canMoveSession(id, by: step, store: store) {
                    LookoutHub.animate { hub.moveSession(id, by: step, store: store) }
                    select(selection)
                }
            } else { return false }
            return true
        }
        return false
    }

    /// The row the pick moves to when its own goes (Done, Hide): the one after it, or the one before at the end of the list.
    private static func neighbour(of selection: String, in targets: [String]) -> String? {
        guard let i = targets.firstIndex(of: selection) else { return nil }
        return targets.indices.contains(i + 1) ? targets[i + 1] : i > 0 ? targets[i - 1] : nil
    }

    /// The Menu key, ⇧F10 and ⌃Return: the row's context menu, as the right button opens it.
    private static func opensRowMenu(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        switch Int(event.keyCode) {
        case kVK_ContextualMenu: flags.isEmpty
        case kVK_F10: flags == .shift
        case kVK_Return, kVK_ANSI_KeypadEnter: flags == .control
        default: false
        }
    }

    /// The picked row's context menu (the Menu key, ⇧F10 or ⌃Return): every row with one has the same actions in it for
    /// the mouse and the keyboard. False with no row picked, or one that has none (Passing, "+N more", New session), and
    /// while the Tab ring is on a control, which is the one being driven.
    private func openRowMenu() -> Bool {
        guard !hub.controls.isActive, let selection = hub.selection, targets().contains(selection), selection != "c:passing",
              ["i:", "c:", "a:"].contains(String(selection.prefix(2))) else { return false }
        hub.openRowMenu(selection)
        return true
    }

    /// ← is -1 and → is +1; nil for any other key.
    private static func horizontalStep(_ keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case kVK_LeftArrow: -1
        case kVK_RightArrow: 1
        default: nil
        }
    }

    /// ← and → on the main view: a picked row that has its own meaning for them keeps it (Passing opens and closes, New
    /// session's → shows the projects); anything else, with no query to move through, switches the inbox's tab. A pick
    /// outside the inbox survives the switch, which would otherwise take it with the tab's rows.
    private func horizontal(_ step: Int, in targets: [String], event: NSEvent, shortcut: Shortcut) -> Bool {
        if let selection = hub.selection, targets.contains(selection) {
            if selection.hasPrefix("c:"), ciKey(event, id: String(selection.dropFirst(2)), flags: [], shortcut: shortcut) { return true }
            if selection == "s:new", step > 0 {
                hub.openProjectsMenu()
                return true
            }
        }
        guard hub.query.isEmpty, hub.shows(.inbox) else { return false }
        let all = InboxFilter.allCases
        let next = all.firstIndex(of: hub.filter)! + step
        guard all.indices.contains(next) else { return true }
        let kept = hub.selection.flatMap { $0.hasPrefix("i:") ? nil : ($0, hub.keyboardSelection) }
        LookoutHub.animate { hub.filter = all[next] }
        if let (selection, scroll) = kept { (hub.selection, hub.keyboardSelection) = (selection, scroll) }
        return true
    }

    /// ← and → on Settings: the pane before or after the open one, none past the ends.
    private func switchPane(by step: Int) {
        let all = SettingsPane.allCases
        let next = all.firstIndex(of: hub.settingsPane)! + step
        if all.indices.contains(next) { LookoutHub.animate { hub.settingsPane = all[next] } }
    }

    /// The controls menu has the keyboard (DESIGN.md 4.7): ↑↓ walk its rows, Return or Space does the picked one.
    private func menuKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.isEmpty else { return false }
        let rows = ControlsRow.listed(store)
        switch Int(event.keyCode) {
        case kVK_DownArrow, kVK_UpArrow:
            // Round, as NSMenu's.
            let i = rows.firstIndex(of: hub.menuPick) ?? 0
            // One highlight: the ring Tab had put on a row goes, so Space does what the highlighted row says.
            event.window?.makeFirstResponder(nil)
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

    /// Every row the arrows walk through, top to bottom: inbox items, CI, then sessions, then the list's own rows; only
    /// those on screen (a focused section shrinks the others).
    func targets() -> [String] {
        (store.hubTargets(hub) + store.sessionExtraTargets(hub)).filter(hub.isVisible)
    }

    private func move(down: Bool, in targets: [String]) {
        let i = targets.firstIndex(of: hub.selection ?? "") ?? (down ? -1 : targets.count)
        let next = min(max(i + (down ? 1 : -1), 0), targets.count - 1)
        if targets.indices.contains(next) { select(targets[next]) }
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
        !Shortcut(event).hasCommandLikeModifier && Self.printable(event) != nil
    }
}
