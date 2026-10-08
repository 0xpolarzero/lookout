import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import Lookout

@Suite(.serialized, .hostsWindows) struct TipEscape {
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

    /// A control's focus, which a test moves.
    @MainActor @Observable final class Focus { var on = false }

    struct Tipped: View {
        let focus: Focus

        var body: some View {
            Color.clear.frame(width: 40, height: 40)
                .tip("Settings", "⌘,", focused: focus.on)
                .tipSpace()
                .frame(width: 200, height: 100)
        }
    }

    @MainActor @Test func aControlsTipShowsOnceItHasHadKeyboardFocusForASecondAndGoesWithIt() async throws {
        _ = NSApplication.shared
        let focus = Focus()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Tipped(focus: focus))
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close(); TipCenter.visible?.dismiss() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(TipCenter.visible == nil)
        focus.on = true
        // Not at once: a Tab through a row of controls doesn't flash each one's tip.
        try await Task.sleep(for: .milliseconds(400))
        #expect(TipCenter.visible == nil)
        // Waited for rather than slept on: a busy machine (CI, parallel suites) can run the second late.
        try await eventually { TipCenter.visible != nil }
        #expect(TipCenter.visible?.current?.title == "Settings")
        focus.on = false
        try await eventually { TipCenter.visible == nil }
        #expect(TipCenter.visible == nil)
    }
}

/// Waits for `condition`, which something the test started brings about.
@MainActor private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
}
