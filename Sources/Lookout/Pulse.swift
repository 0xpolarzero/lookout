import AppKit
import SwiftUI

/// Content whose opacity pulses between two values. The loop is a Core Animation animation on a layer, so it runs
/// in the render server: no SwiftUI work per frame. Static when Reduce Motion is on or `active` is false.
struct Pulse<Content: View>: NSViewRepresentable {
    var active = true
    var from: Double = 1
    var to: Double = 0.3
    var duration: Double = 1
    /// Ease in and out (smooth pulse) or step-like timing (blink).
    var smooth = true
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PulseHost<Content> { PulseHost(content) }

    func updateNSView(_ view: PulseHost<Content>, context: Context) {
        view.hosting.rootView = content
        view.set(active: active && !reduceMotion, from: from, to: to, duration: duration, smooth: smooth)
        // Reduce Motion: hold the midpoint.
        view.layer?.opacity = active && reduceMotion ? Float((from + to) / 2) : 1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseHost<Content>, context: Context) -> CGSize? {
        nsView.hosting.fittingSize
    }
}

/// A layer-backed container around a hosting view, owning the opacity animation.
final class PulseHost<Content: View>: NSView {
    let hosting: NSHostingView<Content>
    private var spec: (from: Double, to: Double, duration: Double, smooth: Bool)?
    private var active = false
    private var observer: NSObjectProtocol?

    private func unobserve() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    init(_ content: Content) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        wantsLayer = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        addSubview(hosting)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Clicks pass through to the SwiftUI view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(active: Bool, from: Double, to: Double, duration: Double, smooth: Bool) {
        self.active = active
        spec = (from, to, duration, smooth)
        refresh()
    }

    /// Runs the animation only while the window is on screen and visible; removes it otherwise.
    private func refresh() {
        guard let layer else { return }
        guard active, let spec, let window, window.occlusionState.contains(.visible) else {
            layer.removeAnimation(forKey: "pulse")
            return
        }
        guard layer.animation(forKey: "pulse") == nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = spec.from
        a.toValue = spec.to
        a.duration = spec.duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: spec.smooth ? .easeInEaseOut : .linear)
        layer.add(a, forKey: "pulse")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unobserve()
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }
}
