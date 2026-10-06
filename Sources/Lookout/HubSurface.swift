import SwiftUI

// The hub's surface (DESIGN.md 3.4): an opaque `bg` shape with one 1pt outline, over static shadow layers. The bar and
// a panel joined to it are one path, so no line shows where they meet.

/// The bar (the view's own bounds) and, joined to it, a panel: one path.
struct SurfaceShape: Shape {
    var barRadii: RectangleCornerRadii
    /// The panel at its full size, in the bar's coordinates (it may lie outside the bar), and its corners.
    var panel: CGRect?
    var panelRadii = RectangleCornerRadii()
    /// Which edge of the panel is flush with the bar.
    var edge = DockEdge.right
    /// How much of the panel is out (0...1): it grows from the bar, so a page can slide out. Animatable.
    var reveal: CGFloat = 1

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Self.rounded(rect, barRadii)
        if let panel, reveal > 0.001 {
            path = path.union(Self.rounded(shown(panel).offsetBy(dx: rect.minX, dy: rect.minY), panelRadii))
        }
        return path
    }

    private func shown(_ full: CGRect) -> CGRect {
        let r = min(max(reveal, 0), 1)
        return switch edge {
        case .right: CGRect(x: full.maxX - full.width * r, y: full.minY, width: full.width * r, height: full.height)
        case .left: CGRect(x: full.minX, y: full.minY, width: full.width * r, height: full.height)
        case .top: CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height * r)
        case .bottom: CGRect(x: full.minX, y: full.maxY - full.height * r, width: full.width, height: full.height * r)
        }
    }

    /// A continuous rounded rectangle whose corners never exceed what its size has room for.
    static func rounded(_ rect: CGRect, _ radii: RectangleCornerRadii) -> Path {
        let limit = max(min(rect.width, rect.height) / 2, 0)
        let clamped = RectangleCornerRadii(topLeading: min(radii.topLeading, limit), bottomLeading: min(radii.bottomLeading, limit),
                                           bottomTrailing: min(radii.bottomTrailing, limit), topTrailing: min(radii.topTrailing, limit))
        return Path(roundedRect: rect, cornerRadii: clamped, style: .continuous)
    }
}

extension DockEdge {
    /// The hub's corners: rounded away from the screen edge it is flush with, square against it.
    var hubRadii: RectangleCornerRadii {
        let r = Theme.Radius.hub
        return switch self {
        case .right: RectangleCornerRadii(topLeading: r, bottomLeading: r)
        case .left: RectangleCornerRadii(bottomTrailing: r, topTrailing: r)
        case .top: RectangleCornerRadii(bottomLeading: r, bottomTrailing: r)
        case .bottom: RectangleCornerRadii(topLeading: r, topTrailing: r)
        }
    }
}

/// What lies under the hub: a contact shadow always, an ambient one on top of it while a panel or the full view is out.
/// Both are shapes drawn once (nothing here is a blurred composite of live content), and the ambient one only changes
/// opacity: its radius and offset never animate.
struct SurfaceLayers: View {
    let shape: SurfaceShape
    let ambient: Bool

    var body: some View {
        ZStack {
            shape.fill(Theme.bg).shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            shape.fill(Theme.bg).shadow(color: .black.opacity(0.30), radius: 20, y: 7)
                .opacity(ambient ? 1 : 0)
        }
        .allowsHitTesting(false)
    }
}

/// The surface's 1pt outline, over the content (which is always inset from it).
struct SurfaceRing: View {
    let shape: SurfaceShape

    var body: some View {
        // The inside half of a 2pt line: 1pt, within the shape whichever way it turns.
        shape.stroke(Theme.stroke, lineWidth: 2).clipShape(shape).allowsHitTesting(false)
    }
}
