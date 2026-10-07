import AppKit
import Testing
@testable import Lookout

/// What the idle gate reads from the rings: how many loop, and a word when that changes (a covered window or Reduce Motion
/// takes the loop away, and a measurement without one would pass for free).
@MainActor
@Suite(.serialized) struct PulseLoops {
    @MainActor private final class Host {
        var showing = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: .borderless, backing: .buffered, defer: false)

        init() {
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        }

        func add() -> PulseView {
            let view = PulseView()
            view.frame = NSRect(x: 0, y: 0, width: 26, height: 26)
            view.windowShowing = { [unowned self] _ in showing }
            window.contentView?.addSubview(view)
            return view
        }
    }

    private func set(_ view: PulseView, animated: Bool) {
        view.set(animated: animated, rest: 1, from: 0.6, to: 0.28, duration: 1, smooth: true)
    }

    @Test func theIdleGateCanAskHowManyRingsLoopAndIsToldWhenThatChanges() {
        let host = Host()
        let view = host.add()
        var told = 0
        PulseView.onLoopingChange = { told += 1 }
        defer { PulseView.onLoopingChange = nil }
        let before = PulseView.looping
        set(view, animated: true)
        #expect(PulseView.looping == before + 1 && told == 1)
        // Hidden window: no loop, and the gate would see it.
        host.showing = false
        view.refresh()
        #expect(PulseView.looping == before && told == 2)
        view.refresh()
        #expect(told == 2)
        // Reduce Motion: the view is told not to animate.
        host.showing = true
        set(view, animated: false)
        #expect(PulseView.looping == before)
    }

    @Test func theLifecycleReportIsTheLineTheIdleScriptReads() {
        let store = Store()
        store.persists = false
        let line = Lifecycle.line(store)
        let pattern = #"^lifecycle: sessions=\d+ working=\d+ rings=\d+ showing=[01] reduceMotion=[01]\n$"#
        #expect(line.range(of: pattern, options: .regularExpression) != nil, "\(line)")
    }
}
