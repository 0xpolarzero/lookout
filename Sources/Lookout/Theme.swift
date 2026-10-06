import AppKit
import SwiftUI

enum Theme {
    // MARK: Colour
    // Dark only and opaque, on purpose (DESIGN.md 3.1). Contrast figures are on `bg`; ContrastTests holds the full table.

    static let bg = Color(red: 0.078, green: 0.078, blue: 0.086)
    /// The side-edge bar column: a step above `bg`, drawn over it.
    static let rail = Color.white.opacity(0.025)
    /// Tooltip bubbles and menus, a step above `bg` (#2B2B2D).
    static let popover = Color(red: 0.169, green: 0.169, blue: 0.176)
    /// The update download's unfinished ring, on the tile: a groove darker than the tile, in both modes. A lighter track
    /// (a white fill, ×1.6 under Increase Contrast) left the finished arc 2:1 to 2.9:1 from it.
    static let downloadTrack = Color.black.opacity(0.4)
    /// The hub's outline: decorative, exempt from 3:1.
    static let stroke = Ink(\.stroke)
    static let divider = Ink(\.divider)
    /// Field and bordered-button outlines (3.11:1).
    static let fieldBorder = Color.white.opacity(0.34)
    /// A switch's track when off (with a `fieldBorder` outline).
    static let switchOff = Color.white.opacity(0.16)

    /// Titles, rows (read or not) and values: 15.95:1.
    static let text = Color.white.opacity(0.93)
    /// Summaries, ages, status words, hints, form details: 9.34:1.
    static let secondary = Ink(\.secondary)
    /// The meta line, placeholders, quiet glyphs: 6.73:1. Never a hint on a form.
    static let tertiary = Ink(\.tertiary)

    /// Three hues, one meaning each: amber needs you, red is broken, blue is unread or interactive.
    static let accent = Color(red: 0.40, green: 0.58, blue: 1.0)
    /// The accent as text (links).
    static let accentText = Color(red: 0.52, green: 0.68, blue: 1.0)
    static let amber = Color(red: 0.99, green: 0.74, blue: 0.27)
    static let red = Color(red: 1.0, green: 0.47, blue: 0.45)
    /// The update-ready tile, and nothing else.
    static let green = Color(red: 0.32, green: 0.82, blue: 0.50)
    /// Text and glyphs on an amber or green fill.
    static let onTint = Color.black.opacity(0.85)
    /// The Claude mark in the Claude settings pane, and nothing else.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    /// Project colours for the dots in group headers and menus (6pt): in assignment order, so the first projects
    /// differ most, and apart from the status hues.
    static let projectColors: [Color] = [
        Color(red: 0.67, green: 0.52, blue: 1.00),  // violet
        Color(red: 0.96, green: 0.42, blue: 0.75),  // pink
        Color(red: 0.24, green: 0.82, blue: 0.93),  // cyan
        Color(red: 0.86, green: 0.86, blue: 0.90),  // silver
    ]
    static let projectColorNames = ["Violet", "Pink", "Cyan", "Silver"]

    // MARK: Resolved

    /// A token that follows Increase Contrast by itself: it takes its value from `\.resolved` wherever it is drawn
    /// (`foregroundStyle`, `fill`, `strokeBorder`), so a view can't forget to. Use it where SwiftUI wants a
    /// `ShapeStyle`; `AnyShapeStyle` carries it through a property.
    struct Ink: ShapeStyle {
        let token: KeyPath<Theme.Resolved, Color> & Sendable
        init(_ token: KeyPath<Theme.Resolved, Color> & Sendable) { self.token = token }

        func resolve(in environment: EnvironmentValues) -> Color { environment.resolved[keyPath: token] }
    }

    /// Increase Contrast and Differentiate Without Colour, read from the system once at the hub's root (see
    /// `themeResolved()`) and handed down as `\.resolved`: views read this (or draw an `Ink`), never the two settings themselves. Plain
    /// values, so the tokens' Increase Contrast set can be tested.
    struct Resolved: Equatable {
        var contrast = false
        /// Drawn by the waiting tile and the lit gear (an `onTint` inner stroke) and the unread dot (a white ring).
        var differentiate = false

        var stroke: Color { Color.white.opacity(contrast ? 0.28 : 0.12) }
        var divider: Color { Color.white.opacity(contrast ? 0.20 : 0.08) }
        var secondary: Color { Color.white.opacity(contrast ? 0.86 : 0.70) }
        var tertiary: Color { Color.white.opacity(contrast ? 0.80 : 0.58) }
        /// `red` as text on a fill (a chip's check count): lighter under Increase Contrast, whose ×1.6 fills would take
        /// `Theme.red` below 4.5:1 once pressed. Glyphs and text on the page keep `Theme.red`.
        var red: Color { contrast ? Color(red: 1.0, green: 0.66, blue: 0.64) : Theme.red }
        /// Outlines of fields, switches and bordered buttons.
        var borderWidth: CGFloat { contrast ? 1.5 : 1 }
        var focusWidth: CGFloat { contrast ? 2 : 1.5 }
        /// The working ring: `secondary`, and `text` under Increase Contrast.
        var workingRing: Color { contrast ? Theme.text : secondary }

        /// A white fill token, ×1.6 under Increase Contrast. A tinted fill is left alone: its glyph is the same hue, so
        /// a stronger fill would take the glyph's contrast down, not up (`Theme.Fill.tint`).
        func fill(_ fill: Color) -> Color {
            guard contrast, let c = NSColor(fill).usingColorSpace(.sRGB), c.saturationComponent < 0.01 else { return fill }
            return Color(nsColor: c.withAlphaComponent(min(1, c.alphaComponent * 1.6)))
        }
    }

    // MARK: Timing

    /// Every delay in the hover choreography, in one place (DESIGN.md 3.6, 6.1).
    enum Timing {
        /// The pointer must settle this long before the first panel opens (later ones switch at once).
        static let dwell: Duration = .milliseconds(100)
        /// Leaving a section or panel closes it only after this, so travelling between bar and panel never does.
        static let leaveGrace: Duration = .milliseconds(120)
        /// A tooltip shows after this; instantly when another closed less than `tipChain` ago.
        static let tooltip: Duration = .milliseconds(400)
        static let tipChain: TimeInterval = 0.6
        /// A tooltip on keyboard focus.
        static let tooltipFocus: Duration = .seconds(1)
    }
}

extension EnvironmentValues {
    @Entry var resolved = Theme.Resolved()
}

private struct ThemeResolver: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    func body(content: Content) -> some View {
        content.environment(\.resolved, Theme.Resolved(contrast: contrast == .increased, differentiate: differentiate))
    }
}

extension View {
    /// Resolves Increase Contrast and Differentiate Without Colour into `\.resolved`: once, at the root.
    func themeResolved() -> some View { modifier(ThemeResolver()) }
}

func shortAgo(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    if s < 7 * 86400 { return "\(s / 86400)d" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

/// `shortAgo` for a sentence: "just now", "3m ago", "on Sep 28" (never "now ago" or "Sep 28 ago").
func agoPhrase(_ date: Date, now: Date = Date()) -> String {
    let short = shortAgo(date, now: now)
    if short == "now" { return "just now" }
    return now.timeIntervalSince(date) < 7 * 86400 ? "\(short) ago" : "on \(short)"
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = Theme.Metrics.avatar
    /// Shown as initials until (or unless) the picture is there.
    var name: String?

    @State private var loaded: (url: URL, image: NSImage)?
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let sized = Self.sizedURL(url, size: size)
        // A cached image is there on the first frame; otherwise a placeholder, then a quick fade-in.
        let image = loaded.flatMap { $0.url == sized ? $0.image : nil } ?? ImageCache.shared.cached(sized)
        ZStack {
            Circle().fill(Theme.Fill.tile)
            if image == nil { placeholder }
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.stroke))
        // Decoration: the name is always beside it.
        .accessibilityHidden(true)
        .task(id: sized) {
            guard let sized, ImageCache.shared.cached(sized) == nil else { loaded = nil; return }
            loaded = nil
            let img = await ImageCache.shared.load(sized)
            guard !Task.isCancelled, let img else { return }
            withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) { loaded = (sized, img) }
        }
    }

    /// The name's first letter, or a person glyph without one.
    @ViewBuilder private var placeholder: some View {
        let letter = name?.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? ""
        if letter.isEmpty {
            Image(systemName: "person.fill").font(Theme.Typography.glyph(size * 0.5, .regular)).foregroundStyle(Theme.tertiary)
        } else {
            Text(letter).font(Theme.Typography.label).foregroundStyle(Theme.secondary)
        }
    }

    /// The avatar URL asking GitHub for twice the point size, in pixels.
    static func sizedURL(_ url: URL?, size: CGFloat) -> URL? {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: "\(Int(size * 2))")]
        return comps.url
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                let prev = rows[rows.count - 1]
                rows.append(Row(y: prev.y + prev.height + spacing))
            }
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: - Tooltip

/// A quick, styled tooltip for icon-only controls: the label and, after it on the same line, its key ("Settings  ⌘,").
/// Anything with visible text uses the system's `.help`; a tip never carries primary information. Controls only
/// *request* a tooltip; the nearest `.tipSpace()` draws it in one top layer, so nothing (headers, neighbouring
/// rows, scroll views) can cover or clip it.
@Observable
final class TipCenter {
    struct Request: Equatable {
        let id: UUID
        let title: String
        let detail: String?
        var anchor: CGRect
        /// Which side of the anchor it goes on instead of over or under it (a cell of a bar on a side edge).
        var beside: HorizontalEdge? = nil
    }

    var current: Request?
    /// When a tip last closed: the next one shows at once within `Timing.tipChain` of it.
    @ObservationIgnored private var closedAt = Date.distantPast

    /// Whether the next tip should skip its delay: another is showing, or one just closed.
    var chaining: Bool { current != nil || Date().timeIntervalSince(closedAt) < Theme.Timing.tipChain }

    /// The pointer is over the bubble itself: it can be read, magnified and panned onto (WCAG 1.4.13, hoverable).
    @ObservationIgnored private var overBubble = false
    @ObservationIgnored private var leaving: Task<Void, Never>?

    func present(_ request: Request) {
        leaving?.cancel()
        overBubble = false
        current = request
    }

    func close(_ id: UUID) {
        guard current?.id == id else { return }
        leaving?.cancel()
        overBubble = false
        current = nil
        closedAt = Date()
    }

    /// The pointer left the control or the bubble: the tip closes after the leave grace unless it is on the other by then,
    /// so crossing the gap between them keeps it.
    func leave(_ id: UUID) {
        leaving?.cancel()
        leaving = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Theme.Timing.leaveGrace)
            guard !Task.isCancelled, let self, !overBubble else { return }
            close(id)
        }
    }

    /// Esc: the bubble goes and the pointer or the focus stays where it is (WCAG 1.4.13). A tip shows again only when the
    /// pointer or the keyboard comes to a control anew, which asks for it.
    func dismiss() {
        if let id = current?.id { close(id) }
    }

    /// The pointer is back on the control, or has reached the bubble.
    func hold(bubble: Bool) {
        leaving?.cancel()
        if bubble { overBubble = true }
    }

    func releaseBubble(_ id: UUID) {
        overBubble = false
        leave(id)
    }
}

private struct Tip: ViewModifier {
    let title: String
    let detail: String?
    let focused: Bool
    /// Also on pointer hover; off where the system's `.help` already does that (a row's, with the keyboard's pick as the
    /// only thing this one adds).
    let hover: Bool
    let beside: HorizontalEdge?
    @State private var id = UUID()
    @State private var anchor = CGRect.zero
    @State private var pending: Task<Void, Never>?
    @Environment(\.tipCenter) private var center
    @Environment(\.previewTip) private var previewTip
    @Environment(\.systemHelp) private var systemHelp

    @ViewBuilder func body(content: Content) -> some View {
        // No tooltip layer above (or one too small to host the bubble): the system tooltip says the same.
        if center == nil || systemHelp {
            if hover { content.help(detail.map { $0.isEmpty ? title : "\(title)\n\($0)" } ?? title) } else { content }
        } else {
            styled(content)
        }
    }

    private func styled(_ content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TipSpace.name)) } action: { frame in
                anchor = frame
                if center?.current?.id == id { center?.current?.anchor = frame }
            }
            .onAppear {
                if previewTip == title {
                    DispatchQueue.main.async { show() }
                }
            }
            .onHover { inside in
                guard hover else { return }
                if inside { center?.hold(bubble: false); schedule(after: Theme.Timing.tooltip) } else { pending?.cancel(); center?.leave(id) }
            }
            // `initial`: a row the keyboard picked before it was on screen has its tip too.
            .onChange(of: focused, initial: true) { _, focused in
                focused ? schedule(after: Theme.Timing.tooltipFocus) : hide()
            }
            .onDisappear { hide() }
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        // Right after another tip, none of the wait: sweeping along a row of buttons reads them all.
        let wait = center?.chaining == true ? .zero : delay
        pending = Task {
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            show()
        }
    }

    private func hide() {
        pending?.cancel()
        center?.close(id)
    }

    private func show() {
        center?.present(TipCenter.Request(id: id, title: title, detail: detail, anchor: anchor, beside: beside))
    }
}

/// Where a tip's bubble goes (tests read it too).
enum TipPlacement {
    /// Centered over the anchor, clamped inside the panel on both axes; flips below when there's no room above. `beside`: level with the
    /// anchor's centre and wholly off to one side of it, so a bar's tip never covers the cells next to the one it names.
    static func origin(anchor a: CGRect, size: CGSize, bounds: CGSize, beside: HorizontalEdge?) -> CGPoint {
        let margin: CGFloat = 8
        if let beside {
            let x = beside == .leading ? a.minX - size.width - 6 : a.maxX + 6
            let y = min(max(a.midY - size.height / 2, margin), max(margin, bounds.height - margin - size.height))
            return CGPoint(x: min(max(x, margin), max(margin, bounds.width - margin - size.width)), y: y)
        }
        let x = min(max(a.midX - size.width / 2, margin), max(margin, bounds.width - margin - size.width))
        let above = a.minY - size.height - 6
        let below = a.maxY + 6
        // Over the anchor when it fits there, else under it, and in either case inside the window: a bubble too tall for both
        // sits as low as the window lets it.
        let y = above >= margin ? above : min(below, max(margin, bounds.height - margin - size.height))
        return CGPoint(x: x, y: y)
    }
}

private struct TipBubble: View {
    let request: TipCenter.Request
    let center: TipCenter
    let bounds: CGSize
    /// Tells the window where the bubble is, and the way to it from its control, as it moves.
    let report: (CGRect) -> Void
    /// Tells the window whether the pointer is on the bubble.
    let hover: (Bool) -> Void
    @State private var size = CGSize.zero

    /// How wide the text may be: what the window leaves the bubble, and a sentence's worth at most. A long title wraps.
    private var textLimit: CGFloat { min(max(bounds.width - 2 * Self.margin - 16, 80), 360) }
    private static let margin: CGFloat = 8
    private static let lineHeight: CGFloat = 15
    /// The most lines of detail a bubble shows, fewer in a window too short for them: what is cut is in the control's `.help`
    /// and its VoiceOver hint, and a bubble never reaches past the window.
    private static let detailLines = 12

    private var detailLineLimit: Int {
        // The window less its margins, the bubble's padding and room for a title of three lines.
        let room = bounds.height - 2 * Self.margin - 8 - 3 * Self.lineHeight
        return min(Self.detailLines, max(1, Int(room / Self.lineHeight)))
    }

    /// A key equivalent ("⌘,", "⌫", "Esc") rather than a sentence: it goes after the label, on one line.
    private var key: String? {
        guard let detail = request.detail, !detail.isEmpty, detail.count <= 8, !detail.contains(" "), !detail.contains("\n") else { return nil }
        return detail
    }

    var body: some View {
        Group {
            if let key {
                HStack(spacing: Theme.Space.md) {
                    title
                    Text(key).foregroundStyle(Theme.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.hair) {
                    title
                    if let detail = request.detail, !detail.isEmpty {
                        Text(detail)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(detailLineLimit)
                            .frame(width: min(Self.width(of: detail), textLimit), alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.Radius.shape(Theme.Radius.tile).fill(Theme.popover))
        .overlay(Theme.Radius.shape(Theme.Radius.tile).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        // The bubble keeps itself open while the pointer is on it (it can be read and magnified), and closes a moment after
        // the pointer leaves it. Invisible until it is measured, so it takes no pointer before then.
        .onHover { inside in
            hover(inside)
            if inside { center.hold(bubble: true) } else { center.releaseBubble(request.id) }
        }
        .offset(placement)
        .opacity(size == .zero ? 0 : 1)
        .allowsHitTesting(size != .zero)
        .onChange(of: region, initial: true) { _, region in report(region) }
    }

    private var title: some View {
        Text(request.title).foregroundStyle(Theme.text)
            .frame(maxWidth: textLimit, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The bubble and the gap between it and its control: where the pointer can be on its way to the bubble. Nothing until
    /// the bubble is measured.
    private var region: CGRect {
        size == .zero ? .zero : request.anchor.union(CGRect(origin: TipPlacement.origin(anchor: request.anchor, size: size, bounds: bounds, beside: request.beside), size: size))
    }

    private var placement: CGSize {
        let origin = TipPlacement.origin(anchor: request.anchor, size: size, bounds: bounds, beside: request.beside)
        return CGSize(width: origin.x, height: origin.y)
    }

    /// Natural width of the widest line, capped so long details wrap instead of stretching the bubble.
    private static func width(of text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let widest = text.split(separator: "\n").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(ceil(widest) + 2, 220)
    }
}

enum TipSpace {
    static let name = "tips"
}

extension EnvironmentValues {
    @Entry var systemHelp = false
    /// Where the tips of the bar's cells go: to the left (the bar on the right edge) or right (on the left) of the cell. Nil
    /// along the top and bottom, where over or under the cell leaves the bar's other cells alone.
    @Entry var tipBeside: HorizontalEdge? = nil
    @Entry var tipCenter: TipCenter? = nil
}

private struct TipSpaceModifier: ViewModifier {
    /// Where a bubble and the way to it are in this space, for a window that takes the mouse there (`.zero`: none).
    let region: (CGRect) -> Void
    /// Whether the pointer is on the bubble: a window that closes when the pointer leaves it keeps it for that too.
    let bubble: (Bool) -> Void
    /// Where an open tip is the first thing Esc closes: the one every window shares unless a test gives its own.
    let escape: EscapeRoute?
    @State private var center = TipCenter()
    @State private var size = CGSize.zero
    @State private var escapeID = UUID()

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(TipSpace.name))
            .environment(\.tipCenter, center)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay(alignment: .topLeading) {
                if let request = center.current {
                    TipBubble(request: request, center: center, bounds: size, report: region, hover: bubble)
                        .transition(.opacity.animation(Theme.Motion.hover))
                }
            }
            // An open tip is the first thing Esc closes, so it can be dismissed without moving the pointer or the focus.
            .onChange(of: center.current?.id, initial: true) { _, id in
                let route = escape ?? .shared
                if id != nil { route.add(escapeID) { center.dismiss() } } else { route.remove(escapeID) }
                if id == nil { region(.zero); bubble(false) }
            }
            .onDisappear { (escape ?? .shared).remove(escapeID); region(.zero); bubble(false) }
    }
}

extension View {
    /// Hosts tooltips for everything inside (use once, at the root of the panel).
    /// `region` hears where the bubble and the way to it lie (`.zero` when none is up), `bubble` whether the pointer is on it.
    func tipSpace(region: @escaping (CGRect) -> Void = { _ in }, bubble: @escaping (Bool) -> Void = { _ in },
                  escape: EscapeRoute? = nil) -> some View {
        modifier(TipSpaceModifier(region: region, bubble: bubble, escape: escape))
    }

    /// A tooltip for an icon-only control: `detail` is its key, or a short sentence. `focused` (the control's own
    /// focus) shows it after a second for keyboard users.
    func tip(_ title: String, _ detail: String? = nil, focused: Bool = false, hover: Bool = true, beside: HorizontalEdge? = nil) -> some View {
        modifier(Tip(title: title, detail: detail, focused: focused, hover: hover, beside: beside))
    }
}
