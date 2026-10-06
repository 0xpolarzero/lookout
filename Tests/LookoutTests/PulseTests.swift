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
