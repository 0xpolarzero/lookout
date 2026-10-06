import SwiftUI

/// The working arc on tiles, for the `arcs` shots: one tile with and without it, and a row of twelve to compare how
/// they breathe together. A snapshot draws every arc at full opacity (the loop belongs to Core Animation, which a
/// snapshot does not run), so a shot shows the shape and the stroke, in the normal, Increase Contrast and Reduce
/// Motion settings.
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
            group("Twelve arcs, one phase") {
                HStack(spacing: Theme.Space.md) {
                    ForEach(0..<12, id: \.self) { _ in tile(Text("ab")) }
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

    private func tile(_ face: some View, working: Bool = true) -> some View {
        face
            .font(Theme.Typography.tile)
            .foregroundStyle(Theme.text)
            .tile(Theme.Metrics.tile)
            .overlay { WorkingArc(size: Theme.Metrics.tile, working: working) }
    }
}
