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
        #expect(ShortcutAction.removeSession.defaultShortcut.display == "⌘⌫")
        #expect(ShortcutAction.markAllRead.defaultShortcut.display == "⌥Space")
    }

    @Test func modifierTapRecognizesALoneSidedKey() {
        let rightCmd: UInt = 0x10 | NSEvent.ModifierFlags.command.rawValue
        let leftCmd: UInt = 0x08 | NSEvent.ModifierFlags.command.rawValue
        var tap = ModifierTap()
        #expect(tap.flagsChanged(keyCode: 54, flags: rightCmd) == nil)
        #expect(tap.flagsChanged(keyCode: 54, flags: 0) == 54)
        // Left ⌘ is a different key.
        #expect(tap.flagsChanged(keyCode: 55, flags: leftCmd) == nil)
        #expect(tap.flagsChanged(keyCode: 55, flags: 0) == 55)
        // Right ⌘ + C is a combination, not a tap.
        _ = tap.flagsChanged(keyCode: 54, flags: rightCmd)
        tap.interrupt()
        #expect(tap.flagsChanged(keyCode: 54, flags: 0) == nil)
        // Both ⌘ keys held together is not a tap either.
        _ = tap.flagsChanged(keyCode: 54, flags: rightCmd)
        _ = tap.flagsChanged(keyCode: 55, flags: rightCmd | leftCmd)
        _ = tap.flagsChanged(keyCode: 55, flags: rightCmd)
        #expect(tap.flagsChanged(keyCode: 54, flags: 0) == nil)
        // Shift doesn't tap.
        _ = tap.flagsChanged(keyCode: 60, flags: 0x04 | NSEvent.ModifierFlags.shift.rawValue)
        #expect(tap.flagsChanged(keyCode: 60, flags: 0) == nil)
    }

    @Test func modifierTapShortcut() {
        let rightCmd = Shortcut(keyCode: 54)
        #expect(rightCmd.isModifierTap)
        #expect(rightCmd.display == "Right ⌘")
        #expect(!ShortcutAction.sessionSwitcher.defaultShortcut.isModifierTap)
    }

    @Test func customizeAndReset() {
        let store = Store()
        store.persists = false
        var registered: Shortcut?
        store.onGlobalShortcutChange = { _, shortcut in registered = shortcut }
        let custom = Shortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.control, .command])
        store.setShortcut(custom, for: .togglePanel)
        #expect(store.shortcut(.togglePanel) == custom)
        #expect(registered == custom)
        store.setShortcut(nil, for: .togglePanel)
        #expect(store.shortcut(.togglePanel) == ShortcutAction.togglePanel.defaultShortcut)
        #expect(store.settings.shortcuts == nil)
    }

    @Test func hotKeysAreReleasedWhileSuspended() {
        let hotKeys = HotKeys()
        // An unlikely combination, so the test never fights a real shortcut for it.
        hotKeys.set(90, Shortcut(keyCode: UInt16(kVK_F19), modifiers: [.control, .option, .command, .shift])) {}
        defer { hotKeys.set(90, nil) }
        #expect(hotKeys.registeredIDs == [90])
        hotKeys.isSuspended = true
        #expect(hotKeys.registeredIDs.isEmpty)
        // A change made meanwhile applies on resume.
        hotKeys.set(90, Shortcut(keyCode: UInt16(kVK_F18), modifiers: [.control, .option, .command, .shift])) {}
        #expect(hotKeys.registeredIDs.isEmpty)
        hotKeys.isSuspended = false
        #expect(hotKeys.registeredIDs == [90])
        hotKeys.set(90, nil)
        hotKeys.isSuspended = true
        hotKeys.isSuspended = false
        #expect(hotKeys.registeredIDs.isEmpty)
    }

    @Test func startingARecorderStopsTheOneListening() {
        let store = Store()
        store.persists = false
        var changes: [Bool] = []
        store.onRecordingShortcutChange = { changes.append($0) }
        var firstStopped = false
        store.beginRecordingShortcut {
            firstStopped = true
            store.endRecordingShortcut()
        }
        #expect(store.isRecordingShortcut)
        store.beginRecordingShortcut { store.endRecordingShortcut() }
        #expect(firstStopped)
        #expect(store.isRecordingShortcut)
        // Released once the first stopped, then held again for the second.
        #expect(changes == [true, false, true])
        store.endRecordingShortcut()
        #expect(!store.isRecordingShortcut)
    }

    @Test func oldSettingsStillLoad() throws {
        let old = #"{"botHandles":[],"treatAppsAsBots":true,"pollInterval":60,"notifications":true,"reviewRequests":true,"didInitialReviewSync":true}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(settings.shortcuts == nil)
    }
}
