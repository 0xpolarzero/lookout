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
    @MainActor @Observable final class Focus {
        var on = false
        /// The view is on screen, its focus watched: a change from here on is seen.
        var appeared = false
    }

    /// The second a focused control waits before its tip shows, held by the test: it says when it is waited on, and
    /// ends when the test lets it.
    @MainActor final class Delay {
        private(set) var waiting = 0
        private var held: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            waiting += 1
            await withCheckedContinuation { held.append($0) }
        }

        func pass() {
            held.forEach { $0.resume() }
            held = []
        }
    }

    struct Tipped: View {
        let focus: Focus
        let delay: Delay

        var body: some View {
            Color.clear.frame(width: 40, height: 40)
                .tip("Settings", "⌘,", focused: focus.on)
                .tipSpace()
                .frame(width: 200, height: 100)
                .environment(\.tipFocusDelay, { [delay] in await delay.wait() })
                .onAppear { focus.appeared = true }
        }
    }

    @MainActor @Test func aControlsTipShowsOnceItHasHadKeyboardFocusForASecondAndGoesWithIt() async throws {
        _ = NSApplication.shared
        let focus = Focus()
        let delay = Delay()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Tipped(focus: focus, delay: delay))
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close(); TipCenter.visible?.dismiss() }
        try await eventually { focus.appeared }
        #expect(TipCenter.visible == nil)
        focus.on = true
        // Not at once: a Tab through a row of controls doesn't flash each one's tip. The second is the test's to end, so
        // however slow the machine, the tip is still waiting for it here.
        try await eventually { delay.waiting == 1 }
        #expect(TipCenter.visible == nil)
        delay.pass()
        try await eventually { TipCenter.visible != nil }
        #expect(TipCenter.visible?.current?.title == "Settings")
        focus.on = false
        try await eventually { TipCenter.visible == nil }
        #expect(TipCenter.visible == nil)
    }
}

/// Waits for `condition`, which something the test started brings about (see `waitUntil`).
@MainActor private func eventually(within: TimeInterval = 60, _ condition: () -> Bool) async throws {
    await waitUntil(within: within, condition)
}
