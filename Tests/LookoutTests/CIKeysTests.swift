import AppKit
import Carbon
import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct CIKeys {
    private func state(selecting target: String, keyboard: Bool) -> (HubState, UIState) {
        let hub = HubState()
        hub.selection = target
        if keyboard { hub.requestScroll(target) }
        return (hub, UIState(persists: false, edge: .right))
    }

    @Test func thePointerOwnsItsPickOnlyWhileItIsOverTheRow() {
        let (hub, ui) = state(selecting: "c:b/bad", keyboard: false)
        hub.selection = nil
        hub.pointer(true, over: "c:b/bad", ui: ui)
        #expect(hub.selection == "c:b/bad")
        hub.pointer(false, over: "c:b/bad", ui: ui)
        #expect(hub.selection == nil)
    }

    @Test func aRowTheKeyboardPickedKeepsItsPickWhenThePointerLeaves() {
        let (hub, ui) = state(selecting: "c:b/bad", keyboard: true)
        hub.pointer(true, over: "c:b/bad", ui: ui)
        hub.pointer(false, over: "c:b/bad", ui: ui)
        #expect(hub.selection == "c:b/bad")
        // Leaving another row doesn't clear a pick that isn't its own.
        hub.pointer(false, over: "c:c/other", ui: ui)
        #expect(hub.selection == "c:b/bad")
    }

    @Test func aKeyboardPickMovesToTheRowThatTookItsPlaceWhenItLeavesTheList() {
        let (hub, _) = state(selecting: "c:b", keyboard: true)
        hub.rehomeCI(from: ["c:a", "c:b", "c:c", "c:passing"], to: ["c:a", "c:c", "c:passing"])
        #expect(hub.selection == "c:c")
        hub.rehomeCI(from: ["c:a", "c:c", "c:passing"], to: ["c:a", "c:passing"])
        #expect(hub.selection == "c:passing")
        hub.rehomeCI(from: ["c:a", "c:passing"], to: ["c:a"])
        #expect(hub.selection == "c:a")
    }

    @Test func aPointersPickAndAPickWithNothingLeftAreCleared() {
        let (hub, _) = state(selecting: "c:b", keyboard: false)
        hub.rehomeCI(from: ["c:a", "c:b"], to: ["c:a"])
        #expect(hub.selection == nil)
        let (keyed, _) = state(selecting: "c:b", keyboard: true)
        keyed.rehomeCI(from: ["c:b"], to: [])
        #expect(keyed.selection == nil)
        #expect(keyed.keyboardSelection == nil)
        // An inbox pick isn't CI's to move.
        let (inbox, _) = state(selecting: "i:1", keyboard: true)
        inbox.rehomeCI(from: ["c:a"], to: [])
        #expect(inbox.selection == "i:1")
    }

    @Test func showKeepsTheHubOpenOnCIWithItsFirstRowPicked() {
        let store = Store()
        store.persists = false
        store.repos = [RepoConfig(fullName: "a/ok"), RepoConfig(fullName: "b/bad")]
        let now = Date()
        store.ci = ["a/ok": CIStatus(state: .success, branch: "main", sha: "a1", url: nil, failing: [], checkedAt: now, title: nil, updatedAt: now),
                    "b/bad": CIStatus(state: .failure, branch: "main", sha: "b1", url: nil, failing: ["build"], checkedAt: now, title: nil,
                                      updatedAt: now)]
        let (hub, ui) = state(selecting: "i:1", keyboard: false)
        // From a search, with another section filling the view: CI's rows have to come back first.
        hub.query = "zig"
        hub.focus = .agents
        hub.showCI(store, ui: ui)
        #expect(hub.pinned)
        #expect(hub.query.isEmpty)
        #expect(hub.focus == nil)
        #expect(hub.selection == "c:b/bad")
        #expect(hub.keyboardSelection?.id == "c:b/bad")
        #expect(hub.voiceOverRequest?.target == "h:ci")
    }

    @Test func showOnCIWhereTheRoomFoldsItsRowsFocusesCIInsteadOfPickingNothing() {
        let store = Store()
        store.persists = false
        store.repos = [RepoConfig(fullName: "b/bad")]
        let now = Date()
        store.ci = ["b/bad": CIStatus(state: .failure, branch: "main", sha: "b1", url: nil, failing: ["build"], checkedAt: now, title: nil,
                                      updatedAt: now)]
        let (hub, ui) = state(selecting: "i:1", keyboard: false)
        // A low bar on the side: CI is only its header, and has no rows to pick.
        hub.ciFolded = true
        hub.showCI(store, ui: ui)
        #expect(hub.focus == .ci && hub.selection == "c:b/bad" && hub.keyboardSelection?.id == "c:b/bad")
    }

    // MARK: A focused control

    private func press(_ code: Int, _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
    }

    /// A pinned hub with one failing repo, its row picked, and what the store was asked to open.
    private func pickedHub() -> (HubKeys, HubState, () -> [String]) {
        let store = Store()
        store.persists = false
        store.repos = [RepoConfig(fullName: "b/bad")]
        let now = Date()
        store.ci = ["b/bad": CIStatus(state: .failure, branch: "main", sha: "b1", url: nil, failing: ["build"], checkedAt: now, title: nil,
                                      updatedAt: now)]
        var opened: [String] = []
        store.interceptOpen = { opened.append($0) }
        let hub = HubState()
        hub.pinned = true
        let keys = HubKeys(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
        keys.select("c:b/bad")
        return (keys, hub, { opened })
    }

    @Test func returnOpensThePickedRowWhenNoControlHasFocus() {
        let (keys, _, opened) = pickedHub()
        #expect(keys.key(press(kVK_Return)))
        #expect(opened() == ["Open checks · b/bad"])
    }

    @Test func aFocusedControlKeepsReturnAndSpaceFromThePickedRow() {
        let (keys, hub, opened) = pickedHub()
        let control = UUID()
        hub.controls.set(control, focused: true)
        #expect(!keys.key(press(kVK_Return)))
        #expect(!keys.key(press(kVK_ANSI_KeypadEnter)))
        #expect(!keys.key(press(kVK_Space, " ")))
        #expect(opened().isEmpty)
        // Once focus leaves the control, Return is the row's again.
        hub.controls.set(control, focused: false)
        #expect(keys.key(press(kVK_Return)))
        #expect(opened() == ["Open checks · b/bad"])
    }

    @Test func anArrowBoundToOpenOpensTheChecksInsteadOfMeaningPassing() {
        let (keys, hub, opened) = pickedHub()
        keys.store.setShortcut(Shortcut(keyCode: UInt16(kVK_RightArrow)), for: .openItem)
        #expect(keys.key(press(kVK_RightArrow)))
        #expect(opened() == ["Open checks · b/bad"])
        #expect(hub.selection == "c:b/bad")
    }
}
