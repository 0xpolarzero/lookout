import AppKit
import Carbon
import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct Shortcuts {
    private func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                         keyCode: UInt16(code))!
    }

    @Test func eventMatchesByKeyPositionAndModifiers() {
        #expect(Shortcut(key(kVK_Space)) == ShortcutAction.toggleRead.defaultShortcut)
        #expect(Shortcut(key(kVK_Space, [.option])) == ShortcutAction.markAllRead.defaultShortcut)
        #expect(Shortcut(key(kVK_Space, [.option])) != ShortcutAction.toggleRead.defaultShortcut)
        // Caps lock / fn don't change what was pressed.
        #expect(Shortcut(key(kVK_ANSI_R, [.command, .capsLock, .function])) == ShortcutAction.refresh.defaultShortcut)
    }

    @Test func displayUsesSymbols() {
        #expect(ShortcutAction.togglePanel.defaultShortcut.display.hasPrefix("⌃⌥"))
        #expect(ShortcutAction.discard.defaultShortcut.display == "⌫")
        #expect(ShortcutAction.markAllRead.defaultShortcut.display == "⌥Space")
    }

    @Test func customizeAndReset() {
        let store = Store()
        store.persists = false
        var registered: Shortcut?
        store.onGlobalShortcutChange = { registered = $0 }
        let custom = Shortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.control, .command])
        store.setShortcut(custom, for: .togglePanel)
        #expect(store.shortcut(.togglePanel) == custom)
        #expect(registered == custom)
        store.setShortcut(nil, for: .togglePanel)
        #expect(store.shortcut(.togglePanel) == ShortcutAction.togglePanel.defaultShortcut)
        #expect(store.settings.shortcuts == nil)
    }

    @Test func oldSettingsStillLoad() throws {
        let old = #"{"botHandles":[],"treatAppsAsBots":true,"pollInterval":60,"notifications":true,"reviewRequests":true,"didInitialReviewSync":true}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(settings.shortcuts == nil)
    }
}
