import AppKit
import SwiftUI

/// Content whose opacity pulses between two values, exact over any background. The content is rendered once to an image
/// (`ImageRenderer`, at the window's backing scale) and shown in a plain layer-backed view whose opacity loops in Core
/// Animation: no hosting view, no second SwiftUI graph, no SwiftUI work per frame (the render server runs the loop). The
/// SwiftUI content stays in the hierarchy at opacity 0 only for layout. The image is re-rendered when `id` changes (pass
/// every input the content depends on: anything not in `id` is not refreshed), when the size changes and when the
/// backing scale changes. Static (midpoint) when Reduce Motion is on; shown at full opacity, unpulsed, when `active` is false; the loop
/// is stopped while the window is occluded.
///
/// `content` must be a concrete view, not a ViewModifier's `content` placeholder (ImageRenderer cannot draw that).
/// For a bare coloured shape use `PulseBlock`, which fades the shape itself.
struct Pulse<ID: Hashable, Content: View>: View {
    var active = true
    var from: Double = 1
    var to: Double = 0.3
    var duration: Double = 1
    /// Ease in and out (smooth pulse) or step-like timing (blink).
    var smooth = true
    /// Everything the content depends on; the image is re-rendered when it changes.
    var id: ID
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The rendered view gets the environment explicitly: ImageRenderer does not inherit it.
        let rendered = AnyView(content.environment(\.colorScheme, colorScheme))
        content.opacity(0).overlay {
            PulseLayer(
                color: nil, cornerRadius: 0, rest: 1, from: from, to: to, duration: duration, smooth: smooth,
                animated: active && !reduceMotion,
                held: active && reduceMotion ? (from + to) / 2 : nil,
                image: PulseImage(key: AnyHashable(id), view: rendered))
            .allowsHitTesting(false)
        }
    }
}

/// What a `Pulse` shows: the view to render and the key that says when to render it again.
struct PulseImage {
    let key: AnyHashable
    let view: AnyView
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
    let color: Color?
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
    var image: PulseImage?

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ view: PulseView, context: Context) {
        view.configure(color: color, cornerRadius: cornerRadius)
        view.setImage(image)
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
    private var source: PulseImage?
    private var rendered: (key: AnyHashable, size: CGSize, scale: CGFloat)?
    private var cgImage: CGImage?

    override var wantsUpdateLayer: Bool { source == nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Clicks pass through to the SwiftUI view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: Color?, cornerRadius: CGFloat) {
        if let color {
            let cg = NSColor(color).cgColor
            if layer?.backgroundColor != cg { layer?.backgroundColor = cg }
        }
        if layer?.cornerRadius != cornerRadius { layer?.cornerRadius = cornerRadius }
    }

    func setImage(_ image: PulseImage?) {
        source = image
        renderIfNeeded()
    }

    /// Renders the content to an image when its key, the size or the backing scale changed.
    private func renderIfNeeded() {
        guard let source, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let rendered, rendered.key == source.key, rendered.size == bounds.size, rendered.scale == scale { return }
        rendered = (source.key, bounds.size, scale)
        let renderer = ImageRenderer(content: source.view.frame(width: bounds.width, height: bounds.height))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(bounds.size)
        cgImage = renderer.cgImage
        layer?.contentsGravity = .resize
        layer?.contentsScale = scale
        layer?.contents = cgImage
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        renderIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderIfNeeded()
    }

    /// Snapshots (`cacheDisplay`) go through `draw`, not the layer's contents.
    override func draw(_ dirtyRect: NSRect) {
        guard let cgImage, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: bounds)
        ctx.restoreGState()
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
