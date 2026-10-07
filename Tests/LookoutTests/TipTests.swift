import AppKit
import Foundation
import Testing
@testable import Lookout

@Suite(.serialized) struct TipEscape {
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    private func request() -> TipCenter.Request {
        TipCenter.Request(id: UUID(), title: "Settings", detail: nil, anchor: .zero)
    }

    @Test func escDismissesAndIsConsumed() {
        let center = TipCenter()
        center.show(request())
        #expect(TipCenter.dismissVisible(for: key(53)))
        #expect(center.current == nil)
        // Nothing is showing now: the next Esc is the hub's.
        #expect(!TipCenter.dismissVisible(for: key(53)))
    }

    @Test func keysAreWatchedOnlyWhileATooltipIsUp() {
        let center = TipCenter()
        #expect(!center.isWatchingKeys)
        center.show(request())
        #expect(center.isWatchingKeys)
        center.dismiss()
        #expect(!center.isWatchingKeys)
    }

    @Test func otherKeysAreLeftAlone() {
        let center = TipCenter()
        center.show(request())
        #expect(!TipCenter.dismissVisible(for: key(0)))
        #expect(!TipCenter.dismissVisible(for: key(53, .command)))
        #expect(center.current != nil)
        center.dismiss()
    }

    @Test func dismissingByHoverExitOnlyAffectsItsOwnTip() {
        let center = TipCenter()
        let shown = request()
        center.show(shown)
        center.dismiss(ifShowing: UUID())
        #expect(center.current?.id == shown.id)
        center.dismiss(ifShowing: shown.id)
        #expect(center.current == nil)
        #expect(TipCenter.visible == nil)
    }
}
