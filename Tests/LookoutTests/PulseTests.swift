import AppKit
import QuartzCore
import Testing
@testable import Lookout

/// Every working arc breathes in phase: a loop starts at a multiple of its cycle on the shared media clock, whenever
/// it was added.
@Suite struct PulsePhase {
    private let cycle = 2.0 * Theme.Motion.heartbeat.period

    @Test func aLoopBeginsAtTheLastMultipleOfItsCycle() {
        for now in [0.0, 1.1, 2.4, 38_985.8, 123_456.789] {
            let begin = PulseView.beginTime(cycle: cycle, at: now)
            #expect(begin <= now && now - begin < cycle)
            #expect(abs((begin / cycle).rounded() - begin / cycle) < 1e-9)
        }
    }

    @Test func loopsAddedAtDifferentTimesShareOnePhase() {
        // 0.6 s apart in one cycle: the same start. Cycles apart: a whole number of cycles between the starts.
        let a = PulseView.beginTime(cycle: cycle, at: 38_985.8)
        let b = PulseView.beginTime(cycle: cycle, at: 38_986.4)
        let c = PulseView.beginTime(cycle: cycle, at: 38_988.2)
        #expect(a == b)
        #expect(abs((c - a) / cycle - ((c - a) / cycle).rounded()) < 1e-9)
    }
}

/// The layers themselves: loops started at different moments in a window share one phase, a refresh leaves a running
/// loop alone, and Reduce Motion or an occluded window removes it and rests at full opacity.
@MainActor
@Suite struct PulseLayers {
    /// A short cycle (0.1 s), so a test can let several go by.
    private let spec = PulseView.Spec(from: 1, to: 0.55, duration: 0.05)

    private final class Window {
        var showing = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: .borderless, backing: .buffered, defer: false)

        init() {
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        }

        /// A pulse view in the window, not yet looping.
        func add(at x: CGFloat) -> PulseView {
            let view = PulseView()
            view.frame = NSRect(x: x, y: 0, width: 26, height: 26)
            view.windowShowing = { [unowned self] _ in showing }
            window.contentView?.addSubview(view)
            return view
        }
    }

    private func loop(_ view: PulseView) -> CAAnimation? { view.layer?.animation(forKey: "pulse") }

    /// Whether two loops are at the same point of their cycle (their starts a whole number of cycles apart).
    private func inPhase(_ a: CAAnimation, _ b: CAAnimation) -> Bool {
        let cycles = (a.beginTime - b.beginTime) / spec.cycle
        return abs(cycles - cycles.rounded()) < 1e-6
    }

    private func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    @Test func loopsAddedAtDifferentTimesBeginInPhase() throws {
        let host = Window()
        let first = host.add(at: 0), second = host.add(at: 30)
        first.set(spec, animated: true)
        wait(0.25)  // a few cycles later
        second.set(spec, animated: true)
        let a = try #require(loop(first)), b = try #require(loop(second))
        #expect(inPhase(a, b))
        #expect(a.duration == spec.duration && a.autoreverses && a.repeatCount == .infinity)
    }

    @Test func aRefreshLeavesARunningLoopAlone() throws {
        let host = Window()
        let view = host.add(at: 0)
        view.set(spec, animated: true)
        let begin = try #require(loop(view)).beginTime
        wait(0.25)
        view.set(spec, animated: true)  // what SwiftUI does on every update
        view.refresh()
        #expect(try #require(loop(view)).beginTime == begin)
    }

    @Test func reduceMotionRemovesTheLoopAndRestsAtFullOpacity() throws {
        let host = Window()
        let view = host.add(at: 0)
        // A dimmed loop, as the busy tile's: nothing of it may stay under Reduce Motion.
        let dimmed = PulseView.Spec(from: 0.6, to: 0.28, duration: 1.1)
        view.set(dimmed, animated: true)
        #expect(loop(view) != nil)
        view.set(dimmed, animated: false)
        #expect(loop(view) == nil)
        #expect(view.layer?.opacity == 1)
    }

    @Test func aLoopRemovedWhileTheWindowIsHiddenRejoinsThePhase() throws {
        let host = Window()
        let running = host.add(at: 0), occluded = host.add(at: 30)
        running.set(spec, animated: true)
        occluded.set(spec, animated: true)
        host.showing = false
        occluded.refresh()  // what the window's occlusion change does
        #expect(loop(occluded) == nil)
        wait(0.25)
        host.showing = true
        occluded.refresh()
        #expect(inPhase(try #require(loop(occluded)), try #require(loop(running))))
    }
}
