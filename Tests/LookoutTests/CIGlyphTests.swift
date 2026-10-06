import AppKit
import Testing
@testable import Lookout

/// The bar's CI glyph, as the playground's shots draw it and read pixel by pixel: a quiet state is a grey of its
/// token, never the pure white a symbol drew when its style did not reach it (an outline circle, in the bar).
@MainActor
@Suite struct CIGlyph {
    /// Where the glyph is in a 1280×820 shot (points, from the top left), per edge: the bar's second cell.
    private func centre(_ edge: DockEdge) -> CGPoint {
        edge == .right ? CGPoint(x: 1257, y: 160) : CGPoint(x: 515, y: 49)
    }

    /// The brightest red value near the glyph: its own colour, as the PNG holds it (no colour space conversion).
    private func glyph(_ state: CIState, edge: DockEdge, contrast: Bool = false) async -> Double {
        var shot = Shot(name: "glyph", edge: edge)
        shot.scenario = .allPassing
        shot.environment = contrast ? .contrast : ShotEnvironment()
        shot.setup = { store, _, _ in for name in store.ci.keys { store.ci[name]?.state = state } }
        let window = PlaygroundShots.open(shot)
        defer { window.close() }
        try? await Task.sleep(for: .seconds(1.5))
        guard let rep = PlaygroundShots.bitmap(of: window), let data = rep.bitmapData else { return -1 }
        let scale = Double(rep.pixelsWide) / Shot.standard.width
        let c = centre(edge)
        var brightest = 0
        for y in Int((c.y - 14) * scale)..<Int((c.y + 14) * scale) {
            for x in Int((c.x - 14) * scale)..<Int((c.x + 14) * scale) {
                brightest = max(brightest, Int(data[y * rep.bytesPerRow + x * rep.samplesPerPixel]))
            }
        }
        return Double(brightest) / 255
    }

    /// A white token's value over `bg`.
    private func over(_ alpha: Double) -> Double { alpha + (1 - alpha) * 0.078 }

    @Test(arguments: [DockEdge.right, .top])
    func aPassingGlyphIsTertiaryNotWhite(edge: DockEdge) async {
        #expect(abs(await glyph(.success, edge: edge) - over(0.58)) < 0.02)
        #expect(abs(await glyph(.none, edge: edge) - over(0.58)) < 0.02)
    }

    @Test(arguments: [DockEdge.right, .top])
    func aRunningGlyphIsSecondary(edge: DockEdge) async {
        #expect(abs(await glyph(.pending, edge: edge) - over(0.70)) < 0.02)
    }

    @Test func increaseContrastRaisesThemToTheirStrongerSet() async {
        #expect(abs(await glyph(.success, edge: .right, contrast: true) - over(0.80)) < 0.02)
        #expect(abs(await glyph(.pending, edge: .right, contrast: true) - over(0.86)) < 0.02)
    }
}
