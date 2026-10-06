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
