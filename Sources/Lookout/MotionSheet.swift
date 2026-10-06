import SwiftUI

/// The working arc on tiles, for the `arcs` shots: one tile with and without it, and the two ends of its heartbeat.
/// A snapshot cannot show the loop (Core Animation runs it, and a snapshot draws the layer's resting value), so a shot
/// shows the shape and the stroke, in the normal and Increase Contrast settings, and the arc at its dimmest, to check
/// it still reads there. That every arc breathes in phase, and rests at full opacity under Reduce Motion, is
/// `PulseLayers`' to prove, on the layers.
struct MotionSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("Working tile, with and without the arc, over a glyph and an emoji") {
                HStack(spacing: Theme.Space.lg) {
                    tile(Text("lc"))
                    tile(Text("lc"), working: false)
                    tile(Image(systemName: "hammer").font(Theme.Typography.glyph(12)))
                    tile(Text("🦊").font(.system(size: 14)))
                }
            }
            group("The heartbeat at its two ends") {
                HStack(spacing: Theme.Space.lg) {
                    tile(Text("ab"), level: Theme.Motion.heartbeat.from)
                    tile(Text("ab"), level: Theme.Motion.heartbeat.to)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
        .themeResolved()
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(title).font(Theme.Typography.label).foregroundStyle(Theme.secondary)
            content()
        }
    }

    /// A tile with the arc: the real one, or (with a `level`) the arc frozen at that opacity.
    private func tile(_ face: some View, working: Bool = true, level: Double? = nil) -> some View {
        face
            .font(Theme.Typography.tile)
            .foregroundStyle(Theme.text)
            .tile(Theme.Metrics.tile)
            .overlay {
                if let level {
                    ArcShape(size: Theme.Metrics.tile).opacity(level)
                } else {
                    WorkingArc(size: Theme.Metrics.tile, working: working)
                }
            }
    }
}
