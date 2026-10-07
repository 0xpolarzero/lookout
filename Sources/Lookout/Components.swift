import SwiftUI

// The design system's pieces. Tokens live in `Theme` (Theme.swift); shared components live here.
//
// TOKENS (Theme.swift)
//   Colours   bg, raised, hover, stroke, text, secondary (white .64, ~7.97:1 on bg; was .56), tertiary (white .46, ~4.67:1; was .34), accent, amber,
//             green, red, purple, claude; `Theme.onTint` = text on a tinted (amber/green/...) fill.
//   Radius    Theme.Radius.xs 5 (keycaps, small chips) / sm 7 (compact tiles, menus) / md 9 (rows, fields, buttons)
//             / lg 12 (cards, popovers) / panel 18 (the hub itself). All `.continuous`: use `Theme.Radius.shape(_)`.
//   Fill      Theme.Fill.rest 0 / faint .045 (cards) / field .06 (fields, row highlight) / hover .07 / selected .12 /
//             pressed .15 / tile .10 (avatars, icon tiles). Disabled buttons show no fill and fade to 40%. Never write `Color.white.opacity(x)` for these.
//   Font      Theme.Typography.title 13 semibold (page/section titles) / body 12 medium (row text) / meta 11 (secondary
//             info) / caption 10.5 (tooltip detail, hints) / eyebrow 10 semibold (uppercase headings, with
//             `.tracking(Theme.Typography.eyebrowTracking)`) / count 11 semibold mono-digit / badge 10 bold mono-digit.
//             `Theme.Typography.glyph(_ size, weight)` for icons sized off their box.
//   Space     Theme.Space.xs 4 / sm 6 / md 8 / lg 12 / xl 16.
//   Metrics   Theme.Metrics.line 30 (header / one-line row), row 36 (session row), bar 46 (bar depth), inset 6 (the
//             one outer inset), field 32, chip 26.
//   Motion    Theme.Motion.hover (easeOut .12), spring (.28, bounce .06), fade (easeOut .14).
//             `.motion(_:value:)` replaces `.animation(_:value:)`: reads Reduce Motion LIVE from the environment and
//             swaps springs for a short fade. In code with no view: `@Environment(\.accessibilityReduceMotion) var
//             reduce`, then `withAnimation(Theme.Motion.spring.resolved(reduce: reduce))` or
//             `.transition(.slide(from: .trailing, reduce: reduce))`.
//
// COMPONENTS (this file)
//   HoverFillButtonStyle   (respects isEnabled) `.buttonStyle(HoverFillButtonStyle(...))`: hover/active/pressed fill, hover animation. Use
//                          for every button that fills on hover (rows, icon buttons, chips). Any shape.
//   .rowHighlight(on)      The hub row's 8x6 padding + r9 fill; `on` = hovered or picked. Pair with `.onHover`.
//   Hairline(axis:inset:)  A 1pt stroke-coloured divider. Never `Rectangle().fill(Theme.stroke)`.
//   CountBadge(n, tint:)   A count in a capsule (filter chips, section counts). `tint` fills it (text uses onTint).
//   DotCount(n, color:)    A coloured dot + number, numeric-text transition; grey when 0 (CI counts, status counts).
//   Eyebrow(title)         Uppercase tracking section title (settings sections, "PENDING", "WATCHING").
//   .tile(size)            Frames a view as a rounded square filled `Fill.tile`, clipped, radius size*0.3.
//   Tile.shape(size)       The same shape, for your own backgrounds / clipping.
//   plural(n, "folder")    "1 folder", "2 folders"; third arg for irregulars: plural(2, "repository", "repositories").

extension Theme {
    enum Radius {
        static let xs: CGFloat = 5
        static let sm: CGFloat = 7
        static let md: CGFloat = 9
        static let lg: CGFloat = 12
        static let panel: CGFloat = 18

        static func shape(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    }

    /// Translucent white fills, one per state, so hover looks the same everywhere.
    enum Fill {
        static let rest = Color.clear
        static let faint = Color.white.opacity(0.045)
        static let field = Color.white.opacity(0.06)
        static let hover = Color.white.opacity(0.07)
        static let tile = Color.white.opacity(0.10)
        static let selected = Color.white.opacity(0.12)
        static let pressed = Color.white.opacity(0.15)
    }

    enum Typography {
        /// Page and field titles (was 13 semibold).
        static let title = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Section header titles (was 12 semibold).
        static let heading = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// Chips, buttons and settings labels (was 12 medium).
        static let control = SwiftUI.Font.system(size: 12, weight: .medium)
        /// Row text (was 12.5): regular for read, `bodyStrong` for unread; `bodyMedium` in between.
        static let body = SwiftUI.Font.system(size: 12.5)
        static let bodyMedium = SwiftUI.Font.system(size: 12.5, weight: .medium)
        static let bodyStrong = SwiftUI.Font.system(size: 12.5, weight: .semibold)
        /// Secondary info (was 11, 11.5).
        static let meta = SwiftUI.Font.system(size: 11)
        /// Tooltip detail, hints (was 10.5).
        static let caption = SwiftUI.Font.system(size: 10.5)
        /// Uppercase headings (was 9.5 bold in "PENDING", 10.5 semibold in settings).
        static let eyebrow = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let eyebrowTracking: CGFloat = 0.6
        /// Numbers beside dots (was 11 semibold).
        static let count = SwiftUI.Font.system(size: 11, weight: .semibold).monospacedDigit()
        /// Numbers in capsules (was 10 bold).
        static let badge = SwiftUI.Font.system(size: 10, weight: .bold).monospacedDigit()

        /// An icon or initials sized off the box that holds it.
        static func glyph(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight)
        }
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    enum Metrics {
        /// A section header, or a one-line row.
        static let line: CGFloat = 30
        /// A session row.
        static let row: CGFloat = 36
        /// The bar's depth: a cell's width on the sides, the strip's height along the top and bottom.
        static let bar: CGFloat = 46
        /// The one outer inset around the hub's pieces.
        static let inset: CGFloat = 6
        static let field: CGFloat = 32
        static let chip: CGFloat = 26
    }

    enum Motion {
        static let hover = Animation.easeOut(duration: 0.12)
        static let spring = Animation.spring(duration: 0.28, bounce: 0.06)
        static let fade = Animation.easeOut(duration: 0.14)
    }

    /// Text and glyphs on a tinted (amber, green...) fill.
    static let onTint = Color.black.opacity(0.8)
}

extension Animation {
    /// No animation at all when Reduce Motion is on (positions, scales and sizes jump); fades come from `.opacity`
    /// transitions, which `AnyTransition.slide`/`scaleFade` fall back to. Pass to `withAnimation` / `.animation`.
    func resolved(reduce: Bool) -> Animation? { reduce ? nil : self }
}

extension AnyTransition {
    /// Slides in from an edge; a plain fade with Reduce Motion.
    static func slide(from edge: Edge, reduce: Bool) -> AnyTransition { reduce ? .opacity : .move(edge: edge) }
    /// Scales up from `scale` while fading; a plain fade with Reduce Motion.
    static func scaleFade(_ scale: CGFloat = 0.96, reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .scale(scale: scale).combined(with: .opacity)
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content.animation(animation.resolved(reduce: reduce), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that follows Reduce Motion live: animations are dropped.
    func motion<V: Equatable>(_ animation: Animation = Theme.Motion.spring, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// The hub row's look: 8x6 padding inside an r9 fill, shown while `on` (hovered or picked).
    func rowHighlight(_ on: Bool) -> some View {
        self
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.Radius.shape(Theme.Radius.md).fill(on ? Theme.Fill.field : Theme.Fill.rest))
            .contentShape(Theme.Radius.shape(Theme.Radius.md))
            .motion(Theme.Motion.hover, value: on)
    }

    /// A rounded square filled like a tile (see `Tile`).
    func tile(_ size: CGFloat, fill: Color = Theme.Fill.tile) -> some View {
        frame(width: size, height: size).background(Tile.shape(size).fill(fill)).clipShape(Tile.shape(size))
    }
}

/// Fills its shape on hover (and a stronger one while `active` or pressed), animated; for `.buttonStyle`.
/// The label keeps its own colours: labels that should change on hover read `@Environment(\.hoverFillHovering)`.
struct HoverFillButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(Theme.Radius.shape(Theme.Radius.md))
    var rest: Color = Theme.Fill.rest
    var hover: Color = Theme.Fill.hover
    var active: Color = Theme.Fill.selected
    var pressed: Color = Theme.Fill.pressed
    var isActive = false

    init(shape: some Shape = Theme.Radius.shape(Theme.Radius.md), rest: Color = Theme.Fill.rest, hover: Color = Theme.Fill.hover,
         active: Color = Theme.Fill.selected, pressed: Color = Theme.Fill.pressed, isActive: Bool = false) {
        self.shape = AnyShape(shape)
        self.rest = rest
        self.hover = hover
        self.active = active
        self.pressed = pressed
        self.isActive = isActive
    }

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, style: self)
    }

    private struct Label: View {
        let configuration: Configuration
        let style: HoverFillButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let hot = enabled && hovering
            let fill = !enabled ? style.rest : configuration.isPressed ? style.pressed : style.isActive ? style.active : hot ? style.hover : style.rest
            configuration.label
                .environment(\.hoverFillHovering, hot)
                .background(style.shape.fill(fill))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(style.shape)
                .onHover { hovering = $0 }
                .motion(Theme.Motion.hover, value: hovering)
                .motion(Theme.Motion.hover, value: configuration.isPressed)
        }
    }
}

private struct HoverFillHoveringKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside a `HoverFillButtonStyle` label while the pointer is over an enabled button. Read-only for consumers.
    var hoverFillHovering: Bool {
        get { self[HoverFillHoveringKey.self] }
        set { self[HoverFillHoveringKey.self] = newValue }
    }
}

/// A 1pt divider in the stroke colour. `inset` trims both ends.
struct Hairline: View {
    var axis: Axis = .horizontal
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .padding(axis == .horizontal ? .horizontal : .vertical, inset)
    }
}

/// A count in a capsule. `tint` fills it (text goes dark); without, a quiet white fill.
struct CountBadge: View {
    let count: Int
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduce

    init(_ count: Int, tint: Color? = nil) {
        self.count = count
        self.tint = tint
    }

    var body: some View {
        Text("\(count)")
            .font(Theme.Typography.badge)
            .foregroundStyle(tint == nil ? Theme.secondary : Theme.onTint)
            .padding(.horizontal, 5)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(tint ?? Theme.Fill.tile))
            .contentTransition(reduce ? .opacity : .numericText(value: Double(count)))
    }
}

/// A dot and a number; both grey out at zero.
struct DotCount: View {
    let count: Int
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduce

    init(_ count: Int, color: Color) {
        self.count = count
        self.color = color
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(count == 0 ? Theme.tertiary : color).frame(width: 7, height: 7)
            Text("\(count)")
                .font(Theme.Typography.count)
                .foregroundStyle(count == 0 ? Theme.tertiary : Theme.text)
                .contentTransition(reduce ? .opacity : .numericText(value: Double(count)))
        }
    }
}

/// An uppercase section title, optionally with a count after it.
struct Eyebrow: View {
    let title: String
    var count: Int? = nil

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        Text(count.map { "\(title.uppercased())  \($0)" } ?? title.uppercased())
            .font(Theme.Typography.eyebrow)
            .tracking(Theme.Typography.eyebrowTracking)
            .foregroundStyle(Theme.tertiary)
    }
}

/// The rounded square behind avatars, icons and the "+" tile: radius is a fixed share of the size.
enum Tile {
    static let ratio: CGFloat = 0.3
    static func shape(_ size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: size * ratio, style: .continuous)
    }
}

/// "1 folder", "2 folders"; pass the plural for irregular words.
func plural(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
}

/// Says something aloud to VoiceOver: what appears or fails without anyone looking at it. The same words twice within a few
/// seconds are said once (a failure announced where it happens, and again by the pane that shows it).
@MainActor
enum Announce {
    private static var last: (text: String, at: Date)?
    /// Where the words go instead of VoiceOver; the tests replace it (there is no app to post to).
    static var sink: ((String) -> Void)?

    /// A moment after what asked for it, so a window taking the keyboard doesn't talk over it.
    /// `again`: a repeated attempt is news (a refusal at each try), so the same words are said again.
    static func say(_ text: String, again: Bool = false, after delay: Duration = .milliseconds(300)) {
        guard sink != nil || (NSApp != nil && NSWorkspace.shared.isVoiceOverEnabled) else { return }
        if !again, let last, last.text == text, Date().timeIntervalSince(last.at) < 3 { return }
        last = (text, Date())
        if let sink { sink(text); return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            AccessibilityNotification.Announcement(text).post()
        }
    }

    /// Forgets what was last said, so the tests don't depend on each other.
    static func reset() { last = nil; sink = nil }
}
