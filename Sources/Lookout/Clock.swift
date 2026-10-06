import AppKit
import Observation
import SwiftUI

/// The shared clocks for every time label: `now` every second, `minute` every 30 seconds. Idle is 0%, so the timer
/// only runs while a `Ticking` view is on screen, the screens are awake and a window is visible, and only at a
/// second's pace while a view that counts seconds is on screen: ages and "Checked 2m ago" need no more than 30.
@MainActor @Observable
final class Clock {
    static let shared = Clock()

    /// How often a label needs to be redrawn.
    enum Rate {
        case second, minute

        var interval: TimeInterval { self == .second ? 1 : 30 }
    }

    /// Updated every second while a seconds-ticking view is on screen.
    private(set) var now = Date()
    /// Updated at least every 30 seconds while anything ticking is on screen: for labels that show minutes at most.
    private(set) var minute = Date()

    /// The running timer's interval; nil while it is stopped.
    @ObservationIgnored private(set) var interval: TimeInterval?
    @ObservationIgnored private var subscribers: [Rate: Int] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private let windowVisible: @MainActor () -> Bool
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// `observing` follows the screens' sleep and the windows' occlusion, as the app does; a test turns it off and
    /// says whether a window is visible.
    init(observing: Bool = true, windowVisible: @escaping @MainActor () -> Bool = {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }) {
        self.windowVisible = windowVisible
        guard observing else { return }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.asleep = sleeping; self?.update() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
    }

    func retain(_ rate: Rate) {
        subscribers[rate, default: 0] += 1
        // What a label reads must be current when it starts ticking: the clock may have been stopped for a while.
        let date = Date()
        if rate == .second, subscribers[.second] == 1 { now = date }
        if date.timeIntervalSince(minute) > 1 { minute = date }
        update()
    }

    func release(_ rate: Rate) {
        subscribers[rate] = max(0, (subscribers[rate] ?? 0) - 1)
        update()
    }

    /// The pace the timer needs: a second's while a view counts seconds, 30 seconds for the others, none for none.
    private var needed: Rate? {
        if subscribers[.second, default: 0] > 0 { return .second }
        return subscribers[.minute, default: 0] > 0 ? .minute : nil
    }

    private func update() {
        let rate = asleep || !windowVisible() ? nil : needed
        guard rate?.interval != interval else { return }
        timer?.invalidate()
        timer = nil
        interval = rate?.interval
        guard let rate else { return }
        now = Date()
        minute = now
        ticks = 0
        let t = Timer(timeInterval: rate.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A label may be late by a fraction of its step; the system can batch the wake-up with others.
        t.tolerance = rate.interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let interval else { return }
        let date = Date()
        if interval == Rate.second.interval { now = date }
        ticks += 1
        if Double(ticks) * interval >= Rate.minute.interval {
            ticks = 0
            minute = date
        }
    }
}

/// Content that depends on the current time, redrawn from the shared clock: every 30 seconds if `coarse` (ages, "2m
/// ago": anything that shows minutes at most), every second otherwise.
struct Ticking<Content: View>: View {
    private let start: Date?
    private let coarse: Bool
    private let content: (Date) -> Content
    @State private var subscribed: Clock.Rate?

    init(coarse: Bool = false, @ViewBuilder content: @escaping (Date) -> Content) {
        start = nil
        self.coarse = coarse
        self.content = content
    }

    /// An elapsed time since `start`: it counts seconds while it is under a minute, minutes after. With no start
    /// there are no seconds to count.
    init(since start: Date?, @ViewBuilder content: @escaping (Date) -> Content) {
        self.start = start
        coarse = start == nil
        self.content = content
    }

    var body: some View {
        let clock = Clock.shared
        let rate = rate
        content(rate == .second ? clock.now : clock.minute)
            .onAppear { subscribe(to: rate) }
            .onChange(of: rate) { subscribe(to: rate) }
            .onDisappear { subscribe(to: nil) }
    }

    /// An elapsed time asks the system's date, not the clock's: a stopped clock would say it is still young.
    private var rate: Clock.Rate {
        if let start { return Date().timeIntervalSince(start) < 60 ? .second : .minute }
        return coarse ? .minute : .second
    }

    private func subscribe(to rate: Clock.Rate?) {
        guard rate != subscribed else { return }
        // The new one first, so the timer isn't stopped and started again in between.
        if let rate { Clock.shared.retain(rate) }
        if let subscribed { Clock.shared.release(subscribed) }
        subscribed = rate
    }
}
