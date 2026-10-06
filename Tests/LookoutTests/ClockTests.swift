import AppKit
import SwiftUI
import Testing
@testable import Lookout

/// The clock's timer is the only thing that can wake an idle app: it runs only for a view on screen, and at a
/// second's pace only for one that counts seconds.
@MainActor
@Suite struct ClockGating {
    private func clock(visible: @escaping @MainActor () -> Bool = { true }) -> Clock {
        Clock(observing: false, windowVisible: visible)
    }

    @Test func stoppedWithoutViews() {
        #expect(clock().interval == nil)
    }

    @Test func minuteLabelsTickEvery30Seconds() {
        let clock = clock()
        clock.retain(.minute)
        #expect(clock.interval == 30)
        clock.release(.minute)
        #expect(clock.interval == nil)
    }

    @Test func secondsLabelsTickEverySecondAndOnlyWhileOnScreen() {
        let clock = clock()
        clock.retain(.second)
        clock.retain(.minute)
        #expect(clock.interval == 1)
        clock.release(.second)
        #expect(clock.interval == 30)
        clock.release(.minute)
        #expect(clock.interval == nil)
    }

    @Test func manyViewsShareOneTimer() {
        let clock = clock()
        for _ in 0..<5 { clock.retain(.second) }
        for _ in 0..<4 { clock.release(.second) }
        #expect(clock.interval == 1)
        clock.release(.second)
        #expect(clock.interval == nil)
    }

    @Test func aSecondSubscriberChangesNothingTheFirstReads() {
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = Clock(observing: false, windowVisible: { true }, date: { date })
        clock.retain(.minute)
        let first = clock.minute
        // The system's date has moved on since the first one started: a label mounting now must not tell the others (the
        // footer's mounts one on every poll, and every row reads this).
        date.addTimeInterval(5)
        let changed = Flag()
        withObservationTracking { _ = clock.minute } onChange: { changed.set() }
        clock.retain(.minute)
        #expect(!changed.value && clock.minute == first)
    }

    @Test func goingBetweenASecondsPaceAndThirtyRedrawsNoMinuteLabel() {
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = Clock(observing: false, windowVisible: { true }, date: { date })
        clock.retain(.minute)
        let first = clock.minute
        date.addTimeInterval(7)
        // A working row scrolls in (a seconds label starts) and out again: the timer changes pace twice, and the ages, which
        // read `minute`, are told nothing either time.
        let changed = Flag()
        withObservationTracking { _ = clock.minute } onChange: { changed.set() }
        clock.retain(.second)
        #expect(clock.interval == 1)
        clock.release(.second)
        #expect(clock.interval == 30 && !changed.value && clock.minute == first)
        // Started again after a stop, the clock does bring them up to date.
        clock.release(.minute)
        clock.retain(.minute)
        #expect(clock.minute == date)
    }

    @Test func aChangeOfPaceKeepsTheMinutesDeadline() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var date = start
        let clock = Clock(observing: false, windowVisible: { true }, date: { date })
        clock.retain(.minute)
        // A seconds label in view from t20 to t25, and again from t45 to t50: the age's update is still due at t30, and then t60.
        date = start.addingTimeInterval(20)
        clock.retain(.second)
        date = start.addingTimeInterval(25)
        clock.release(.second)
        #expect(try #require(clock.nextTick).timeIntervalSinceNow < 5.5)
        date = start.addingTimeInterval(30)
        clock.tick()
        #expect(clock.minute == date)
        date = start.addingTimeInterval(45)
        clock.retain(.second)
        date = start.addingTimeInterval(50)
        clock.release(.second)
        #expect(try #require(clock.nextTick).timeIntervalSinceNow < 10.5)
    }

    @Test func extraReleasesDoNotGoNegative() {
        let clock = clock()
        clock.release(.second)
        clock.retain(.minute)
        #expect(clock.interval == 30)
    }

    @Test func stoppedWhileNoWindowIsVisible() {
        var visible = false
        let clock = clock { visible }
        clock.retain(.second)
        #expect(clock.interval == nil)
        visible = true
        clock.retain(.minute)  // anything that re-evaluates it, as an occlusion change does
        #expect(clock.interval == 1)
    }
}

/// A label holds the clock only while it is on screen and drawn: the timer follows the last one that is.
@MainActor
@Suite struct ClockClaims {
    private func clock() -> Clock { Clock(observing: false, windowVisible: { true }, showing: { _ in true }) }

    @Test func aLabelHoldsTheClockOnlyWhileItIsOnScreen() {
        let clock = clock()
        let claim = ClockClaim()
        claim.start(on: clock, rate: .second, hidden: false)
        #expect(clock.interval == nil)  // not on screen yet
        claim.onScreen = true
        #expect(clock.interval == 1)
        claim.onScreen = false
        #expect(clock.interval == nil)
    }

    @Test func theLastSecondsLabelLeavingDowngradesTheTimer() {
        let clock = clock()
        let seconds = ClockClaim(), age = ClockClaim()
        seconds.start(on: clock, rate: .second, hidden: false)
        age.start(on: clock, rate: .minute, hidden: false)
        seconds.onScreen = true
        age.onScreen = true
        #expect(clock.interval == 1)
        seconds.onScreen = false
        #expect(clock.interval == 30)
        age.onScreen = false
        #expect(clock.interval == nil)
    }

    @Test func anElapsedTimeHandedToTheMinuteClockNeverGoesBack() {
        let t = Date(timeIntervalSince1970: 2_000_000_000)
        let claim = ClockClaim()
        // At the end of its seconds it drew t+59; the minute clock last ticked at t+43.
        claim.drawn = t.addingTimeInterval(59)
        let held = claim.time(ticked: t.addingTimeInterval(43), system: t.addingTimeInterval(60))
        #expect(held == t.addingTimeInterval(60))
        claim.drawn = held
        // Kept until the minute clock catches up, without waiting for the next tick to move.
        #expect(claim.time(ticked: t.addingTimeInterval(43), system: t.addingTimeInterval(66)) == held)
        #expect(claim.time(ticked: t.addingTimeInterval(73), system: t.addingTimeInterval(74)) == t.addingTimeInterval(73))
        // A label that was only following the minute clock is never held back.
        claim.drawn = t.addingTimeInterval(73)
        #expect(claim.time(ticked: t.addingTimeInterval(103), system: t.addingTimeInterval(104)) == t.addingTimeInterval(103))
    }

    @Test func aHiddenLabelAsksForNothing() {
        let clock = clock()
        let claim = ClockClaim()
        claim.start(on: clock, rate: .second, hidden: false)
        claim.onScreen = true
        claim.hidden = true
        #expect(clock.interval == nil)
        claim.hidden = false
        #expect(clock.interval == 1)
    }

    @Test func leavingTheHierarchyLetsGoAndChangingRateIsOneClaim() {
        let clock = clock()
        let claim = ClockClaim()
        claim.start(on: clock, rate: .second, hidden: false)
        claim.onScreen = true
        claim.rate = .minute  // a working turn passing its first minute
        #expect(clock.interval == 30)
        claim.rate = nil
        #expect(clock.interval == nil)
        claim.onScreen = false
        claim.onScreen = true
        #expect(clock.interval == nil)
    }
}

/// The same, through real views: a seconds label in an eager stack that is scrolled out of its viewport, or hidden,
/// stops the one-second timer.
@MainActor
@Suite struct TickingOnScreen {
    private struct List: View {
        var hidden = false
        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    Ticking(coarse: true) { _ in Text("ages").frame(height: 40) }
                    Color.clear.frame(height: 800)
                    // Under a minute old: it counts seconds.
                    Ticking(since: Date()) { _ in Text("working").frame(height: 40) }.tickingHidden(hidden)
                }
            }
            .frame(width: 200, height: 120)
        }
    }

    private func host(_ list: List, in clock: Clock) -> (NSWindow, NSScrollView) {
        let hosting = NSHostingView(rootView: list.environment(\.clock, clock))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        settle(hosting)
        return (window, find(NSScrollView.self, in: hosting)!)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); view.layoutSubtreeIfNeeded() }
    }

    private func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func scroll(_ scrollView: NSScrollView, toBottom: Bool) {
        let clip = scrollView.contentView
        let document = scrollView.documentView!
        let far = document.frame.height - clip.bounds.height
        // The document is flipped (y grows down) or not, depending on how SwiftUI hosts it.
        let bottom = document.isFlipped ? far : 0, top = document.isFlipped ? 0 : far
        clip.scroll(to: NSPoint(x: 0, y: toBottom ? bottom : top))
        scrollView.reflectScrolledClipView(clip)
        settle(scrollView)
    }

    /// How many times each label's content was evaluated.
    private final class Evaluations {
        var top = 0
        var bottom = 0
    }

    private struct Counted: View {
        let counts: Evaluations
        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    Ticking(coarse: true) { _ in
                        let _ = counts.top += 1
                        Text("top").frame(height: 40)
                    }
                    Color.clear.frame(height: 800)
                    Ticking(coarse: true) { _ in
                        let _ = counts.bottom += 1
                        Text("bottom").frame(height: 40)
                    }
                }
            }
            .frame(width: 200, height: 120)
        }
    }

    @Test func aTickRedrawsTheLabelsOnScreenAndNotThoseScrolledAway() async throws {
        // The ages of a long list: a minute's tick rebuilds the ones that can be seen, not every row.
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = Clock(observing: false, windowVisible: { true }, showing: { _ in true }, date: { date })
        let counts = Evaluations()
        let hosting = NSHostingView(rootView: Counted(counts: counts).environment(\.clock, clock))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        // The label that found itself on screen is redrawn once, from the clock, a moment after the update that found out.
        try await Task.sleep(for: .milliseconds(300))
        settle(hosting)
        #expect(clock.interval == 30)
        let (top, bottom) = (counts.top, counts.bottom)
        date.addTimeInterval(30)
        clock.tick()
        try await Task.sleep(for: .milliseconds(200))
        settle(hosting)
        #expect(counts.top > top, "the label in view is redrawn by the tick")
        #expect(counts.bottom == bottom, "the label scrolled away is not")
        window.contentView = nil
        window.orderOut(nil)
    }

    @Test func scrollingTheSecondsLabelOutOfViewDowngradesTheTimer() {
        let clock = Clock(observing: false, windowVisible: { true }, showing: { _ in true })
        let (window, scrollView) = host(List(), in: clock)
        #expect(clock.interval == 30)  // the age at the top is in view, the seconds label 800 pt down is not
        scroll(scrollView, toBottom: true)
        #expect(clock.interval == 1)
        scroll(scrollView, toBottom: false)
        #expect(clock.interval == 30)
        window.contentView = nil
        window.orderOut(nil)
        #expect(clock.interval == nil)
    }

    @Test func aHiddenSecondsLabelDoesNotTick() {
        let clock = Clock(observing: false, windowVisible: { true }, showing: { _ in true })
        let (window, scrollView) = host(List(hidden: true), in: clock)
        scroll(scrollView, toBottom: true)
        #expect(clock.interval == nil)  // in view, but not drawn
        window.contentView = nil
        window.orderOut(nil)
    }

    @Test func aLabelInACoveredWindowDoesNotTick() {
        var showing = true
        let clock = Clock(observing: false, windowVisible: { true }, showing: { _ in showing })
        let (window, scrollView) = host(List(), in: clock)
        #expect(clock.interval == 30)
        showing = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        settle(scrollView)
        #expect(clock.interval == nil)
        window.contentView = nil
        window.orderOut(nil)
    }
}

/// Set from an observation's change handler.
private final class Flag: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}
