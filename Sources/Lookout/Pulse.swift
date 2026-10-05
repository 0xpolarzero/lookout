import AppKit
import SwiftUI

/// Content whose opacity pulses between two values. The content stays plain SwiftUI, drawn as usual; on top of it sits a
/// lightweight layer (no hosting view, no second SwiftUI graph) filled with the background colour, whose opacity loops in
/// Core Animation, so the content reads as fading between `from` and `to`. The loop runs in the render server: no SwiftUI
/// work per frame. Static when Reduce Motion is on or `active` is false, and stopped while the window is occluded.
///
/// The fade is exact over a solid `background` (default the `\.pulseBackdrop` environment, `Theme.bg` unless a highlighted row sets it); over anything else it only
/// approximates. For a bare coloured shape use `PulseBlock`, which fades the shape itself. `cornerRadius` rounds the
/// veil to the content's shape.
struct Pulse<Content: View>: View {
    var active = true
    var from: Double = 1
    var to: Double = 0.3
    var duration: Double = 1
    /// Ease in and out (smooth pulse) or step-like timing (blink).
    var smooth = true
    /// The veil colour; nil follows `\.pulseBackdrop` (the surface the content sits on).
    var background: Color?
    var cornerRadius: CGFloat = 0
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pulseBackdrop) private var backdrop

    var body: some View {
        content.overlay {
            // The veil's opacity is what the content has lost: 1 - content opacity.
            PulseLayer(
                color: background ?? backdrop, cornerRadius: cornerRadius, rest: 0, from: 1 - from, to: 1 - to,
                duration: duration, smooth: smooth, animated: active && !reduceMotion,
                // Reduce Motion: hold the midpoint.
                held: active && reduceMotion ? 1 - (from + to) / 2 : nil)
            .allowsHitTesting(false)
        }
    }
}

private struct PulseBackdropKey: EnvironmentKey { static let defaultValue = Theme.bg }

extension EnvironmentValues {
    /// The opaque colour a `Pulse` veil fades into: what the pulsing content sits on. `Theme.bg` by default; a
    /// highlighted row sets `Theme.composite(Theme.Fill.field)` (see `.rowHighlight`).
    var pulseBackdrop: Color {
        get { self[PulseBackdropKey.self] }
        set { self[PulseBackdropKey.self] = newValue }
    }
}

/// A solid rounded block (a dot, a caret) whose own opacity pulses between `from` and `to`; a single layer.
struct PulseBlock: View {
    var color: Color
    var size: CGSize
    var cornerRadius: CGFloat
    var from: Double = 1
    var to: Double = 0.3
    var duration: Double = 1
    var smooth = true
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(color: Color, size: CGSize, cornerRadius: CGFloat, from: Double = 1, to: Double = 0.3, duration: Double = 1, smooth: Bool = true, active: Bool = true) {
        self.color = color; self.size = size; self.cornerRadius = cornerRadius
        self.from = from; self.to = to; self.duration = duration; self.smooth = smooth; self.active = active
    }

    /// A circle.
    init(color: Color, diameter: CGFloat, from: Double = 1, to: Double = 0.3, duration: Double = 1, smooth: Bool = true, active: Bool = true) {
        self.init(color: color, size: CGSize(width: diameter, height: diameter), cornerRadius: diameter / 2, from: from, to: to, duration: duration, smooth: smooth, active: active)
    }

    var body: some View {
        PulseLayer(
            color: color, cornerRadius: cornerRadius, rest: 1, from: from, to: to, duration: duration, smooth: smooth,
            animated: active && !reduceMotion, held: active && reduceMotion ? (from + to) / 2 : nil)
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// A plain layer-backed view filled with one colour, with an optional looping opacity animation.
private struct PulseLayer: NSViewRepresentable {
    let color: Color
    let cornerRadius: CGFloat
    /// Opacity when not pulsing and not held.
    let rest: Double
    let from: Double
    let to: Double
    let duration: Double
    let smooth: Bool
    let animated: Bool
    /// A fixed opacity (Reduce Motion).
    let held: Double?

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ view: PulseView, context: Context) {
        view.configure(color: color, cornerRadius: cornerRadius)
        view.set(animated: animated, rest: held ?? (animated ? from : rest), from: from, to: to, duration: duration, smooth: smooth)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

final class PulseView: NSView {
    private var spec: (from: Double, to: Double, duration: Double, smooth: Bool)?
    private var animated = false
    private var observer: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Clicks pass through to the SwiftUI view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: Color, cornerRadius: CGFloat) {
        let cg = NSColor(color).cgColor
        if layer?.backgroundColor != cg { layer?.backgroundColor = cg }
        if layer?.cornerRadius != cornerRadius { layer?.cornerRadius = cornerRadius }
    }

    func set(animated: Bool, rest: Double, from: Double, to: Double, duration: Double, smooth: Bool) {
        let changed = spec.map { $0 != (from, to, duration, smooth) } ?? true
        self.animated = animated
        spec = (from, to, duration, smooth)
        // The model value is what a snapshot draws, and what shows when the animation is off.
        if layer?.opacity != Float(rest) { layer?.opacity = Float(rest) }
        if changed { layer?.removeAnimation(forKey: "pulse") }
        refresh()
    }

    /// Runs the animation only while the window is on screen and visible; removes it otherwise.
    private func refresh() {
        guard let layer else { return }
        guard animated, let spec, let window, window.occlusionState.contains(.visible) else {
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
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }
}
