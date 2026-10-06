import AppKit
import Carbon
import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct Shortcuts {
    @Test func eventMatchesByKeyPositionAndModifiers() {
        #expect(Shortcut(keyDown(kVK_Space)) == ShortcutAction.toggleRead.defaultShortcut)
        #expect(Shortcut(keyDown(kVK_Space, [.option])) == ShortcutAction.markAllRead.defaultShortcut)
        #expect(Shortcut(keyDown(kVK_Space, [.option])) != ShortcutAction.toggleRead.defaultShortcut)
        // Caps lock / fn don't change what was pressed.
        #expect(Shortcut(keyDown(kVK_ANSI_R, [.command, .capsLock, .function])) == ShortcutAction.refresh.defaultShortcut)
    }

    @Test func displayUsesSymbols() {
        #expect(ShortcutAction.togglePanel.defaultShortcut.display.hasPrefix("⌃⌥"))
        #expect(ShortcutAction.discard.defaultShortcut.display == "⌫")
        #expect(ShortcutAction.removeSession.defaultShortcut.display == "⌘⌫")
        #expect(ShortcutAction.markAllRead.defaultShortcut.display == "⌥Space")
        #expect(ShortcutAction.moveSessionUp.defaultShortcut.display == "⌥↑")
        #expect(ShortcutAction.moveSessionDown.defaultShortcut.display == "⌥↓")
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
        let store = Store.unsaved()
        var registered: Shortcut?
        store.onGlobalShortcutChange = { _, shortcut in registered = shortcut; return true }
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

    @Test func aClearedShortcutMatchesNothingAndComesBackWithReset() {
        let store = Store.unsaved()
        store.setShortcut(.unassigned, for: .markAllRead)
        #expect(store.shortcut(.markAllRead).isUnassigned)
        #expect(store.shortcut(.markAllRead).display == "None")
        #expect(!store.shortcut(.markAllRead).isModifierTap && store.shortcut(.markAllRead).mouseButton == nil)
        // Whatever key is pressed, none is the cleared one.
        for code in [kVK_Space, kVK_Delete, kVK_Return, kVK_ANSI_Z] {
            #expect(Shortcut(keyDown(code, [.option])) != store.shortcut(.markAllRead))
        }
        store.setShortcut(nil, for: .markAllRead)
        #expect(store.shortcut(.markAllRead) == ShortcutAction.markAllRead.defaultShortcut)
    }

    @Test func restoreDefaultsResetsEveryShortcutAndRegistersTheGlobalOnesAgain() {
        let store = Store.unsaved()
        var registered: [ShortcutAction] = []
        store.onGlobalShortcutChange = { action, _ in registered.append(action); return true }
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.control, .command]), for: .togglePanel)
        store.setShortcut(.unassigned, for: .discard)
        #expect(store.hasCustomShortcuts)
        registered = []
        store.restoreDefaultShortcuts()
        #expect(!store.hasCustomShortcuts)
        for action in ShortcutAction.allCases { #expect(store.shortcut(action) == action.defaultShortcut) }
        #expect(Set(registered) == [.togglePanel, .sessionSwitcher])
    }

    @Test func globalDefaultsAreUnchanged() {
        #expect(ShortcutAction.togglePanel.defaultShortcut == Shortcut(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .option]))
        #expect(ShortcutAction.sessionSwitcher.defaultShortcut == Shortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: [.control, .option]))
    }

    private func connected(_ store: Store, _ registrar: FakeRegistrar) -> GlobalShortcuts {
        store.persists = false
        store.agents.enabled = true
        let globals = GlobalShortcuts(store: store, registrar: registrar) { _ in }
        globals.start()
        return globals
    }

    @Test func restoreDefaultsAfterSwappingTheGlobalKeysRegistersBothDefaults() {
        let store = Store()
        let registrar = FakeRegistrar()
        let globals = connected(store, registrar)
        let keep = ShortcutAction.togglePanel.defaultShortcut, sessions = ShortcutAction.sessionSwitcher.defaultShortcut
        // Swapped the way the recorder allows it: through a key neither holds.
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.control, .command]), for: .togglePanel)
        store.setShortcut(keep, for: .sessionSwitcher)
        store.setShortcut(sessions, for: .togglePanel)
        #expect(registrar.registered == [1: sessions, 2: keep])
        registrar.refused = []
        store.restoreDefaultShortcuts()
        #expect(registrar.refused.isEmpty)
        #expect(registrar.registered == [1: keep, 2: sessions])
        #expect(store.shortcut(.togglePanel) == keep && store.shortcut(.sessionSwitcher) == sessions)
        withExtendedLifetime(globals) {}
    }

    @Test func restoreDefaultsRefusedByAnotherAppChangesNothing() {
        let store = Store()
        let registrar = FakeRegistrar()
        let globals = connected(store, registrar)
        let keep = ShortcutAction.togglePanel.defaultShortcut
        let moved = Shortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .command])
        store.setShortcut(moved, for: .togglePanel)
        store.setShortcut(.unassigned, for: .discard)
        let before = store.settings.shortcuts
        // Another app took Keep open's default after it was let go of.
        registrar.taken = [keep]
        let refusal = store.restoreDefaultShortcuts()
        #expect(refusal == .defaultUnavailable(keep))
        #expect(refusal?.message == "\(keep.display) is used by another app. Lookout keeps your shortcuts")
        // What worked still does, and so does what was cleared: stored, registered, shown.
        #expect(store.settings.shortcuts == before && store.shortcut(.togglePanel) == moved && store.shortcut(.discard).isUnassigned)
        #expect(registrar.registered == [1: moved, 2: ShortcutAction.sessionSwitcher.defaultShortcut])
        // Once the other app lets go, the restore goes through.
        registrar.taken = []
        #expect(store.restoreDefaultShortcuts() == nil && !store.hasCustomShortcuts)
        #expect(registrar.registered == [1: keep, 2: ShortcutAction.sessionSwitcher.defaultShortcut])
        withExtendedLifetime(globals) {}
    }

    @Test func resetRefusesADefaultAnotherActionHasTakenAndKeepsTheWorkingKey() {
        let store = Store()
        let registrar = FakeRegistrar()
        let globals = connected(store, registrar)
        let keepDefault = ShortcutAction.togglePanel.defaultShortcut
        let moved = Shortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.control, .command])
        store.setShortcut(moved, for: .togglePanel)
        // Open on sessions takes the key Keep open used to have: nothing holds it, so the recorder allows it.
        #expect(store.shortcutConflict(keepDefault, for: .sessionSwitcher) == nil)
        store.setShortcut(keepDefault, for: .sessionSwitcher)
        registrar.refused = []
        #expect(store.resetShortcut(for: .togglePanel) == .usedBy(.sessionSwitcher))
        #expect(store.shortcut(.togglePanel) == moved)
        #expect(store.shortcut(.sessionSwitcher) == keepDefault)
        #expect(registrar.registered == [1: moved, 2: keepDefault])
        #expect(registrar.refused.isEmpty)
        // Once the other action lets go of it, the reset goes through.
        store.setShortcut(nil, for: .sessionSwitcher)
        #expect(store.resetShortcut(for: .togglePanel) == nil)
        #expect(store.shortcut(.togglePanel) == keepDefault)
        #expect(registrar.registered == [1: keepDefault, 2: ShortcutAction.sessionSwitcher.defaultShortcut])
        withExtendedLifetime(globals) {}
    }

    @Test func aKeyAnotherAppHoldsIsRefusedAndTheWorkingOneStays() {
        let store = Store()
        let registrar = FakeRegistrar()
        let globals = connected(store, registrar)
        let keep = ShortcutAction.togglePanel.defaultShortcut
        let held = Shortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.control, .command])
        registrar.taken = [held]
        let refusal = store.setShortcut(held, for: .togglePanel)
        #expect(refusal == .unavailable(held))
        #expect(refusal?.message == "⌃⌘G is used by another app. Lookout keeps the old shortcut")
        // Stored and registered as before: nothing shows a key that does nothing, and the old one still works.
        #expect(store.shortcut(.togglePanel) == keep && store.settings.shortcuts == nil)
        #expect(registrar.registered[1] == keep)
        // A refused reset of a custom key keeps the custom one too.
        let moved = Shortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .command])
        #expect(store.setShortcut(moved, for: .togglePanel) == nil)
        registrar.taken = [keep]
        #expect(store.resetShortcut(for: .togglePanel) == .unavailable(keep))
        #expect(store.shortcut(.togglePanel) == moved && registrar.registered[1] == moved)
        withExtendedLifetime(globals) {}
    }

    @Test func aKeyAnotherAppHeldAtLaunchIsStoredButSaidToDoNothing() {
        let store = Store()
        let registrar = FakeRegistrar()
        store.persists = false
        let held = Shortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.control, .command])
        store.setShortcut(held, for: .togglePanel)
        registrar.taken = [held, ShortcutAction.sessionSwitcher.defaultShortcut]
        store.agents.enabled = false
        let globals = GlobalShortcuts(store: store, registrar: registrar) { _ in }
        globals.start()
        #expect(store.isShortcutHeldByAnotherApp(.togglePanel))
        // Switching the extension on tries the session key again, and a refusal there is kept too.
        #expect(!store.isShortcutHeldByAnotherApp(.sessionSwitcher))
        store.agents.enabled = true
        globals.register(.sessionSwitcher)
        #expect(store.isShortcutHeldByAnotherApp(.sessionSwitcher))
        // Another key that works clears it, as does the other app letting go.
        registrar.taken = []
        #expect(store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .command]), for: .togglePanel) == nil)
        #expect(!store.isShortcutHeldByAnotherApp(.togglePanel))
        globals.register(.sessionSwitcher)
        #expect(!store.isShortcutHeldByAnotherApp(.sessionSwitcher))
        // A refusal of a key just chosen leaves the old one stored and working: nothing to say.
        registrar.taken = [held]
        #expect(store.setShortcut(held, for: .togglePanel) != nil)
        #expect(!store.isShortcutHeldByAnotherApp(.togglePanel))
    }

    @Test func aClearedGlobalShortcutIsUnregisteredNotRegisteredAsNothing() {
        let store = Store()
        let registrar = FakeRegistrar()
        let globals = connected(store, registrar)
        registrar.received = []
        store.setShortcut(.unassigned, for: .togglePanel)
        #expect(registrar.received == [nil])
        #expect(registrar.registered[1] == nil)
        #expect(registrar.registered[2] == ShortcutAction.sessionSwitcher.defaultShortcut)
        store.setShortcut(nil, for: .togglePanel)
        #expect(registrar.registered[1] == ShortcutAction.togglePanel.defaultShortcut)
        withExtendedLifetime(globals) {}
    }

    @Test func theSessionSwitcherIsRegisteredOnlyWhileTheExtensionIsOn() {
        let store = Store()
        let registrar = FakeRegistrar()
        let globals = connected(store, registrar)
        #expect(registrar.registered[2] != nil)
        store.agents.enabled = false
        globals.register(.sessionSwitcher)
        #expect(registrar.registered[2] == nil)
    }
}

/// Stands in for the system: one registration per id, and a key another id (or another app) holds is refused, as Carbon
/// does, with what the id held left as it was.
private final class FakeRegistrar: HotKeyRegistrar {
    var registered: [UInt32: Shortcut] = [:]
    var refused: [Shortcut] = []
    var received: [Shortcut?] = []
    /// Keys that other apps hold.
    var taken: Set<Shortcut> = []

    func set(_ id: UInt32, _ shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool {
        received.append(shortcut)
        guard let shortcut, !shortcut.isUnassigned else { registered[id] = nil; return true }
        if taken.contains(shortcut) || registered.contains(where: { $0.key != id && $0.value == shortcut }) {
            refused.append(shortcut)
            return false
        }
        registered[id] = shortcut
        return true
    }
}
