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
}
