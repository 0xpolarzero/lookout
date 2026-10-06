import AppKit
import Observation
import SwiftUI

/// The shared clocks for every time label: `now` every second, `minute` every 30 seconds. Idle is 0%, so the timer
/// only runs while a `Ticking` view is on screen (in a visible window, not scrolled out of view, not hidden), the
/// screens are awake and a window is visible, and only at a second's pace while a view that counts seconds is on
/// screen: ages and "Checked 2m ago" need no more than 30.
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
    @ObservationIgnored let showing: @MainActor (NSWindow) -> Bool
    /// The system's date; a test moves it.
    @ObservationIgnored private let date: @MainActor () -> Date
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// `observing` follows the screens' sleep and the windows' occlusion, as the app does; a test turns it off and
    /// says whether a window is visible (`windowVisible`: any of them; `showing`: the one a label is in).
    init(observing: Bool = true, windowVisible: @escaping @MainActor () -> Bool = { NSApp.windows.contains { $0.isShowing } },
         showing: @escaping @MainActor (NSWindow) -> Bool = { $0.isShowing }, date: @escaping @MainActor () -> Date = { Date() }) {
        self.windowVisible = windowVisible
        self.showing = showing
        self.date = date
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
        // What a label reads must be current when the first one starts ticking: the clock may have been stopped for a
        // while. A later one changes nothing the others read (they would all redraw for it); `Ticking` draws its own
        // first frame from the system's date.
        if subscribers[rate] == 1 {
            if rate == .second { now = date() } else { minute = date() }
        }
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
        let wasStopped = interval == nil
        timer?.invalidate()
        timer = nil
        interval = rate?.interval
        guard let rate else { return }
        // Started again after a stop: what labels hold is as old as the stop. Going between a second's pace and 30 seconds'
        // changes nothing they read (each label's own start has set its own), and would redraw every one of them.
        if wasStopped {
            now = date()
            minute = now
        }
        ticks = 0
        let t = Timer(timeInterval: rate.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A label may be late by a fraction of its step; the system can batch the wake-up with others.
        t.tolerance = rate.interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        guard let interval else { return }
        let date = date()
        if interval == Rate.second.interval { now = date }
        ticks += 1
        if Double(ticks) * interval >= Rate.minute.interval {
            ticks = 0
            minute = date
        }
    }
}

extension NSWindow {
    /// Ordered in and not covered, minimised or on another Space.
    var isShowing: Bool { isVisible && occlusionState.contains(.visible) }
}

/// What one `Ticking` view asks of the clock: its rate, held only while the view is on screen and drawn, so a label
/// scrolled out of its list, in a window that is covered, or hidden, never keeps the timer running.
@MainActor @Observable
final class ClockClaim {
    @ObservationIgnored private var clock: Clock?
    @ObservationIgnored private var held: Clock.Rate?
    /// What the label needs; nil when it has left the hierarchy.
    @ObservationIgnored var rate: Clock.Rate? { didSet { sync() } }
    @ObservationIgnored var onScreen = false {
        didSet {
            sync()
            if onScreen != oldValue { announceChange() }
        }
    }
    @ObservationIgnored var hidden = false { didSet { sync() } }
    /// The time the label last drew, which it keeps while it is off screen.
    @ObservationIgnored var drawn: Date?
    /// Counts the times it came on screen or left it, for the label to be redrawn then (and not at every tick while it is away).
    private(set) var visibility = 0
    @ObservationIgnored private var announcing = false

    func start(on clock: Clock, rate: Clock.Rate, hidden: Bool) {
        self.clock = clock
        self.hidden = hidden
        self.rate = rate
    }

    private func sync() {
        let wanted = onScreen && !hidden ? rate : nil
        guard let clock, wanted != held else { return }
        // The new one first, so the timer isn't stopped and started again in between.
        if let wanted { clock.retain(wanted) }
        if let held { clock.release(held) }
        held = wanted
    }

    /// Said after the view update that found it out: it is not a state to change while the views are being updated.
    private func announceChange() {
        guard !announcing else { return }
        announcing = true
        DispatchQueue.main.async { [self] in
            announcing = false
            visibility &+= 1
        }
    }
}

extension EnvironmentValues {
    /// The clock `Ticking` views subscribe to: the shared one unless a test says otherwise.
    @Entry var clock: Clock? = nil
    /// Set by a parent that keeps its content laid out but not drawn (opacity 0): a `Ticking` inside is not on screen.
    @Entry var tickingHidden = false
}

extension View {
    /// Say the content is laid out but not drawn, so a time label in it stops asking the clock to tick.
    func tickingHidden(_ hidden: Bool) -> some View { environment(\.tickingHidden, hidden) }
}

/// Content that depends on the current time, redrawn from the shared clock: every 30 seconds if `coarse` (ages, "2m
/// ago": anything that shows minutes at most), every second otherwise. It asks the clock to tick only while it is on
/// screen: in a visible window, inside its scroll view's viewport, and not `tickingHidden`.
struct Ticking<Content: View>: View {
    private let start: Date?
    private let coarse: Bool
    private let content: (Date) -> Content
    @State private var claim = ClockClaim()
    @Environment(\.clock) private var environmentClock
    @Environment(\.tickingHidden) private var hidden

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
        let clock = environmentClock ?? .shared
        let rate = rate
        // A label reads the clock only while it is on screen: one scrolled away keeps what it drew and is not redrawn by the
        // ticks, and is redrawn (`visibility`) with the current time when it comes back.
        _ = claim.visibility
        let date: Date
        if !claim.onScreen {
            date = claim.drawn ?? Date()
        } else {
            // The clock's time is the one that ticks; a stopped clock's is old, and a label that has just appeared reads the
            // system's date for its first frame.
            date = clock.interval == nil ? Date() : rate == .second ? clock.now : clock.minute
        }
        claim.drawn = date
        return content(date)
            .background(OnScreen(showing: clock.showing) { claim.onScreen = $0 })
            .onAppear { claim.start(on: clock, rate: rate, hidden: hidden) }
            .onChange(of: rate) { claim.rate = rate }
            .onChange(of: hidden) { claim.hidden = hidden }
            .onDisappear { claim.rate = nil }
    }

    /// An elapsed time asks the system's date, not the clock's: a stopped clock would say it is still young.
    private var rate: Clock.Rate {
        if let start { return Date().timeIntervalSince(start) < 60 ? .second : .minute }
        return coarse ? .minute : .second
    }
}

private struct SpokenTime<Result: View>: ViewModifier {
    let since: Date?
    let speak: (Content, Date) -> Result
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @ViewBuilder func body(content: Content) -> some View {
        if voiceOver {
            // Only this redraws at a tick (the row it speaks for is `content`, which is not re-evaluated).
            Ticking(since: since) { speak(content, $0) }
        } else {
            speak(content, Date())
        }
    }
}

extension View {
    /// What a screen reader says about a time on this view (`speak` puts it in the accessibility label or value, from `now`).
    /// It follows the clock only while VoiceOver is on, and from a view of its own: a tick redraws this, not the view, whose
    /// age shown (`Ticking` round the text alone) and said still come from the one clock. `since`: as `Ticking(since:)`.
    func spokenTime<Result: View>(since: Date? = nil, _ speak: @escaping (SpokenTimeContent, Date) -> Result) -> some View {
        modifier(SpokenTime(since: since, speak: { content, now in speak(SpokenTimeContent(content), now) }))
    }
}

/// The view a time is spoken for, as `View.spokenTime` hands it to its closure.
struct SpokenTimeContent: View {
    private let content: AnyView
    init<Content: View>(_ content: Content) { self.content = AnyView(content) }
    var body: some View { content }
}

/// Reports whether the view behind it is on screen: its window is showing, and it is not clipped out of a scroll
/// view (a lazy list drops the rows it scrolls past, an eager one keeps them, so `onDisappear` alone says nothing).
/// It asks the clip views, kept up to date from their bounds: the same on every macOS we support, where
/// `onScrollVisibilityChange` is macOS 15 and knows scroll views only.
private struct OnScreen: NSViewRepresentable {
    let showing: @MainActor (NSWindow) -> Bool
    let change: (Bool) -> Void

    func makeNSView(context: Context) -> OnScreenView { OnScreenView() }

    func updateNSView(_ view: OnScreenView, context: Context) {
        view.showing = showing
        view.change = change
        view.evaluate()
    }
}

final class OnScreenView: NSView {
    var showing: @MainActor (NSWindow) -> Bool = { $0.isShowing }
    var change: (Bool) -> Void = { _ in }
    private var reported: Bool?
    private var observers: [NSObjectProtocol] = []

    /// Clicks pass through to the content.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watch()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        watch()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        evaluate()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        evaluate()
    }

    /// Follows the window's occlusion and every clip view above (a scroll view's viewport moving, or resizing).
    private func watch() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
            var ancestor = superview
            while let view = ancestor {
                if let clip = view as? NSClipView {
                    clip.postsBoundsChangedNotifications = true
                    observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.evaluate() }
                    })
                }
                ancestor = view.superview
            }
        }
        evaluate()
    }

    /// Out of the viewport of a scroll view above it. (Not `visibleRect`: SwiftUI's platform views report one that
    /// does not meet their own bounds.)
    private var isClipped: Bool {
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView, !clip.convert(bounds, from: self).intersects(clip.bounds) { return true }
            ancestor = view.superview
        }
        return false
    }

    func evaluate() {
        let on = window.map(showing) == true && !isHiddenOrHasHiddenAncestor && !isClipped
        guard on != reported else { return }
        reported = on
        change(on)
    }
}
