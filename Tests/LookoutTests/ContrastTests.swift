import AppKit
import SwiftUI
import Testing
@testable import Lookout

/// WCAG contrast of the colour tokens over the surfaces they land on (DESIGN.md 3.2), in the normal and the Increase
/// Contrast sets. Text pairs need 4.5:1, glyphs, rings and borders 3:1. Keep the pair list in step with the tokens.
@Suite struct Contrast {
    private struct RGB { var r: Double, g: Double, b: Double }

    private func components(_ color: Color) -> (rgb: RGB, alpha: Double) {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        return (RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent), c.alphaComponent)
    }

    private func over(_ top: Color, _ below: RGB) -> RGB {
        let (c, a) = components(top)
        return RGB(r: c.r * a + below.r * (1 - a), g: c.g * a + below.g * (1 - a), b: c.b * a + below.b * (1 - a))
    }

    private func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// The surfaces text and glyphs land on: white fills over `bg`, as the views draw them, and the opaque popover.
    private func surfaces(_ r: Theme.Resolved) -> [String: RGB] {
        let bg = components(Theme.bg).rgb
        func fill(_ c: Color) -> RGB { over(r.fill(c), bg) }
        return [
            "bg": bg, "rail": over(Theme.rail, bg), "hover": fill(Theme.Fill.hover), "field": fill(Theme.Fill.field),
            "tile": fill(Theme.Fill.tile), "selected": fill(Theme.Fill.selected), "pressed": fill(Theme.Fill.pressed),
            "group": fill(Theme.Fill.group), "popover": components(Theme.popover).rgb,
        ]
    }

    private struct Pair {
        let name: String
        let color: Color
        let on: [String]
        let minimum: Double
    }

    private static let all = ["bg", "rail", "hover", "field", "tile", "selected", "pressed", "group", "popover"]
    private static let rows = ["bg", "rail", "hover", "field", "tile", "selected"]

    private func pairs(_ r: Theme.Resolved) -> [Pair] {
        [
            // Text.
            Pair(name: "text", color: Theme.text, on: Self.all, minimum: 4.5),
            Pair(name: "secondary", color: r.secondary, on: Self.all, minimum: 4.5),
            Pair(name: "tertiary", color: r.tertiary, on: Self.all, minimum: 4.5),
            Pair(name: "accentText", color: Theme.accentText, on: Self.rows, minimum: 4.5),
            Pair(name: "amber text", color: Theme.amber, on: Self.all, minimum: 4.5),
            Pair(name: "red text", color: r.red, on: Self.rows, minimum: 4.5),
            // Glyphs, rings and borders.
            Pair(name: "accent", color: Theme.accent, on: Self.rows + ["popover"], minimum: 3),
            Pair(name: "amber glyph", color: Theme.amber, on: Self.all, minimum: 3),
            Pair(name: "red glyph", color: r.red, on: Self.rows, minimum: 3),
            Pair(name: "fieldBorder", color: Theme.fieldBorder, on: ["bg", "rail", "group"], minimum: 3),
        ]
    }

    @Test(arguments: [false, true]) func tokensOverTheirSurfaces(contrast: Bool) {
        let resolved = Theme.Resolved(contrast: contrast)
        let surfaces = surfaces(resolved)
        var failures: [String] = []
        for pair in pairs(resolved) {
            for name in pair.on {
                let below = surfaces[name]!
                let value = ratio(over(pair.color, below), below)
                if value < pair.minimum { failures.append("\(pair.name) on \(name): \(String(format: "%.2f", value)) < \(pair.minimum)") }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
    }

    @Test func textOnTintedFills() {
        // Amber and green are solid, unaffected by Increase Contrast.
        for fill in [Theme.amber, Theme.green] {
            let tint = over(fill, components(Theme.bg).rgb)
            let value = ratio(over(Theme.onTint, tint), tint)
            #expect(value >= 4.5, "onTint \(value)")
        }
    }

    @Test func tokensMatchTheDesignTable() {
        // A few of the figures printed in DESIGN.md 3.2, so a changed token can't pass unnoticed.
        let s = surfaces(Theme.Resolved())
        func value(_ color: Color, _ surface: String) -> Double { ratio(over(color, s[surface]!), s[surface]!) }
        #expect(abs(value(Theme.text, "bg") - 15.95) < 0.02)
        #expect(abs(value(Theme.secondary, "bg") - 9.34) < 0.02)
        #expect(abs(value(Theme.tertiary, "bg") - 6.73) < 0.02)
        #expect(abs(value(Theme.accent, "selected") - 4.53) < 0.02)
        #expect(abs(value(Theme.red, "selected") - 4.96) < 0.02)
        #expect(abs(value(Theme.fieldBorder, "bg") - 3.11) < 0.02)
    }
}
