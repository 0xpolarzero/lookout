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

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

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

enum ShortcutAction: String, CaseIterable, Identifiable {
    case togglePanel, openItem, toggleRead, discard, markAllRead, refresh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePanel: "Show / hide panel"
        case .openItem: "Open on GitHub"
        case .toggleRead: "Mark read / unread"
        case .discard: "Discard / back to inbox"
        case .markAllRead: "Mark all as read"
        case .refresh: "Refresh now"
        }
    }

    /// Works from any app (registered system-wide) rather than only while the panel has focus.
    var isGlobal: Bool { self == .togglePanel }

    var defaultShortcut: Shortcut {
        switch self {
        case .togglePanel: Shortcut(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .option])
        case .openItem: Shortcut(keyCode: UInt16(kVK_Return))
        case .toggleRead: Shortcut(keyCode: UInt16(kVK_Space))
        case .discard: Shortcut(keyCode: UInt16(kVK_Delete))
        case .markAllRead: Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.option])
        case .refresh: Shortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [.command])
        }
    }
}

/// Click, then press the new combination. Esc cancels.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    let store: Store
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?
    @State private var hover = false

    var body: some View {
        let current = store.shortcut(action)
        let customized = current != action.defaultShortcut
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                if customized && !recording {
                    Button { store.setShortcut(nil, for: action) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
                    .tip("Reset", "Back to \(action.defaultShortcut.display)")
                }
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "Press keys…" : current.display)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(recording ? Theme.accent : Theme.text)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 70, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover || recording ? 0.1 : 0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Theme.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
            }
            if let error {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Theme.amber)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        error = nil
        recording = true
        store.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let shortcut = Shortcut(event)
            if event.keyCode == UInt16(kVK_Escape) && shortcut.flags.isEmpty {
                stop()
            } else if action.isGlobal && !shortcut.hasCommandLikeModifier {
                error = "Use ⌃, ⌥ or ⌘ for a shortcut that works everywhere"
            } else if let other = ShortcutAction.allCases.first(where: { $0 != action && store.shortcut($0) == shortcut }) {
                error = "Already used for \(other.title)"
            } else {
                store.setShortcut(shortcut, for: action)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        store.isRecordingShortcut = false
    }
}
