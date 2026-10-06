import AppKit
import SwiftUI

// The design system's pieces (DESIGN.md is the source of truth). Colour tokens, `Theme.Resolved` and `Theme.Timing`
// live in Theme.swift; the rest of the tokens and the shared components live here.
//
// TOKENS
//   Colours   Theme.bg / rail / popover; text .93, secondary .70, tertiary .58 (a hint on a form is never tertiary);
//             accent (blue: unread, interactive), accentText (links), amber (needs you), red (broken), green (update
//             ready only), onTint (on amber/green fills), claude (Claude settings pane only); stroke, divider,
//             fieldBorder, switchOff. secondary, tertiary, stroke and divider are `Theme.Ink`s: they follow
//             Increase Contrast wherever drawn; the rest of its set is read from `@Environment(\.resolved)`.
//   Radius    Theme.Radius.hub 16 / row 10 (hub - inset; also banners and groups) / field 8 / tile 7 / small 4. All
//             `.continuous`, concentric: use `Theme.Radius.shape(_)`.
//   Fill      Theme.Fill.rest 0 / hover .07 (pointer only) / field .06 / tile .10 (tiles, avatars, bordered buttons) /
//             selected .12 (keyboard pick, selected tab) / pressed .15 / group .045 (settings groups, banners, undo
//             line). Never write `Color.white.opacity(x)` for these.
//   Font      Theme.Typography.title 13 semibold / body 13 / control 12 medium / meta 11 / label 11 semibold (sentence
//             case, secondary) / numeral 11 semibold mono-digit / tile 11 bold rounded / keyhint 11. Nothing below 11.
//             `Theme.Typography.glyph(_ size, weight)` sizes an icon off its box (symbols may be smaller).
//   Space     Theme.Space.hair 2 / xs 4 / sm 6 / md 8 / lg 12 / xl 16.
//   Metrics   pitch 36 (every cell, header, one-line row and footer), bar 46, inset 6, contentEdge 14, twoLineRow 44,
//             taskRow 60, menuRow 28, formRow 36, field/button 28, tab 24, tile 26, avatar 24 ... `line` 30 is the
//             pre-redesign pitch, kept until each surface moves to `pitch`.
//   Motion    Theme.Motion.hover (easeOut .12), fade (.14), move (spring .28), close (spring .20): never a bounce.
//             `.motion(_:value:)` replaces `.animation(_:value:)` and follows Reduce Motion live; with no view,
//             `Theme.Motion.resolve(_:reduce:)` (or `.resolved(reduce:)`), the reduce flag coming from
//             `@Environment(\.accessibilityReduceMotion)` or, in key handlers, `LookoutHub.animate`.
//
// COMPONENTS
//   HoverFillButtonStyle   Hover/active/pressed fill for any button and shape; disabled shows no fill.
//   .rowHighlight(hover:picked:)  A hub row's padding and fill; picked (keyboard) adds the accent bar.
//   .focusRing(radius)     The one focus ring: 1.5pt accent, offset 2 (inset for rows), from @FocusState.
//   .reportsControlFocus(focused)  Tells the key monitor a control has focus (so it keeps Space and Return); `focusRing`
//                          does it for you unless the control keeps its own @FocusState.
//   Focus     Controls are native Buttons (or Menus, Toggles) whose `@FocusState` draws the ring: they are on the Tab ring
//             with Full Keyboard Access and never take focus from a click, so no `.focusable()` on a control that is
//             already one (it would add click focus: a stray ring). List rows are `.focusable(false)`: ↑↓ pick them, Tab
//             walks the chrome (tabs, header actions, footer). `HubController.dropClickFocus` lets go of any focus a click
//             did leave.
//   IconButton, KeyCap, MenuRow, BorderedButton, SwitchStyle, CheckboxStyle, .fieldStyle(), Tabs, SectionHeader, StatusBanner,
//   EmptyBlock, UndoLine (presentation only), Hairline, Avatar, FlowLayout, `.tip(_:_:)` (icon-only controls only).
//   .tile(size) / Tile.shape(size)   A rounded square filled like a tile, radius 27% of its size.
//   plural(n, "folder")    "1 folder", "2 folders"; third arg for irregulars: plural(2, "repository", "repositories").

extension Theme {
    /// All `.continuous` and concentric: an inner radius is its outer one minus the inset between them.
    enum Radius {
        static let hub: CGFloat = 16
        /// Rows, banners, undo lines and settings groups: the hub's radius minus the one outer inset.
        static let row = hub - Metrics.inset
        static let field: CGFloat = 8
        /// Tiles, bordered buttons and tooltips (a 26pt tile at 27%).
        static let tile: CGFloat = 7
        /// Keycaps and small chips.
        static let small: CGFloat = 4

        static func shape(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    }

    /// Translucent white fills, one per state, so hover looks the same everywhere. Under Increase Contrast they go
    /// through `Theme.Resolved.fill`.
    enum Fill {
        static let rest = Color.clear
        static let hover = Color.white.opacity(0.07)
        static let field = Color.white.opacity(0.06)
        /// A field while it has focus (with the accent border).
        static let fieldFocused = Color.white.opacity(0.08)
        static let tile = Color.white.opacity(0.10)
        static let selected = Color.white.opacity(0.12)
        static let pressed = Color.white.opacity(0.15)
        static let group = Color.white.opacity(0.045)

        /// How far a tinted fill (a repository badge that is on) is pressed into.
        enum Tint: Double {
            case rest = 0.15, hover = 0.24, pressed = 0.32
        }

        /// A hue's own fill, for a glyph of the same hue to sit on. Not multiplied by Increase Contrast (see
        /// `Theme.Resolved.fill`): the glyph must keep 3:1 on every level.
        static func tint(_ color: Color, _ level: Tint) -> Color { color.opacity(level.rawValue) }
    }

    enum Typography {
        /// Page, section and group titles; unread row titles.
        static let title = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Read row titles, form labels, menu labels.
        static let body = SwiftUI.Font.system(size: 13)
        /// Tabs, buttons, chips.
        static let control = SwiftUI.Font.system(size: 12, weight: .medium)
        /// Second lines, summaries, hints, tooltip detail.
        static let meta = SwiftUI.Font.system(size: 11)
        /// Group and form section headings: sentence case, in `secondary`.
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// Counts, ages, elapsed time, status words.
        static let numeral = SwiftUI.Font.system(size: 11, weight: .semibold).monospacedDigit()
        /// Tile letters: the tile is fixed, the font doesn't scale.
        static let tile = SwiftUI.Font.system(size: 11, weight: .bold, design: .rounded)
        /// Key equivalents as plain text, in SF Pro (never Rounded: ⌃ must render as ⌃).
        static let keyhint = SwiftUI.Font.system(size: 11)

        /// An icon sized off the box that holds it (symbols are glyphs, not text: the 11pt floor is for text).
        static func glyph(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight)
        }
    }

    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    enum Metrics {
        /// One pitch on both axes: every bar cell (its tile centred), a section header, a one-line row, the footer.
        static let pitch: CGFloat = 36
        /// The bar's depth: a cell's width on the sides, the strip's height along the top and bottom.
        static let bar: CGFloat = 46
        /// The one outer inset around the hub's pieces.
        static let inset: CGFloat = 6
        /// A row's own horizontal padding inside the inset.
        static let rowPadding: CGFloat = 8
        /// Where leading text starts: headers, tabs, dots, group labels, form titles.
        static let contentEdge = inset + rowPadding
        static let dotSlot: CGFloat = 14
        static let avatar: CGFloat = 24
        static let ageColumn: CGFloat = 36
        /// Rows: two lines (inbox, CI, session) and with a task line; menu items; the rows of a settings form (minimum).
        static let twoLineRow: CGFloat = 44
        static let taskRow: CGFloat = 60
        static let menuRow: CGFloat = 28
        static let formRow: CGFloat = 36
        /// A status tile, and the glyph cells beside it.
        static let tile: CGFloat = 26
        /// Fields and bordered buttons.
        static let field: CGFloat = 28
        static let button: CGFloat = 28
        static let tab: CGFloat = 24
        /// An icon button: drawn this big, hit this big.
        static let iconButton: CGFloat = 24
        static let iconHit: CGFloat = 28
        static let banner: CGFloat = 30
        static let undoLine: CGFloat = 32
        static let emptyBlock: CGFloat = 132
    }

    /// Three speeds and no bounce. Pass through `.motion` / `resolve`, which follow Reduce Motion.
    enum Motion {
        /// Fills and tints.
        static let hover = Animation.easeOut(duration: 0.12)
        /// Content in and out, list changes, undo line, sibling page switch.
        static let fade = Animation.easeOut(duration: 0.14)
        /// Expanding, a page sliding in, focus.
        static let move = Animation.spring(duration: 0.28, bounce: 0)
        /// Collapsing.
        static let close = Animation.spring(duration: 0.20, bounce: 0)
        /// What a fade becomes under Reduce Motion.
        static let reduced = Animation.easeOut(duration: 0.10)

        /// The working ring's breathing: the one repeating motion, run by Core Animation (a SwiftUI repeat is forbidden).
        struct Heartbeat: Equatable {
            let period: Double
            let from: Double
            let to: Double
        }
        // The trough holds 3:1 on every surface the ring lands on (ContrastTests), which is why it is not lower.
        static let heartbeat = Heartbeat(period: 1.2, from: 1.0, to: 0.65)

        /// The one place Reduce Motion is decided: fills and fades shorten to a cross-fade, anything spatial is
        /// instant (nothing translates, scales or springs).
        static func resolve(_ animation: Animation, reduce: Bool) -> Animation? {
            guard reduce else { return animation }
            return animation == hover || animation == fade ? reduced : nil
        }
    }
}

extension Animation {
    /// `Theme.Motion.resolve`, for `withAnimation` / `.animation`.
    func resolved(reduce: Bool) -> Animation? { Theme.Motion.resolve(self, reduce: reduce) }
}

extension AnyTransition {
    /// Slides in from an edge; a plain fade with Reduce Motion.
    static func slide(from edge: Edge, reduce: Bool) -> AnyTransition { reduce ? .opacity : .move(edge: edge) }
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
    /// `.animation(_:value:)` that follows Reduce Motion live.
    func motion<V: Equatable>(_ animation: Animation = Theme.Motion.move, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// The hub row's look: 8x6 padding inside a row-radius fill. `hover` is the pointer over it; `picked` the
    /// keyboard's pick, which also gets the accent bar. Pair with `.onHover`.
    func rowHighlight(hover: Bool, picked: Bool = false) -> some View {
        modifier(RowHighlight(hover: hover, picked: picked))
    }

    /// A rounded square filled like a tile (see `Tile`).
    func tile(_ size: CGFloat, fill: Color = Theme.Fill.tile) -> some View {
        frame(width: size, height: size).background(Tile.shape(size).fill(fill)).clipShape(Tile.shape(size))
    }
}

private struct RowHighlight: ViewModifier {
    let hover: Bool
    let picked: Bool
    @Environment(\.resolved) private var resolved

    func body(content: Content) -> some View {
        let fill = picked ? Theme.Fill.selected : hover ? Theme.Fill.hover : Theme.Fill.rest
        content
            .padding(.horizontal, Theme.Metrics.rowPadding)
            .padding(.vertical, 6)
            .background(Theme.Radius.shape(Theme.Radius.row).fill(resolved.fill(fill)))
            .overlay(alignment: .leading) {
                if picked { Capsule().fill(Theme.accent).frame(width: 2, height: 24).padding(.leading, 2) }
            }
            .contentShape(Theme.Radius.shape(Theme.Radius.row))
            .motion(Theme.Motion.hover, value: hover)
            .motion(Theme.Motion.hover, value: picked)
    }
}

// MARK: - Focus

/// Which controls have keyboard focus (the Tab ring), so the hub's key monitor can leave Return and Space to them
/// instead of the picked row (DESIGN.md 6.2). Every control with a ring reports here; the hub owns one (`HubState.controls`).
@MainActor
final class ControlFocus {
    private var holders: Set<UUID> = []
    /// A control has focus.
    var isActive: Bool { !holders.isEmpty }

    func set(_ holder: UUID, focused: Bool) {
        if focused { holders.insert(holder) } else { holders.remove(holder) }
    }
}

private struct ControlFocusReport: ViewModifier {
    let focused: Bool
    @Environment(\.controlFocus) private var controlFocus
    @State private var holder = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: focused) { _, now in controlFocus?.set(holder, focused: now) }
            .onDisappear { controlFocus?.set(holder, focused: false) }
    }
}

extension View {
    /// Reports that this control has keyboard focus (its own `@FocusState`, not a row's pick) to the hub's key
    /// monitor. `.focusRing` does it for the controls whose focus it keeps; one that keeps its own calls this.
    func reportsControlFocus(_ focused: Bool) -> some View { modifier(ControlFocusReport(focused: focused)) }
}

extension EnvironmentValues {
    /// Nil outside the hub (a sheet of components, a settings pane in isolation): nobody is listening.
    @Entry var controlFocus: ControlFocus? = nil
}

private struct FocusRingDrawing: ViewModifier {
    let radius: CGFloat
    let inset: Bool
    let focused: Bool
    @Environment(\.resolved) private var resolved

    func body(content: Content) -> some View {
        // The system's own ring is replaced by ours.
        content
            .focusEffectDisabled()
            .overlay { if focused { ring } }
    }

    /// 1.5pt accent, 2pt off the content; inside it, for rows that sit flush in a list.
    @ViewBuilder private var ring: some View {
        let width = resolved.focusWidth
        if inset {
            Theme.Radius.shape(radius).strokeBorder(Theme.accent, lineWidth: width)
        } else {
            Theme.Radius.shape(radius + 2 + width).strokeBorder(Theme.accent, lineWidth: width).padding(-(2 + width))
        }
    }
}

private struct FocusRing: ViewModifier {
    let radius: CGFloat
    let inset: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused).modifier(FocusRingDrawing(radius: radius, inset: inset, focused: focused))
            .reportsControlFocus(focused)
    }
}

extension View {
    /// The one focus ring (tiles, icon buttons, tabs, chips, menu rows, fields, switches), drawn while the view has
    /// keyboard focus (Tab with Full Keyboard Access): `radius` is the content's own. `inset` draws it inside the
    /// bounds, for rows (use radius 10).
    func focusRing(_ radius: CGFloat, inset: Bool = false) -> some View {
        modifier(FocusRing(radius: radius, inset: inset))
    }

    /// `focusRing` for a view that keeps its own `@FocusState` (to also show a tooltip on focus, say).
    func focusRing(_ radius: CGFloat, inset: Bool = false, isFocused: Bool) -> some View {
        modifier(FocusRingDrawing(radius: radius, inset: inset, focused: isFocused))
    }
}

// MARK: - Buttons

/// Fills its shape on hover (and a stronger one while `active` or pressed), animated; for `.buttonStyle`.
/// The label keeps its own colours: labels that should change on hover read `@Environment(\.hoverFillHovering)`.
/// Disabled: no fill at all, and the label a step quieter.
struct HoverFillButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(Theme.Radius.shape(Theme.Radius.row))
    var rest: Color = Theme.Fill.rest
    var hover: Color = Theme.Fill.hover
    var active: Color = Theme.Fill.selected
    var pressed: Color = Theme.Fill.pressed
    var isActive = false
    /// How far past the drawn shape the button takes clicks, on every side (a 24pt circle hit as 28pt).
    var hitOutset: CGFloat = 0

    init(shape: some Shape = Theme.Radius.shape(Theme.Radius.row), rest: Color = Theme.Fill.rest, hover: Color = Theme.Fill.hover,
         active: Color = Theme.Fill.selected, pressed: Color = Theme.Fill.pressed, isActive: Bool = false, hitOutset: CGFloat = 0) {
        self.hitOutset = hitOutset
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
        @Environment(\.resolved) private var resolved

        var body: some View {
            let hot = enabled && hovering
            let fill = !enabled ? style.rest : configuration.isPressed ? style.pressed : style.isActive ? style.active : hot ? style.hover : style.rest
            configuration.label
                .environment(\.hoverFillHovering, hot)
                .background(style.shape.fill(resolved.fill(fill)))
                .opacity(enabled ? 1 : 0.6)
                .contentShape(style.hitOutset > 0 ? AnyShape(Rectangle().inset(by: -style.hitOutset)) : style.shape)
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

/// A glyph button: 24pt drawn, 28pt to hit, outline symbols at rest and `.fill` ones (the caller's choice) for on.
/// An icon button always has a name for VoiceOver: `help` or `label`.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    /// What VoiceOver says; defaults to `help`. Give one when `help` is empty: icon-only buttons need a label.
    var label: String? = nil
    var detail: String? = nil
    var active = false
    /// Off for a row's action, which the row's keys and VoiceOver actions reach: Tab walks the chrome only (DESIGN.md 6.2).
    var tabStop = true
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let button = Button(action: action) { IconButtonLabel(symbol: symbol, active: active) }
            .buttonStyle(HoverFillButtonStyle(shape: Circle(), hover: Theme.Fill.hover, isActive: active,
                                              hitOutset: (Theme.Metrics.iconHit - Theme.Metrics.iconButton) / 2))
            .focused($focused)
            .focusRing(Theme.Metrics.iconButton / 2, isFocused: focused)
            .reportsControlFocus(focused)
            .accessibilityLabel(label ?? help)
            .accessibilityHint(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "")

        if help.isEmpty {
            reachable(button)
        } else {
            reachable(button.tip(help, detail, focused: focused))
        }
    }

    @ViewBuilder private func reachable(_ view: some View) -> some View {
        if tabStop { view } else { view.focusable(false) }
    }
}

private struct IconButtonLabel: View {
    let symbol: String
    let active: Bool
    @Environment(\.hoverFillHovering) private var hover
    @Environment(\.resolved) private var resolved

    var body: some View {
        Image(systemName: symbol)
            .font(Theme.Typography.glyph(14, .medium))
            .foregroundStyle(active || hover ? Theme.text : resolved.secondary)
            .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
    }
}

/// A plain button with a border: the one text button (Save, Add, Retry, Use a token…).
struct BorderedButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.resolved) private var resolved

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: Theme.Metrics.button)
                .overlay(Theme.Radius.shape(Theme.Radius.tile).strokeBorder(Theme.fieldBorder, lineWidth: resolved.borderWidth))
        }
        .buttonStyle(HoverFillButtonStyle(shape: Theme.Radius.shape(Theme.Radius.tile), rest: Theme.Fill.tile,
                                          hover: Theme.Fill.selected, pressed: Theme.Fill.pressed))
        .focusRing(Theme.Radius.tile)
    }
}

/// A key as a quiet keycap, for the `esc` hint and the footer's key hints: no stroke, SF Pro.
struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(Theme.Typography.keyhint)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(Theme.Radius.shape(Theme.Radius.small).fill(Theme.Fill.tile))
    }
}

/// A line of a menu-like panel, as in NSMenu: symbol column, label, the key that does the same as plain text.
/// `picked` is the menu's own highlight, moved by the arrow keys: it fills like a pick and draws the focus ring.
struct MenuRow: View {
    let symbol: String
    let title: String
    let key: String?
    var picked = false
    /// Told when the Tab ring lands on the row: a menu with the keys has one highlight, which Tab moves as the arrows do.
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(Theme.Typography.glyph(12))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title).font(Theme.Typography.body).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let key { Text(key).font(Theme.Typography.keyhint).foregroundStyle(Theme.secondary) }
            }
            .padding(.horizontal, Theme.Metrics.rowPadding)
            .frame(height: Theme.Metrics.menuRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillButtonStyle(shape: Theme.Radius.shape(Theme.Radius.field), hover: Theme.Fill.selected, isActive: picked))
        .focused($focused)
        .focusRing(Theme.Radius.field, isFocused: focused || picked)
        .reportsControlFocus(focused)
        .onChange(of: focused) { _, now in if now { onFocus?() } }
        .accessibilityLabel(title)
    }
}

// MARK: - Forms

/// A button that draws its label as it is, disabled or not: `.plain` fades a disabled label, and what a switch or
/// checkbox row says stays readable (it draws its own unavailable look).
private struct UnfadedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// A drawn switch, 32 x 20: accent when on, whatever the window's key state (the system one greys out in a panel
/// that isn't key). The whole label row is the target; VoiceOver gets a toggle that says On or Off. Disabled changes
/// the switch only (never fades the label).
struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchRow(configuration: configuration)
    }

    private struct SwitchRow: View {
        let configuration: ToggleStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.resolved) private var resolved
        @Environment(\.accessibilityReduceMotion) private var reduce

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: Theme.Space.md) {
                    configuration.label
                    Spacer(minLength: Theme.Space.md)
                    track(on: on)
                }
                .frame(minHeight: Theme.Metrics.formRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(UnfadedButtonStyle())
            .focusRing(10)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(on ? "On" : "Off")
        }

        /// Unavailable is drawn on the switch alone, as a quiet outline and a grey knob: the label stays as it is, as it
        /// is what the reason beside it explains.
        private func track(on: Bool) -> some View {
            Capsule()
                .fill(!enabled ? resolved.fill(Theme.Fill.field) : on ? Theme.accent : resolved.fill(Theme.switchOff))
                .overlay(Capsule().strokeBorder(!enabled ? resolved.divider : on ? .clear : Theme.fieldBorder, lineWidth: resolved.borderWidth))
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(enabled ? AnyShapeStyle(.white) : AnyShapeStyle(resolved.tertiary)).frame(width: 16, height: 16).padding(2)
                }
                .brightness(hovering && enabled ? 0.06 : 0)
                .frame(width: 32, height: 20)
                .animation(reduce ? nil : Theme.Motion.hover, value: on)
                .motion(Theme.Motion.hover, value: hovering)
        }
    }
}

/// A drawn checkbox for the options of a list (SwitchStyle is for a setting that is on or off): a 14pt box with a
/// `fieldBorder` outline, accent and an `onTint` check when on. Drawn because the system's greys out in a panel that
/// isn't key and its off box is a borderless fill below 3:1. The row is 28pt and all of it is the target.
struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        CheckboxRow(configuration: configuration)
    }

    private struct CheckboxRow: View {
        let configuration: ToggleStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.resolved) private var resolved

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: Theme.Space.md) {
                    box(on: on)
                    configuration.label
                        .foregroundStyle(enabled ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.tertiary))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.Metrics.menuRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(UnfadedButtonStyle())
            .focusRing(Theme.Radius.small + Theme.Space.xs)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(on ? "On" : "Off")
        }

        private func box(on: Bool) -> some View {
            let shape = Theme.Radius.shape(Theme.Radius.small)
            let filled = on && enabled
            return shape
                .fill(filled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(resolved.fill(Theme.Fill.field)))
                .overlay(shape.strokeBorder(filled ? .clear : enabled ? Theme.fieldBorder : resolved.divider, lineWidth: resolved.borderWidth))
                .overlay {
                    if on {
                        Image(systemName: "checkmark").font(Theme.Typography.glyph(9, .heavy))
                            .foregroundStyle(enabled ? AnyShapeStyle(Theme.onTint) : AnyShapeStyle(Theme.tertiary))
                    }
                }
                .brightness(hovering && enabled ? 0.06 : 0)
                .frame(width: 14, height: 14)
                .motion(Theme.Motion.hover, value: on)
                .motion(Theme.Motion.hover, value: hovering)
        }
    }
}

private struct FieldStyle: ViewModifier {
    let focused: Bool
    @Environment(\.resolved) private var resolved

    func body(content: Content) -> some View {
        let shape = Theme.Radius.shape(Theme.Radius.field)
        content
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .padding(.horizontal, 10)
            .frame(height: Theme.Metrics.field)
            .background(shape.fill(resolved.fill(focused ? Theme.Fill.fieldFocused : Theme.Fill.field)))
            .overlay(shape.strokeBorder(focused ? Theme.accent : Theme.fieldBorder, lineWidth: focused ? resolved.focusWidth : resolved.borderWidth))
    }
}

extension View {
    /// A text field's look: 28pt, radius 8, a visible border, and the accent border while `focused` (pass the field's
    /// own `@FocusState`).
    func fieldStyle(focused: Bool = false) -> some View { modifier(FieldStyle(focused: focused)) }
}

// MARK: - Tabs

/// A row of pill tabs, drawn by hand: a non-key panel draws `Picker(.segmented)` grey. Selected is `text` on a tile
/// fill, the rest `secondary`; a count after the label is a numeral in the colour that says how urgent it is (never
/// the selection's). ←/→ switching is the keys' business.
struct Tabs<ID: Hashable>: View {
    struct Tab: Identifiable {
        let id: ID
        var title: String
        var count: Int? = nil
        var countTint: AnyShapeStyle = AnyShapeStyle(Theme.tertiary)
        /// Shown as the system tooltip.
        var help: String? = nil
    }

    /// What VoiceOver calls the group: "Inbox filter".
    let label: String
    let tabs: [Tab]
    let selection: ID
    let select: (ID) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.hair) {
            ForEach(tabs) { tab in TabButton(tab: tab, selected: tab.id == selection) { select(tab.id) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isTabBar)
    }

    private struct TabButton: View {
        let tab: Tab
        let selected: Bool
        let action: () -> Void
        @Environment(\.resolved) private var resolved

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Text(tab.title)
                    if let count = tab.count, count > 0 {
                        Text("\(count)").font(Theme.Typography.numeral).foregroundStyle(tab.countTint)
                    }
                }
                .font(Theme.Typography.control)
                .foregroundStyle(selected ? Theme.text : resolved.secondary)
                .padding(.horizontal, 10)
                .frame(height: Theme.Metrics.tab)
                .fixedSize()
            }
            .buttonStyle(HoverFillButtonStyle(shape: Capsule(), hover: Theme.Fill.hover, active: Theme.Fill.tile, isActive: selected))
            .focusRing(Theme.Metrics.tab / 2)
            .help(tab.help ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

// MARK: - Sections

/// A section's header, 36pt: its title, one status phrase, then its actions. The whole header is the control that
/// gives the section the room (a button behind it: click, Tab and Space, VoiceOver; the chevron only shows on hover or
/// focus, as a hint). Reserve the trailing slots per section, so nothing in the header jumps.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var status: (text: String, color: AnyShapeStyle)? = nil
    /// Makes the status a button ("1 waiting" picks the first one).
    var statusAction: (() -> Void)? = nil
    /// This section is the focused one: `esc` shows beside the title, the chevron points back.
    var focused = false
    /// What the tooltip and VoiceOver say: "Expand Inbox", or "Back to all sections".
    var expandHelp = ""
    /// Click anywhere on the header; nil for a header that isn't a control.
    var onFocus: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            // What is drawn over the button doesn't take its clicks; the trailing actions and a status button do.
            Text(title).font(Theme.Typography.title).foregroundStyle(Theme.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .allowsHitTesting(false)
            if let status {
                statusLabel(status).transition(.opacity)
            }
            Group {
                if focused { Text("esc").font(Theme.Typography.keyhint).foregroundStyle(Theme.secondary) }
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
            trailing
            if onFocus != nil {
                Image(systemName: focused ? "chevron.up" : "chevron.down")
                    .font(Theme.Typography.glyph(11, .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
                    .opacity(hovering || focused || keyboardFocus ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, Theme.Metrics.contentEdge - Theme.Metrics.inset)
        .padding(.trailing, Theme.Space.hair)
        .frame(minHeight: Theme.Metrics.pitch)
        .background { if let onFocus { activation(onFocus) } }
        .onHover { hovering = $0 }
        .motion(Theme.Motion.hover, value: hovering)
        .motion(Theme.Motion.hover, value: keyboardFocus)
        .motion(Theme.Motion.fade, value: status?.text)
    }

    /// The header's own button: no fill (the chevron is its hover cue), the shared ring when Tab lands on it.
    private func activation(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .focused($keyboardFocus)
            .focusRing(Theme.Radius.row, inset: true, isFocused: keyboardFocus)
            .reportsControlFocus(keyboardFocus)
            .tip(expandHelp, focused: keyboardFocus)
            .accessibilityLabel(expandHelp)
    }
}

extension SectionHeader {
    @ViewBuilder fileprivate func statusLabel(_ status: (text: String, color: AnyShapeStyle)) -> some View {
        let text = Text(status.text).font(Theme.Typography.numeral).foregroundStyle(status.color).lineLimit(1)
        if let statusAction {
            Button(action: statusAction) { text.frame(minHeight: Theme.Metrics.iconButton).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .focusRing(Theme.Radius.small)
        } else {
            text.allowsHitTesting(false)
        }
    }
}

/// One thing the user should know, above a list or under a header: an icon, a sentence and up to two buttons.
struct StatusBanner<Actions: View>: View {
    let symbol: String
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.secondary)
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: symbol).font(Theme.Typography.glyph(12)).foregroundStyle(tint).accessibilityHidden(true)
            Text(message).font(Theme.Typography.control).foregroundStyle(Theme.text).lineLimit(2)
            Spacer(minLength: Theme.Space.md)
            actions
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(minHeight: Theme.Metrics.banner)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(Theme.Fill.group))
        .accessibilityElement(children: .contain)
    }
}

extension StatusBanner where Actions == EmptyView {
    init(symbol: String, tint: AnyShapeStyle = AnyShapeStyle(Theme.secondary), message: String) {
        self.init(symbol: symbol, tint: tint, message: message) { EmptyView() }
    }
}

/// A list with nothing in it, and why: two centred lines and at most one action (and a glyph when it says why).
struct EmptyBlock<Action: View>: View {
    let title: String
    var detail: String? = nil
    /// Only when it carries the cause: the red icon of a sign-in problem, the hollow check of "All caught up".
    var symbol: String? = nil
    var symbolTint = AnyShapeStyle(Theme.tertiary)
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            if let symbol {
                Image(systemName: symbol).font(Theme.Typography.glyph(22, .regular)).foregroundStyle(symbolTint)
                    .padding(.bottom, Theme.Space.xs)
                    .accessibilityHidden(true)
            }
            Text(title).font(Theme.Typography.body.weight(.medium)).foregroundStyle(Theme.secondary)
            if let detail { Text(detail).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary) }
            action.padding(.top, Theme.Space.sm)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: Theme.Metrics.emptyBlock)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyBlock where Action == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// "Moved to Done · Undo": the strip under a list after something was cleared. Presentation only: whoever shows it
/// owns the timer, ⌘Z and the announcement.
struct UndoLine: View {
    let message: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(message).font(Theme.Typography.control).foregroundStyle(Theme.text).lineLimit(1)
            Text("·").foregroundStyle(Theme.tertiary).accessibilityHidden(true)
            Button(action: undo) {
                Text("Undo").font(Theme.Typography.control).foregroundStyle(Theme.accentText)
                    .frame(minHeight: Theme.Metrics.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(Theme.Radius.small)
            .accessibilityLabel("Undo")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: Theme.Metrics.undoLine)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(Theme.Fill.group))
        .transition(.opacity.animation(Theme.Motion.fade))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Shapes

/// A 1pt divider in the divider colour. `inset` trims both ends.
struct Hairline: View {
    var axis: Axis = .horizontal
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .padding(axis == .horizontal ? .horizontal : .vertical, inset)
    }
}

/// The rounded square behind avatars, icons and the "+" tile: radius is a fixed share of the size (7 at 26).
enum Tile {
    static let ratio: CGFloat = 0.27
    static func shape(_ size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: size * ratio, style: .continuous)
    }
}

/// "1 folder", "2 folders"; pass the plural for irregular words.
func plural(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
}
