import AppKit
import Observation
import SwiftUI

/// One shared clock for every ticking label. Its timer only runs while a `Ticking` view is on screen, the screen is
/// awake and a window is visible, and it ticks no faster than the quickest label on screen needs: a label that counts
/// minutes never starts the one-second timer.
@MainActor @Observable
final class Clock {
    static let shared = Clock()

    /// How often a label needs the time, and so how often its value changes.
    enum Resolution: CaseIterable {
        case second, slow, minute

        var period: TimeInterval {
            switch self {
            case .second: 1
            case .slow: 5
            case .minute: 30
            }
        }
    }

    /// Updated every second.
    private(set) var now = Date()
    /// Updated every 5 seconds, for labels that don't need more.
    private(set) var slow = Date()
    /// Updated every 30 seconds, for ages and "Checked 2m ago".
    private(set) var minute = Date()

    /// How often the timer must fire for these labels on screen: the quickest of them; nil with none.
    static func tick(for subscribers: [Resolution: Int]) -> TimeInterval? {
        Resolution.allCases.first { subscribers[$0, default: 0] > 0 }?.period
    }

    /// The timer's period while it runs.
    @ObservationIgnored private(set) var period: TimeInterval?
    @ObservationIgnored private var subscribers: [Resolution: Int] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
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

    func retain(_ resolution: Resolution = .second) {
        // The first label of a resolution shows the time as it is, not as it was when the timer last stopped.
        if subscribers[resolution, default: 0] == 0 { refresh(resolution, Date()) }
        subscribers[resolution, default: 0] += 1
        update()
    }

    func release(_ resolution: Resolution = .second) {
        subscribers[resolution] = max(0, subscribers[resolution, default: 0] - 1)
        update()
    }

    private var anyWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    private func update() {
        let wanted = !asleep && anyWindowVisible ? Self.tick(for: subscribers) : nil
        guard wanted != period else { return }
        timer?.invalidate()
        timer = nil
        period = wanted
        guard let wanted else { return }
        let date = Date()
        Resolution.allCases.forEach { refresh($0, date) }
        let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = wanted * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func value(_ resolution: Resolution) -> Date {
        switch resolution {
        case .second: now
        case .slow: slow
        case .minute: minute
        }
    }

    private func refresh(_ resolution: Resolution, _ date: Date) {
        switch resolution {
        case .second: now = date
        case .slow: slow = date
        case .minute: minute = date
        }
    }

    /// Each value changes at its own period (the timer may fire faster), and only while a label reads it.
    private func tick() {
        let date = Date()
        for resolution in Resolution.allCases where subscribers[resolution, default: 0] > 0 {
            if date.timeIntervalSince(value(resolution)) >= resolution.period - 0.5 { refresh(resolution, date) }
        }
    }
}

/// Content that depends on the current time, redrawn from the shared clock: every second, every 5 if `coarse`, or every
/// 30 if `minute` (for what is told in minutes).
struct Ticking<Content: View>: View {
    var coarse = false
    var minute = false
    @ViewBuilder let content: (Date) -> Content

    private var resolution: Clock.Resolution { minute ? .minute : coarse ? .slow : .second }

    var body: some View {
        let clock = Clock.shared
        content(clock.value(resolution))
            .onAppear { clock.retain(resolution) }
            .onDisappear { clock.release(resolution) }
    }
}
