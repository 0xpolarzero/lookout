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
        store.onGlobalShortcutChange = { _, shortcut in registered = shortcut; return true }
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
        let f19 = Shortcut(keyCode: UInt16(kVK_F19), modifiers: [.control, .option, .command, .shift])
        let f18 = Shortcut(keyCode: UInt16(kVK_F18), modifiers: [.control, .option, .command, .shift])
        // Carbon rejects a combination twice in one app, so a second ID getting it shows the first was released.
        func isFree(_ shortcut: Shortcut) -> Bool {
            let probe = HotKeys()
            probe.set(91, shortcut) {}
            defer { probe.set(91, nil) }
            return probe.registeredIDs == [91]
        }
        hotKeys.set(90, f19) {}
        defer { hotKeys.set(90, nil) }
        #expect(!isFree(f19))
        hotKeys.isSuspended = true
        #expect(isFree(f19))
        // A change made meanwhile applies on resume.
        hotKeys.set(90, f18) {}
        #expect(isFree(f18))
        hotKeys.isSuspended = false
        #expect(isFree(f19))
        #expect(!isFree(f18))
        hotKeys.set(90, nil)
        #expect(isFree(f18))
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

    @Test func aClearedShortcutMatchesNothingAndComesBackWithReset() {
        let store = Store()
        store.persists = false
        store.setShortcut(.unassigned, for: .markAllRead)
        #expect(store.shortcut(.markAllRead).isUnassigned)
        #expect(store.shortcut(.markAllRead).display == "None")
        #expect(!store.shortcut(.markAllRead).isModifierTap && store.shortcut(.markAllRead).mouseButton == nil)
        // Whatever key is pressed, none is the cleared one.
        for code in [kVK_Space, kVK_Delete, kVK_Return, kVK_ANSI_Z] {
            #expect(Shortcut(key(code, [.option])) != store.shortcut(.markAllRead))
        }
        store.setShortcut(nil, for: .markAllRead)
        #expect(store.shortcut(.markAllRead) == ShortcutAction.markAllRead.defaultShortcut)
    }

    @Test func oldSettingsStillLoad() throws {
        let old = #"{"botHandles":[],"treatAppsAsBots":true,"pollInterval":60,"notifications":true,"reviewRequests":true,"didInitialReviewSync":true}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(settings.shortcuts == nil)
    }

    @MainActor private func connected(_ store: Store, _ registrar: FakeRegistrar) -> GlobalShortcuts {
        store.persists = false
        store.agents.enabled = true
        let globals = GlobalShortcuts(store: store, registrar: registrar) { _ in }
        globals.start()
        return globals
    }

    @MainActor @Test func aKeyAnotherAppHoldsIsRefusedAndTheWorkingOneStays() {
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

    @MainActor @Test func resetRefusesADefaultAnotherActionHasTakenAndKeepsTheWorkingKey() {
        let store = Store()
        let registrar = FakeRegistrar()
        let globals = connected(store, registrar)
        let keepDefault = ShortcutAction.togglePanel.defaultShortcut
        let moved = Shortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.control, .command])
        store.setShortcut(moved, for: .togglePanel)
        // Switch Claude session takes the key Keep open used to have: nothing holds it, so the recorder allows it.
        #expect(store.shortcutConflict(keepDefault, for: .sessionSwitcher) == nil)
        store.setShortcut(keepDefault, for: .sessionSwitcher)
        let refusal = store.resetShortcut(for: .togglePanel)
        #expect(refusal == .usedBy(.sessionSwitcher))
        #expect(refusal?.message == "Already used for Switch Claude session")
        #expect(store.shortcut(.togglePanel) == moved)
        #expect(store.shortcut(.sessionSwitcher) == keepDefault)
        #expect(registrar.registered == [1: moved, 2: keepDefault])
        // Once the other action lets go of it, the reset goes through.
        store.setShortcut(nil, for: .sessionSwitcher)
        #expect(store.resetShortcut(for: .togglePanel) == nil)
        #expect(store.shortcut(.togglePanel) == keepDefault)
        #expect(registrar.registered == [1: keepDefault, 2: ShortcutAction.sessionSwitcher.defaultShortcut])
        withExtendedLifetime(globals) {}
    }

    @MainActor @Test func turningTheExtensionOnSaysWhenAnotherAppHoldsTheSessionKey() {
        let store = Store()
        let registrar = FakeRegistrar()
        store.persists = false
        store.agents.enabled = false
        var said: [String] = []
        let globals = GlobalShortcuts(store: store, registrar: registrar, perform: { _ in }) { said.append($0) }
        globals.start()
        registrar.taken = [ShortcutAction.sessionSwitcher.defaultShortcut]
        store.agents.enabled = true
        store.onAgentsEnabledChange?(true)
        #expect(said == ["Switch Claude session: ⌃⌥S is used by another app, so it does nothing"])
        // Nothing to say once it takes.
        registrar.taken = []
        store.onAgentsEnabledChange?(true)
        #expect(said.count == 1 && registrar.registered[2] == ShortcutAction.sessionSwitcher.defaultShortcut)
    }

    @MainActor @Test func aKeyAnotherAppHeldAtLaunchIsStoredSaidOnceAndShownToDoNothing() {
        let store = Store()
        let registrar = FakeRegistrar()
        store.persists = false
        let held = Shortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.control, .command])
        store.setShortcut(held, for: .togglePanel)
        registrar.taken = [held, ShortcutAction.sessionSwitcher.defaultShortcut]
        store.agents.enabled = false
        var said: [String] = []
        let globals = GlobalShortcuts(store: store, registrar: registrar, perform: { _ in }) { said.append($0) }
        globals.start()
        #expect(store.isShortcutHeldByAnotherApp(.togglePanel))
        #expect(said == ["Keep open: ⌃⌘G is used by another app, so it does nothing"])
        // The switcher is not registered while the extension is off, so there is nothing to refuse yet.
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

    @MainActor @Test func aClearedGlobalShortcutIsUnregisteredNotRegisteredAsNothing() {
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

    @MainActor @Test func theSessionSwitcherIsRegisteredOnlyWhileTheExtensionIsOn() {
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
    var received: [Shortcut?] = []
    /// Keys that other apps hold.
    var taken: Set<Shortcut> = []

    func set(_ id: UInt32, _ shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool {
        received.append(shortcut)
        guard let shortcut else { registered[id] = nil; return true }
        if taken.contains(shortcut) || registered.contains(where: { $0.key != id && $0.value == shortcut }) { return false }
        registered[id] = shortcut
        return true
    }
}
