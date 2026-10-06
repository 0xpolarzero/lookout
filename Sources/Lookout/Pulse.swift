import AppKit
import SwiftUI

/// Content whose opacity pulses between two values, exact over any background. The content is rendered once to an image
/// (`ImageRenderer`, at the window's backing scale) and shown in a plain layer-backed view whose opacity loops in Core
/// Animation: no hosting view, no second SwiftUI graph, no SwiftUI work per frame (the render server runs the loop). The
/// SwiftUI content stays in the hierarchy at opacity 0 only for layout.
///
/// Every pulse breathes in phase: each loop begins at the last multiple of its cycle on the shared media clock, so a
/// view that is made again, or a loop that is removed and added back, joins the others where they are. The image is
/// shared by every pulse that draws the same thing, and rendered again when `id` changes (pass every input the content
/// depends on: anything not in `id` is not refreshed), when Increase Contrast or Differentiate Without Colour changes,
/// when the size changes and when the backing scale changes. Held at `from` when Reduce Motion is on; shown at `from`,
/// unpulsed, when `active` is false; the loop is stopped while the window is occluded.
///
/// `content` must be a concrete view, not a ViewModifier's `content` placeholder (ImageRenderer cannot draw that).
struct Pulse<ID: Hashable, Content: View>: View {
    var active = true
    var from = Theme.Motion.heartbeat.from
    var to = Theme.Motion.heartbeat.to
    /// Seconds from `from` to `to`; the loop is there and back.
    var duration = Theme.Motion.heartbeat.period
    /// Everything the content depends on; the image is re-rendered when it changes.
    var id: ID
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.resolved) private var resolved

    var body: some View {
        // The rendered view gets the environment explicitly: ImageRenderer does not inherit it.
        let rendered = AnyView(content.environment(\.colorScheme, colorScheme).environment(\.resolved, resolved))
        content.opacity(0).overlay {
            PulseLayer(
                spec: PulseView.Spec(from: from, to: to, duration: duration),
                animated: active && !reduceMotion,
                key: PulseKey(id: id, contrast: resolved.contrast, differentiate: resolved.differentiate), view: rendered)
            .allowsHitTesting(false)
        }
    }
}

/// What the image depends on: the content's own inputs, and the two settings the content may draw differently for.
private struct PulseKey: Hashable {
    let id: AnyHashable
    let contrast: Bool
    let differentiate: Bool

    init(id: some Hashable, contrast: Bool, differentiate: Bool) {
        self.id = AnyHashable(id)
        self.contrast = contrast
        self.differentiate = differentiate
    }
}

/// A plain layer-backed view showing the rendered image, with a looping opacity animation.
private struct PulseLayer: NSViewRepresentable {
    let spec: PulseView.Spec
    let animated: Bool
    let key: PulseKey
    let view: AnyView

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ pulse: PulseView, context: Context) {
        pulse.setImage(key: key, view: view)
        pulse.set(spec, animated: animated)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

final class PulseView: NSView {
    struct Spec: Equatable {
        let from: Double
        let to: Double
        let duration: Double

        /// There and back.
        var cycle: Double { duration * 2 }
    }

    private var spec: Spec?
    private var animated = false
    private var observer: NSObjectProtocol?
    private var source: (key: PulseKey, view: AnyView)?
    private var rendered: (key: PulseKey, size: CGSize, scale: CGFloat)?
    private var cgImage: CGImage?

    /// The images already rendered, by what they show: every arc of a size and appearance is the same picture.
    private static var images: [ImageKey: CGImage] = [:]
    private struct ImageKey: Hashable {
        let key: PulseKey
        let size: CGSize
        let scale: CGFloat
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Clicks pass through to the SwiftUI view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    fileprivate func setImage(key: PulseKey, view: AnyView) {
        source = (key, view)
        renderIfNeeded()
    }

    /// Renders the content to an image when its key, the size or the backing scale changed (and no other pulse has).
    private func renderIfNeeded() {
        guard let source, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let rendered, rendered.key == source.key, rendered.size == bounds.size, rendered.scale == scale { return }
        rendered = (source.key, bounds.size, scale)
        let imageKey = ImageKey(key: source.key, size: bounds.size, scale: scale)
        if let cached = Self.images[imageKey] {
            cgImage = cached
        } else {
            let renderer = ImageRenderer(content: source.view.frame(width: bounds.width, height: bounds.height))
            renderer.scale = scale
            renderer.proposedSize = ProposedViewSize(bounds.size)
            cgImage = renderer.cgImage
            // A few appearances at most (sizes × contrast × scale); never a reason to keep growing.
            if Self.images.count > 32 { Self.images.removeAll() }
            Self.images[imageKey] = cgImage
        }
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

    fileprivate func set(_ spec: Spec, animated: Bool) {
        let changed = self.spec != spec
        self.animated = animated
        self.spec = spec
        // The model value is what a snapshot draws, and what shows when the animation is off.
        if layer?.opacity != Float(spec.from) { layer?.opacity = Float(spec.from) }
        if changed { layer?.removeAnimation(forKey: "pulse") }
        refresh()
    }

    /// When a loop of `cycle` seconds begins: the last multiple of it on the media clock, the same for every loop of that
    /// length, so all of them are at the same point of their cycle whenever they were added.
    static func beginTime(cycle: Double, at media: CFTimeInterval) -> CFTimeInterval {
        media - media.truncatingRemainder(dividingBy: cycle)
    }

    /// Runs the animation only while the window is on screen and visible; removes it otherwise.
    private func refresh() {
        guard let layer else { return }
        guard animated, let spec, let window, window.occlusionState.contains(.visible) else {
            layer.removeAnimation(forKey: "pulse")
            return
        }
        // Already looping: leave it, or it would start over.
        guard layer.animation(forKey: "pulse") == nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = spec.from
        a.toValue = spec.to
        a.duration = spec.duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.beginTime = layer.convertTime(Self.beginTime(cycle: spec.cycle, at: CACurrentMediaTime()), from: nil)
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
