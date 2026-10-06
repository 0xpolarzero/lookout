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
            // A picked or pressed row of a list that floats (the repository suggestions) is a fill over the popover.
            "popover picked": over(r.fill(Theme.Fill.selected), components(Theme.popover).rgb),
            "popover pressed": over(r.fill(Theme.Fill.pressed), components(Theme.popover).rgb),
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
    /// A button's fills, pressed included: the chips' red check count lands on all of them.
    private static let buttons = rows + ["pressed"]
    /// The suggestions' rows, at rest, picked and pressed.
    private static let popoverRows = ["popover", "popover picked", "popover pressed"]

    private func pairs(_ r: Theme.Resolved) -> [Pair] {
        [
            // Text.
            Pair(name: "text", color: Theme.text, on: Self.all, minimum: 4.5),
            Pair(name: "secondary", color: r.secondary, on: Self.all, minimum: 4.5),
            Pair(name: "tertiary", color: r.tertiary, on: Self.all, minimum: 4.5),
            Pair(name: "suggestion owner", color: r.secondary, on: Self.popoverRows, minimum: 4.5),
            Pair(name: "suggestion name", color: Theme.text, on: Self.popoverRows, minimum: 4.5),
            Pair(name: "accentText", color: Theme.accentText, on: Self.rows, minimum: 4.5),
            Pair(name: "amber text", color: Theme.amber, on: Self.all, minimum: 4.5),
            // `resolved.red` on a chip (any fill it takes); `Theme.red` for the rest, on the page and its groups.
            Pair(name: "red text on a chip", color: r.red, on: Self.buttons, minimum: 4.5),
            Pair(name: "red text", color: Theme.red, on: ["bg", "rail", "group", "popover"], minimum: 4.5),
            // Glyphs, rings and borders.
            Pair(name: "accent", color: Theme.accent, on: Self.rows + ["popover"], minimum: 3),
            // The suggestions' pick bar, lighter than the rest because the popover under the fills is.
            Pair(name: "suggestion pick bar", color: Theme.accentText, on: ["popover", "popover picked"], minimum: 3),
            Pair(name: "amber glyph", color: Theme.amber, on: Self.all, minimum: 3),
            Pair(name: "red glyph", color: Theme.red, on: Self.buttons, minimum: 3),
            Pair(name: "fieldBorder", color: Theme.fieldBorder, on: ["bg", "rail", "group"], minimum: 3),
        ]
    }

    /// Each check is a colour laid over a surface, which must reach the minimum ratio against it.
    private typealias Check = (name: String, color: Color, surface: RGB, minimum: Double)

    private func expectContrast(_ checks: [Check]) {
        let failures = checks.compactMap { check -> String? in
            let value = ratio(over(check.color, check.surface), check.surface)
            return value < check.minimum ? "\(check.name): \(String(format: "%.2f", value)) < \(check.minimum)" : nil
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
    }

    @Test(arguments: [false, true]) func tokensOverTheirSurfaces(contrast: Bool) {
        let resolved = Theme.Resolved(contrast: contrast)
        let surfaces = surfaces(resolved)
        expectContrast(pairs(resolved).flatMap { pair in pair.on.map { ("\(pair.name) on \($0)", pair.color, surfaces[$0]!, pair.minimum) } })
    }

    @Test(arguments: [false, true]) func textOnAButtonInsideASettingsGroup(contrast: Bool) {
        // A bordered button's fill is drawn over the group's own (the recorder, pop-ups, Add): the surface is both, and
        // pressed is the lightest of them. Checked as layered, not as each fill alone.
        let resolved = Theme.Resolved(contrast: contrast)
        let bg = components(Theme.bg).rgb
        let group = over(resolved.fill(Theme.Fill.group), bg)
        expectContrast([("tile", Theme.Fill.tile), ("selected", Theme.Fill.selected), ("pressed", Theme.Fill.pressed)].flatMap { name, fill in
            let surface = over(resolved.fill(fill), group)
            return [("text", Theme.text), ("secondary", resolved.secondary)].map { ("\($0) on \(name) over the group", $1, surface, 4.5) }
        })
    }

    @Test func textOnTintedFills() {
        // Amber, green and the accent (a checked checkbox) are solid, unaffected by Increase Contrast.
        let bg = components(Theme.bg).rgb
        expectContrast([("amber", Theme.amber), ("green", Theme.green), ("accent", Theme.accent)].map { ("onTint on \($0)", Theme.onTint, over($1, bg), 4.5) })
    }

    @Test(arguments: [false, true]) func badgeGlyphsOverTheirOwnFill(contrast: Bool) {
        // An enabled repository badge draws accent over an accent fill, on its card (rest, or hovered) over the hub:
        // the fill takes the glyph's contrast down, so every level of it is checked, pressed included. The card draws
        // its fill as it is (Increase Contrast doesn't multiply it); the badge's own fill is `resolved.fill`.
        let resolved = Theme.Resolved(contrast: contrast)
        let bg = components(Theme.bg).rgb
        expectContrast([("page", bg), ("card", over(Theme.Fill.group, bg)), ("hovered card", over(Theme.Fill.hover, bg))].flatMap { name, card in
            [Theme.Fill.Tint.rest, .hover, .pressed].map { level in
                ("accent on \(level) fill over \(name)", Theme.accent, over(resolved.fill(Theme.Fill.tint(Theme.accent, level)), card), 3)
            }
        })
    }

    @Test(arguments: [false, true]) func ringHoldsThreeToOneThroughItsWholeHeartbeat(contrast: Bool) {
        // The ring is the one mark of working that isn't colour. It is drawn outside the tile, so it lands on the
        // surface the bar sits on (the rail, or the strip's `bg`) or on the row that is lit beside it (hovered or
        // picked): it holds 3:1 there at both ends of its heartbeat (DESIGN.md 10.1), and so at every opacity between.
        let resolved = Theme.Resolved(contrast: contrast)
        let surfaces = surfaces(resolved)
        expectContrast(["bg", "rail", "hover", "selected"].flatMap { name in
            [("full opacity", Theme.Motion.heartbeat.from), ("its trough", Theme.Motion.heartbeat.to)].map { end, opacity in
                ("ring at \(end) on \(name)", resolved.workingRing.opacity(opacity), surfaces[name]!, 3)
            }
        })
    }

    @Test(arguments: [false, true]) func theDownloadArcHoldsThreeToOneAgainstTheTrackItLeavesBehind(contrast: Bool) {
        // The finished arc is the progress: against the unfinished track, itself over the tile (at rest or hovered) over the rail or
        // the strip, the layers a bar actually draws.
        let resolved = Theme.Resolved(contrast: contrast)
        let bg = components(Theme.bg).rgb
        expectContrast([("strip", bg), ("rail", over(Theme.rail, bg))].flatMap { surface, base in
            [("rest", Theme.Fill.tile), ("hovered", Theme.Fill.selected)].map { state, tile in
                ("arc on the track, \(state) on the \(surface)", Theme.accent, over(Theme.downloadTrack, over(resolved.fill(tile), base)), 3)
            }
        })
    }

    @Test func tintedFillsAreNotMultiplied() {
        // Increase Contrast strengthens white fills only: a hue's fill stays what the glyph was checked against.
        let increased = Theme.Resolved(contrast: true)
        let tint = Theme.Fill.tint(Theme.accent, .pressed)
        #expect(components(increased.fill(tint)).alpha == components(tint).alpha)
        let white = Theme.Fill.hover
        #expect(components(increased.fill(white)).alpha > components(white).alpha)
    }

    @Test func tokensMatchTheDesignTable() {
        // A few of the figures printed in DESIGN.md 3.2, so a changed token can't pass unnoticed.
        let r = Theme.Resolved()
        let s = surfaces(r)
        func value(_ color: Color, _ surface: String) -> Double { ratio(over(color, s[surface]!), s[surface]!) }
        #expect(abs(value(Theme.text, "bg") - 15.95) < 0.02)
        #expect(abs(value(r.secondary, "bg") - 9.34) < 0.02)
        #expect(abs(value(r.tertiary, "bg") - 6.73) < 0.02)
        #expect(abs(value(Theme.accent, "selected") - 4.53) < 0.02)
        #expect(abs(value(Theme.red, "selected") - 5.12) < 0.02)
        #expect(abs(value(Theme.fieldBorder, "bg") - 3.11) < 0.02)
    }

    @Test(arguments: [false, true]) func inksDrawTheResolvedColours(contrast: Bool) {
        // What the views draw (an Ink resolved where it's used) is what tokensOverTheirSurfaces certifies.
        var environment = EnvironmentValues()
        environment.resolved = Theme.Resolved(contrast: contrast)
        let r = environment.resolved
        #expect(Theme.secondary.resolve(in: environment) == r.secondary)
        #expect(Theme.tertiary.resolve(in: environment) == r.tertiary)
        #expect(Theme.stroke.resolve(in: environment) == r.stroke)
        #expect(Theme.divider.resolve(in: environment) == r.divider)
        // And Increase Contrast does change them.
        #expect((Theme.Resolved(contrast: true).secondary == Theme.Resolved().secondary) == false)
    }

    @Test(arguments: [false, true]) func theSelectedTabIsToldApartByAnOutlineAtBorderContrast(contrast: Bool) {
        // The selected capsule's fill is 1.3:1 on the page, so the outline carries it: over the page, a group and the rail.
        let surfaces = surfaces(Theme.Resolved(contrast: contrast))
        expectContrast(["bg", "rail", "group"].map { ("outline on \($0)", TabStyle.selectedOutline, surfaces[$0]!, 3) })
    }

    @Test func theSwitchKnobHoldsItsEdgeOnTheTrackAtRestAndHovered() {
        // White on the accent is 2.9:1 (2.5:1 hovered), whatever Increase Contrast says (a hue's fill is not multiplied). The
        // knob's dark edge against the track is the contrast that counts.
        let bg = components(Theme.bg).rgb
        let accent = over(Theme.accent, bg)
        let lifted = RGB(r: min(accent.r + 0.06, 1), g: min(accent.g + 0.06, 1), b: min(accent.b + 0.06, 1))  // `.brightness(0.06)`
        expectContrast([("rest", accent), ("hovered", lifted)].map { ("edge on the \($0) track", SwitchKnob.edge, $1, 3) })
    }
}
