import AppKit
import Observation
import SwiftUI

/// One shared once-a-second clock for every ticking label. Its timer only runs while a `Ticking` view is on
/// screen, the screen is awake and a window is visible.
@MainActor @Observable
final class Clock {
    static let shared = Clock()

    /// Updated every second.
    private(set) var now = Date()
    /// Updated every 5 seconds, for labels that don't need more.
    private(set) var slow = Date()

    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
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

    func retain() {
        subscribers += 1
        if subscribers == 1 { now = Date(); slow = now }
        update()
    }

    func release() {
        subscribers = max(0, subscribers - 1)
        update()
    }

    private var anyWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    private func update() {
        let run = subscribers > 0 && !asleep && anyWindowVisible
        if run, timer == nil {
            now = Date()
            slow = now
            ticks = 0
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !run, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func tick() {
        now = Date()
        ticks += 1
        if ticks % 5 == 0 { slow = now }
    }
}

/// Content that depends on the current time, redrawn from the shared clock: every second, or every 5 if `coarse`.
struct Ticking<Content: View>: View {
    var coarse = false
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        let clock = Clock.shared
        content(coarse ? clock.slow : clock.now)
            .onAppear { clock.retain() }
            .onDisappear { clock.release() }
    }
}
