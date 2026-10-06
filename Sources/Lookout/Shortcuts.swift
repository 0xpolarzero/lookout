import AppKit
import Carbon
import SwiftUI

/// A key combination, stored by physical key position (key code) so it keeps working when the keyboard
/// layout changes; it is *displayed* with the current layout's label.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt   // NSEvent.ModifierFlags raw value, limited to ⌃⌥⇧⌘

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
    }

    init(_ event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var hasCommandLikeModifier: Bool { !flags.intersection([.control, .option, .command]).isEmpty }

    var carbonModifiers: UInt32 {
        var m: Int = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    /// Mouse buttons past the left and right ones (a mouse's side buttons), stored as key codes from here on, so
    /// a shortcut is a key, a modifier tap or a button, held with modifiers or not.
    static let mouseBase: UInt16 = 0x1000

    static func mouse(_ button: Int, modifiers: NSEvent.ModifierFlags = []) -> Shortcut {
        Shortcut(keyCode: mouseBase + UInt16(button), modifiers: modifiers)
    }

    /// NSEvent's button number: 2 is the middle button, 3 and 4 the side ones (back, forward).
    var mouseButton: Int? { keyCode >= Self.mouseBase ? Int(keyCode - Self.mouseBase) : nil }

    /// A shortcut that was cleared: no key produces this code, so it never matches and nothing is registered for it.
    static let unassigned = Shortcut(keyCode: 0x0FFF)
    var isUnassigned: Bool { keyCode == Self.unassigned.keyCode }

    var display: String {
        if isUnassigned { return "None" }
        if let tap = Self.tapKeys[keyCode] { return tap.name }
        if let button = mouseButton {
            let name = switch button {
            case 2: "Middle click"
            case 3: "Mouse back"
            case 4: "Mouse forward"
            default: "Mouse button \(button + 1)"
            }
            return modifierSymbols + name
        }
        return modifierSymbols + Self.keyName(keyCode)
    }

    private var modifierSymbols: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    /// Modifier keys that work as a shortcut tapped on their own, by side: key code → device-dependent flag bit.
    static let tapKeys: [UInt16: (bit: UInt, name: String)] = [
        59: (0x01, "Left ⌃"), 62: (0x2000, "Right ⌃"),
        58: (0x20, "Left ⌥"), 61: (0x40, "Right ⌥"),
        55: (0x08, "Left ⌘"), 54: (0x10, "Right ⌘"),
    ]
    /// Device-dependent bits of every sided ⌃⌥⇧⌘ key.
    static let sideBits: UInt = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000

    /// A lone modifier tap (e.g. right ⌘) rather than a key combination.
    var isModifierTap: Bool { Self.tapKeys[keyCode] != nil }

    private static let named: [UInt16: String] = [
        36: "Return", 76: "Enter", 48: "Tab", 49: "Space", 51: "⌫", 117: "⌦", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// The character a printable key types in the current layout, lowercased; nil for a named key or one with no character.
    static func character(_ code: UInt16) -> Character? {
        guard named[code] == nil, case let name = keyName(code).lowercased(), name.count == 1 else { return nil }
        return name.first
    }

    /// Label of a key in the current keyboard layout (so ⌃⌥L shows as such on AZERTY too).
    static func keyName(_ code: UInt16) -> String {
        if let name = named[code] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Recognizes a single modifier key pressed and released on its own: no other modifier held and no key,
/// click or scroll in between (so right ⌘ + C never counts as a right ⌘ tap).
struct ModifierTap {
    private var candidate: UInt16?

    /// Feed a flagsChanged event; returns the key code of a completed tap.
    mutating func flagsChanged(keyCode: UInt16, flags: UInt) -> UInt16? {
        let held = flags & Shortcut.sideBits
        if held == 0 {
            defer { candidate = nil }
            return candidate == keyCode ? candidate : nil
        }
        candidate = Shortcut.tapKeys[keyCode]?.bit == held ? keyCode : nil
        return nil
    }

    /// Anything else happened while the modifier was down.
    mutating func interrupt() { candidate = nil }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case togglePanel, sessionSwitcher, openItem, toggleRead, discard, markAllRead, refresh, keepSession, removeSession,
         moveSessionUp, moveSessionDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePanel: "Keep open"
        case .openItem: "Open on GitHub"
        case .toggleRead: "Mark read / unread"
        case .discard: "Done / Restore"
        case .markAllRead: "Mark all as read"
        case .refresh: "Check now"
        case .sessionSwitcher: "Open on sessions"
        case .keepSession: "Keep a session"
        case .removeSession: "Hide a session"
        case .moveSessionUp: "Move a session up in its project"
        case .moveSessionDown: "Move a session down in its project"
        }
    }

    /// Works from any app (registered system-wide) rather than only while the panel has focus.
    var isGlobal: Bool { self == .togglePanel || self == .sessionSwitcher }

    /// Only meaningful with the Claude sessions extension on.
    var isAgents: Bool {
        [.sessionSwitcher, .keepSession, .removeSession, .moveSessionUp, .moveSessionDown].contains(self)
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .togglePanel: Shortcut(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .option])
        case .openItem: Shortcut(keyCode: UInt16(kVK_Return))
        case .toggleRead: Shortcut(keyCode: UInt16(kVK_Space))
        case .discard: Shortcut(keyCode: UInt16(kVK_Delete))
        case .markAllRead: Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.option])
        case .refresh: Shortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [.command])
        case .sessionSwitcher: Shortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: [.control, .option])
        case .keepSession: Shortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
        // ⌘⌫ rather than a bare ⌫: removing a session is easy to hit by accident and awkward to undo.
        case .removeSession: Shortcut(keyCode: UInt16(kVK_Delete), modifiers: [.command])
        case .moveSessionUp: Shortcut(keyCode: UInt16(kVK_UpArrow), modifiers: [.option])
        case .moveSessionDown: Shortcut(keyCode: UInt16(kVK_DownArrow), modifiers: [.option])
        }
    }
}

extension Store {
    var hasCustomShortcuts: Bool { !(settings.shortcuts ?? [:]).isEmpty }

    /// The action that already holds `shortcut`, which `action` can't take as well.
    func shortcutConflict(_ shortcut: Shortcut, for action: ShortcutAction) -> ShortcutAction? {
        guard !shortcut.isUnassigned else { return nil }
        return ShortcutAction.allCases.first { $0 != action && self.shortcut($0) == shortcut }
    }

    /// Back to the default, unless another action has taken that key since (the reset would give both the same key, and the
    /// system would drop one of them) or another app has. Returns what stood in the way, with nothing changed.
    @discardableResult
    func resetShortcut(for action: ShortcutAction) -> ShortcutRefusal? {
        if let other = shortcutConflict(action.defaultShortcut, for: action) { return .usedBy(other) }
        return setShortcut(nil, for: action)
    }

    /// Every shortcut back to its default. The global ones are unregistered first and registered again after: with
    /// the two swapped, registering one default while the other still holds its key would be refused, and Settings
    /// would show a default that does nothing. If another app holds one of the defaults nothing changes: what was
    /// registered is registered again, every setting stays as it was, and the refusal is returned.
    @discardableResult
    func restoreDefaultShortcuts() -> ShortcutRefusal? {
        let globals = ShortcutAction.allCases.filter(\.isGlobal)
        let before = settings.shortcuts
        let held = globals.map { ($0, shortcut($0)) }
        for action in globals { _ = onGlobalShortcutChange?(action, .unassigned) }
        settings.shortcuts = nil
        var refused: Shortcut?
        for action in globals where onGlobalShortcutChange?(action, shortcut(action)) == false { refused = refused ?? action.defaultShortcut }
        guard let refused else { return nil }
        for action in globals { _ = onGlobalShortcutChange?(action, .unassigned) }
        settings.shortcuts = before
        for (action, shortcut) in held { _ = onGlobalShortcutChange?(action, shortcut) }
        return .defaultUnavailable(refused)
    }
}

/// Why a shortcut wasn't taken: the sentence under its recorder, which says so aloud too.
enum ShortcutRefusal: Equatable {
    case usedBy(ShortcutAction)
    /// Another app holds a system-wide key: Lookout keeps the one it had.
    case unavailable(Shortcut)
    /// Restore defaults found one of the defaults held by another app: nothing was restored.
    case defaultUnavailable(Shortcut)

    var message: String {
        switch self {
        case .usedBy(let other): "Already used by \(other.title)"
        case .unavailable(let shortcut): "\(shortcut.display) is used by another app. Lookout keeps the old shortcut"
        case .defaultUnavailable(let shortcut): "\(shortcut.display) is used by another app. Lookout keeps your shortcuts"
        }
    }
}

/// Where a system-wide shortcut is registered: `HotKeys`, or a stand-in under test.
protocol HotKeyRegistrar: AnyObject {
    /// `nil` unregisters. A shortcut that can't be registered is refused (`false`), and what `id` held stays held.
    @discardableResult
    func set(_ id: UInt32, _ shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool
}

extension HotKeys: HotKeyRegistrar {}

extension ShortcutAction {
    /// The registration a global action holds, one per action.
    var hotKeyID: UInt32 { self == .togglePanel ? 1 : 2 }
}

/// Keeps the registrar in step with the store's global shortcuts: one registration per action, none for a shortcut
/// that was cleared, and the session switcher only while the Claude extension is on.
@MainActor
final class GlobalShortcuts {
    private let store: Store
    private let registrar: HotKeyRegistrar
    private let perform: (ShortcutAction) -> Void

    /// `perform` runs on the main queue when a global shortcut is pressed.
    init(store: Store, registrar: HotKeyRegistrar, perform: @escaping (ShortcutAction) -> Void) {
        self.store = store
        self.registrar = registrar
        self.perform = perform
    }

    /// Registers both and follows the store from here on. A key another app already holds is said once, here: at launch
    /// nothing else tells anyone it does nothing.
    func start() {
        for action in ShortcutAction.allCases where action.isGlobal && !register(action) { announceRefusal(action) }
        store.onGlobalShortcutChange = { [weak self] action, shortcut in self?.register(action, shortcut) ?? true }
        store.onAgentsEnabledChange = { [weak self] _ in
            guard let self, !self.register(.sessionSwitcher) else { return }
            // Turning the extension on is what registers it, and nothing on screen says it did not take: the recorder only does
            // in Settings.
            self.announceRefusal(.sessionSwitcher)
        }
    }

    private func announceRefusal(_ action: ShortcutAction) {
        Announce.say("\(action.title): \(store.shortcut(action).display) is used by another app, so it does nothing")
    }

    /// `shortcut` is what the store has just set, or its current one. `false` when the system refused it, which the store
    /// keeps (`refusedShortcuts`): a key refused at launch, or when the extension turns on, is not one the user just chose.
    @discardableResult
    func register(_ action: ShortcutAction, _ shortcut: Shortcut? = nil) -> Bool {
        guard action.isGlobal else { return true }
        let shortcut = shortcut ?? store.shortcut(action)
        let wanted = action == .sessionSwitcher && !store.agents.enabled ? nil : shortcut
        let taken = registrar.set(action.hotKeyID, wanted.flatMap { $0.isUnassigned ? nil : $0 }) { [perform] in
            DispatchQueue.main.async { perform(action) }
        }
        store.refusedShortcuts[action] = taken ? nil : shortcut
        return taken
    }
}

/// Click, then press the new combination. Esc cancels, Delete clears. The Reset slot is always there (empty until
/// the shortcut differs from its default) so the keys line up down a list.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    let store: Store
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?
    @State private var tap = ModifierTap()
    @Environment(\.pagePreview) private var preview

    var body: some View {
        let current = store.shortcut(action)
        let customized = current != action.defaultShortcut
        // What was said at the last attempt, else the key another app holds: it is stored and does nothing.
        let held = store.isShortcutHeldByAnotherApp(action) ? "\(current.display) is used by another app, so it does nothing" : nil
        let shown = error ?? held
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                if customized && !recording {
                    IconButton(symbol: "arrow.uturn.backward", help: "Reset", label: "Reset \(action.title) to default",
                               detail: "Back to \(action.defaultShortcut.display)") {
                        refuse(store.resetShortcut(for: action)?.message)
                    }
                } else {
                    Color.clear.frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
                }
                Button { recording ? stop() : start() } label: { RecorderLabel(shortcut: current, recording: recording) }
                    .buttonStyle(HoverFillButtonStyle(shape: Theme.Radius.shape(Theme.Radius.tile), rest: Theme.Fill.tile,
                                                      hover: Theme.Fill.selected, isActive: recording))
                    .focusRing(Theme.Radius.tile)
                    .accessibilityLabel("Change shortcut for \(action.title)")
                    .accessibilityValue(recording ? ["Recording, press the new keys", error].compactMap { $0 }.joined(separator: ". ")
                                        : current.isUnassigned ? "Not set" : [current.display, held].compactMap { $0 }.joined(separator: ". "))
                    .accessibilityHint("Delete clears it, Escape cancels")
            }
            if let shown {
                Text(shown).font(Theme.Typography.meta).foregroundStyle(Theme.red)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    // Wider than the keycap it sits under, so a conflict reads on two lines at most.
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .onAppear {
            // A screenshot's recorder: waiting for keys (no monitor), with the error it was showing.
            guard preview.recording == action else { return }
            recording = true
            error = preview.recorderError
        }
        .onChange(of: current) { error = nil }
        .onDisappear(perform: stop)
    }

    private struct RecorderLabel: View {
        let shortcut: Shortcut
        let recording: Bool
        @Environment(\.resolved) private var resolved

        var body: some View {
            Text(recording ? "Press keys…" : shortcut.display)
                .font(Theme.Typography.control)
                .foregroundStyle(!recording && shortcut.isUnassigned ? AnyShapeStyle(Theme.secondary) : AnyShapeStyle(Theme.text))
                .padding(.horizontal, Theme.Space.lg)
                .frame(minWidth: 76, minHeight: Theme.Metrics.button)
                .overlay(Theme.Radius.shape(Theme.Radius.tile)
                    .strokeBorder(recording ? Theme.accent : Theme.fieldBorder, lineWidth: recording ? resolved.focusWidth : resolved.borderWidth))
        }
    }

    private func start() {
        store.recorder?.stop()
        error = nil
        recording = true
        store.recorder = (action, stop)
        tap = ModifierTap()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            if event.type == .otherMouseDown {
                // A mouse's side (or middle) button, for the shortcuts that work everywhere.
                if action.isGlobal {
                    accept(Shortcut.mouse(event.buttonNumber, modifiers: event.modifierFlags))
                } else {
                    refuse("Mouse buttons work for the shortcuts that work from any app")
                }
                return nil
            }
            if event.type == .flagsChanged {
                // A lone modifier tap needs the system-wide detector, so only global shortcuts accept it.
                if action.isGlobal, let key = tap.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) {
                    accept(Shortcut(keyCode: key))
                }
                return event
            }
            tap.interrupt()
            let shortcut = Shortcut(event)
            if event.keyCode == UInt16(kVK_Escape) && shortcut.flags.isEmpty {
                stop()
            } else if event.keyCode == UInt16(kVK_Delete) && shortcut.flags.isEmpty {
                store.setShortcut(.unassigned, for: action)
                stop()
            } else if action.isGlobal && !shortcut.hasCommandLikeModifier {
                refuse("Use ⌃, ⌥ or ⌘, or tap one of them alone, for a shortcut that works everywhere")
            } else {
                accept(shortcut)
            }
            return nil
        }
    }

    /// A conflict or a refusal appears under the key and is said at each attempt, a repeated one too (WCAG 4.1.3).
    private func refuse(_ message: String?) {
        error = message
        if let message { Announce.say(message) }
    }

    private func accept(_ shortcut: Shortcut) {
        if let other = store.shortcutConflict(shortcut, for: action) {
            refuse(ShortcutRefusal.usedBy(other).message)
        } else if let refusal = store.setShortcut(shortcut, for: action) {
            refuse(refusal.message)
        } else {
            stop()
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        if store.recorder?.action == action { store.recorder = nil }
    }
}
