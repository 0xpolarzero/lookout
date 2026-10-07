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
            let mods = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
            let name = switch button {
            case 2: "Middle click"
            case 3: "Mouse back"
            case 4: "Mouse forward"
            default: "Mouse button \(button + 1)"
            }
            return mods + name
        }
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
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
    case togglePanel, sessionSwitcher, openItem, toggleRead, discard, markAllRead, refresh, keepSession, removeSession

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePanel: "Keep open"
        case .openItem: "Open on GitHub"
        case .toggleRead: "Mark read / unread"
        case .discard: "Done / back to inbox"
        case .markAllRead: "Mark all as read"
        case .refresh: "Refresh now"
        case .sessionSwitcher: "Switch Claude session"
        case .keepSession: "Keep a pending session"
        case .removeSession: "Remove a session"
        }
    }

    /// Works from any app (registered system-wide) rather than only while the panel has focus.
    var isGlobal: Bool { self == .togglePanel || self == .sessionSwitcher }

    /// Only meaningful with the Claude sessions extension on.
    var isAgents: Bool { self == .sessionSwitcher || self == .keepSession || self == .removeSession }

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
        }
    }
}

extension Store {
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
}

/// Why a shortcut wasn't taken: the sentence under its recorder.
enum ShortcutRefusal: Equatable {
    case usedBy(ShortcutAction)
    /// Another app holds a system-wide key: Lookout keeps the one it had.
    case unavailable(Shortcut)

    var message: String {
        switch self {
        case .usedBy(let other): "Already used for \(other.title)"
        case .unavailable(let shortcut): "\(shortcut.display) is used by another app. Lookout keeps the old shortcut"
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

/// Keeps the registrar in step with the store's global shortcuts: one registration per action, and the session
/// switcher only while the Claude extension is on, and none for a shortcut that was cleared.
@MainActor
final class GlobalShortcuts {
    private let store: Store
    private let registrar: HotKeyRegistrar
    private let perform: (ShortcutAction) -> Void
    private let say: (String) -> Void

    /// `perform` runs on the main queue when a global shortcut is pressed; `say` speaks what nothing on screen shows.
    init(store: Store, registrar: HotKeyRegistrar, perform: @escaping (ShortcutAction) -> Void,
         say: ((String) -> Void)? = nil) {
        self.store = store
        self.registrar = registrar
        self.perform = perform
        self.say = say ?? { Announce.say($0) }
    }

    /// Registers both and follows the store from here on.
    func start() {
        for action in ShortcutAction.allCases where action.isGlobal { register(action) }
        store.onGlobalShortcutChange = { [weak self] action, shortcut in self?.register(action, shortcut) ?? true }
        store.onAgentsEnabledChange = { [weak self] _ in
            guard let self, !self.register(.sessionSwitcher) else { return }
            // Turning the extension on is what registers it, and nothing on screen says it did not take: the recorder only
            // does in Settings.
            say("\(ShortcutAction.sessionSwitcher.title): \(store.shortcut(.sessionSwitcher).display) is used by another app, so it does nothing")
        }
    }

    /// `shortcut` is what the store is about to set, or its current one. `false` when the system refused it.
    @discardableResult
    func register(_ action: ShortcutAction, _ shortcut: Shortcut? = nil) -> Bool {
        guard action.isGlobal else { return true }
        let shortcut = shortcut ?? store.shortcut(action)
        let wanted = action == .sessionSwitcher && !store.agents.enabled ? nil : shortcut
        return registrar.set(action.hotKeyID, wanted.flatMap { $0.isUnassigned ? nil : $0 }) { [perform] in
            DispatchQueue.main.async { perform(action) }
        }
    }
}

/// Click, then press the new combination. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    let store: Store
    @State private var recording = false
    @State private var monitor: Any?
    /// The window being recorded in; losing key status there means the keys no longer reach the monitor.
    @State private var window: NSWindow?
    @State private var error: String?
    @State private var tap = ModifierTap()

    var body: some View {
        let current = store.shortcut(action)
        let customized = current != action.defaultShortcut
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            HStack(spacing: 4) {
                if customized && !recording {
                    Button { error = store.resetShortcut(for: action)?.message } label: {
                        Image(systemName: "arrow.uturn.backward").font(Theme.Typography.glyph(9, .bold)).frame(width: 20, height: 20)
                    }
                    .buttonStyle(HoverFillButtonStyle(shape: Circle()))
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityLabel("Reset \(action.title) to default")
                    .tip("Reset", "Back to \(action.defaultShortcut.display)")
                }
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "Press keys…" : current.display)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(recording ? Theme.accent : Theme.text)
                        .padding(.horizontal, Theme.Space.md)
                        .frame(minWidth: 70, minHeight: 22)
                        .overlay(Theme.Radius.shape(Theme.Radius.xs).strokeBorder(recording ? Theme.accent : .clear))
                }
                .buttonStyle(HoverFillButtonStyle(shape: Theme.Radius.shape(Theme.Radius.xs), rest: Theme.Fill.hover,
                                                  hover: Theme.Fill.selected, isActive: recording))
                .accessibilityLabel("Change shortcut for \(action.title)")
                .accessibilityValue(recording ? "Recording, press the new keys" : current.isUnassigned ? "Not set" : current.display)
            }
            if let error {
                Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.amber)
            }
        }
        // A refusal belongs to the key it was about.
        .onChange(of: current) { error = nil }
        .onDisappear(perform: stop)
        // Settings can stay pinned and mounted while another app takes over, so none of the other ways out run.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { leave($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { leave($0) }
    }

    private func leave(_ note: Notification) {
        if let window, note.object as? NSWindow === window { stop() }
    }

    private func start() {
        error = nil
        recording = true
        window = NSApp.keyWindow
        // Stops any other recorder first, and releases the global hotkeys: Carbon would otherwise take a
        // combination like Keep open's before it reaches the monitor below.
        store.beginRecordingShortcut(stop: stop)
        tap = ModifierTap()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            if event.type == .otherMouseDown {
                // A mouse's side (or middle) button, for the shortcuts that work everywhere.
                if action.isGlobal {
                    accept(Shortcut.mouse(event.buttonNumber, modifiers: event.modifierFlags))
                } else {
                    error = "Mouse buttons work for the shortcuts that work from any app"
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
                error = "Use ⌃, ⌥ or ⌘, or tap one of them alone, for a shortcut that works everywhere"
            } else {
                accept(shortcut)
            }
            return nil
        }
    }

    private func accept(_ shortcut: Shortcut) {
        if let other = store.shortcutConflict(shortcut, for: action) {
            error = ShortcutRefusal.usedBy(other).message
        } else if let refusal = store.setShortcut(shortcut, for: action) {
            error = refusal.message
        } else {
            stop()
        }
    }

    private func stop() {
        // A recorder that was already stopped must not end the one that replaced it.
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window = nil
        recording = false
        store.endRecordingShortcut()
    }
}
