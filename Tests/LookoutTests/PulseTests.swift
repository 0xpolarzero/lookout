import AppKit
import QuartzCore
import Testing
@testable import Lookout

/// Every working ring breathes in phase: a loop starts at a multiple of its cycle on the shared media clock, whenever
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

    @MainActor private final class Window {
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

    @Test func theLoopAsksForNoMoreThanThirtyFramesASecond() throws {
        let host = Window()
        let view = host.add(at: 0)
        view.set(spec, animated: true)
        let range = try #require(loop(view)).preferredFrameRateRange
        #expect(range.maximum <= 30 && range.preferred.map { $0 <= 30 } == true && range.minimum >= 10)
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
        // Nothing of the loop may stay under Reduce Motion, not even a dimmed value.
        view.set(spec, animated: true)
        #expect(loop(view) != nil)
        view.set(spec, animated: false)
        #expect(loop(view) == nil)
        #expect(view.layer?.opacity == 1)
    }

    @Test func theIdleGateCanAskHowManyRingsLoopAndIsToldWhenThatChanges() {
        let host = Window()
        let view = host.add(at: 0)
        var told = 0
        PulseView.onLoopingChange = { told += 1 }
        defer { PulseView.onLoopingChange = nil }
        let before = PulseView.looping
        view.set(spec, animated: true)
        #expect(PulseView.looping == before + 1 && told == 1)
        // Hidden window, or Reduce Motion: no loop, and the gate would see it.
        host.showing = false
        view.refresh()
        #expect(PulseView.looping == before && told == 2)
        view.refresh()
        #expect(told == 2)
        host.showing = true
        view.set(spec, animated: false)
        #expect(PulseView.looping == before)
    }

    @Test func theLifecycleReportIsTheLineTheIdleScriptReads() {
        let store = Store.unsaved()
        let line = store.lifecycleLine()
        let pattern = #"^lifecycle: sessions=\d+ working=\d+ rings=\d+ showing=[01] reduceMotion=[01]\n$"#
        #expect(line.range(of: pattern, options: .regularExpression) != nil, "\(line)")
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

/// Which sessions carry the ring: busy ones, never one waiting for you, however it waits.
@Suite struct WorkingMark {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let task = ClaudeTask(id: "t", kind: .command, title: "swift test", since: Date(timeIntervalSince1970: 2_000_000_000))

    private func row(running: Bool = false, blocked: Bool = false, unread: Bool = false, tasks: [ClaudeTask] = [],
                     stopped: Bool = false) -> AgentRow {
        let session = ClaudeSession(id: "a", title: "A", folder: "/code/a", lastActivity: now,
                                    summary: running ? nil : .init(blocked: blocked, detail: "Detail"), running: running)
        let activity = stopped ? ClaudeActivity(text: "Which one?", since: now, waitsForYou: true) : nil
        return AgentRow(session: session, entry: AgentEntry(id: "a", unread: unread), label: "A", activity: activity, tasks: tasks)
    }

    @Test func aRunningTurnWorks() {
        #expect(row(running: true).tileMarks.working)
    }

    @Test func aFinishedTurnWithTasksStillRunningWorks() {
        #expect(row(tasks: [task]).tileMarks.working)
        #expect(row(unread: true, tasks: [task]).tileMarks.working)
    }

    @Test func aFinishedTurnWithNothingRunningDoesNot() {
        #expect(!row().tileMarks.working)
        #expect(!row(unread: true).tileMarks.working)
    }

    @Test func aSessionWaitingForYouNeverWorks() {
        #expect(!row(running: true, stopped: true).tileMarks.working)
        // Finished on a question, with a subagent or command still running behind it.
        #expect(!row(blocked: true, unread: true, tasks: [task]).tileMarks.working)
    }

    @Test func readingAQuestionBringsTheRingBackForWhatItLeftRunning() {
        // Finished on a question and read: no longer amber, and the subagent or command behind it is work (DESIGN.md 10.1).
        let read = row(blocked: true, tasks: [task])
        #expect(!read.tileMarks.waiting && read.tileMarks.working)
        #expect(!row(blocked: true).tileMarks.working)
    }
}
