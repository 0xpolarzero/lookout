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
    /// The hub's outline: decorative, exempt from 3:1.
    static let stroke = Color.white.opacity(0.12)
    static let divider = Color.white.opacity(0.08)
    /// Field and bordered-button outlines (3.11:1).
    static let fieldBorder = Color.white.opacity(0.34)
    /// A switch's track when off (with a `fieldBorder` outline).
    static let switchOff = Color.white.opacity(0.16)

    /// Titles, rows (read or not) and values: 15.95:1.
    static let text = Color.white.opacity(0.93)
    /// Summaries, ages, status words, hints, form details: 9.34:1.
    static let secondary = Color.white.opacity(0.70)
    /// The meta line, placeholders, quiet glyphs: 6.73:1. Never a hint on a form.
    static let tertiary = Color.white.opacity(0.58)

    /// Three hues, one meaning each: amber needs you, red is broken, blue is unread or interactive.
    static let accent = Color(red: 0.40, green: 0.58, blue: 1.0)
    /// The accent as text (links).
    static let accentText = Color(red: 0.52, green: 0.68, blue: 1.0)
    static let amber = Color(red: 0.99, green: 0.74, blue: 0.27)
    static let red = Color(red: 1.0, green: 0.45, blue: 0.43)
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

    /// Increase Contrast and Differentiate Without Colour, read from the system once at the hub's root (see
    /// `themeResolved()`) and handed down as `\.resolved`: views read this, never the two settings themselves. Plain
    /// values, so the tokens' Increase Contrast set can be tested.
    struct Resolved: Equatable {
        var contrast = false
        var differentiate = false

        var stroke: Color { contrast ? Color.white.opacity(0.28) : Theme.stroke }
        var divider: Color { contrast ? Color.white.opacity(0.20) : Theme.divider }
        var secondary: Color { contrast ? Color.white.opacity(0.86) : Theme.secondary }
        var tertiary: Color { contrast ? Color.white.opacity(0.80) : Theme.tertiary }
        /// A step lighter under Increase Contrast: the stronger fills would take `red` text on a picked row below 4.5:1.
        var red: Color { contrast ? Color(red: 1.0, green: 0.58, blue: 0.56) : Theme.red }
        /// Outlines of fields, switches and bordered buttons.
        var borderWidth: CGFloat { contrast ? 1.5 : 1 }
        var focusWidth: CGFloat { contrast ? 2 : 1.5 }
        var arcWidth: CGFloat { contrast ? 2.5 : 2 }

        /// A white fill token, ×1.6 under Increase Contrast.
        func fill(_ fill: Color) -> Color {
            guard contrast else { return fill }
            let c = NSColor(fill)
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
    /// Previews and shots: Differentiate Without Colour on, whatever the system says (it can't be set directly).
    @Entry var previewDifferentiate = false
}

private struct ThemeResolver: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.previewDifferentiate) private var preview

    func body(content: Content) -> some View {
        content.environment(\.resolved, Theme.Resolved(contrast: contrast == .increased, differentiate: differentiate || preview))
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
    }

    var current: Request?
    /// When a tip last closed: the next one shows at once within `Timing.tipChain` of it.
    @ObservationIgnored private var closedAt = Date.distantPast

    /// Whether the next tip should skip its delay: another is showing, or one just closed.
    var chaining: Bool { current != nil || Date().timeIntervalSince(closedAt) < Theme.Timing.tipChain }

    func close(_ id: UUID) {
        guard current?.id == id else { return }
        current = nil
        closedAt = Date()
    }
}

private struct Tip: ViewModifier {
    let title: String
    let detail: String?
    let focused: Bool
    @State private var id = UUID()
    @State private var anchor = CGRect.zero
    @State private var pending: Task<Void, Never>?
    @Environment(\.tipCenter) private var center
    @Environment(\.previewTip) private var previewTip
    @Environment(\.systemHelp) private var systemHelp

    @ViewBuilder func body(content: Content) -> some View {
        // No tooltip layer above (or one too small to host the bubble): the system tooltip says the same.
        if center == nil || systemHelp {
            content.help(detail.map { $0.isEmpty ? title : "\(title)\n\($0)" } ?? title)
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
                inside ? schedule(after: Theme.Timing.tooltip) : hide()
            }
            .onChange(of: focused) { _, focused in
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
        center?.current = TipCenter.Request(id: id, title: title, detail: detail, anchor: anchor)
    }
}

private struct TipBubble: View {
    let request: TipCenter.Request
    let bounds: CGSize
    @State private var size = CGSize.zero

    /// A key equivalent ("⌘,", "⌫", "Esc") rather than a sentence: it goes after the label, on one line.
    private var key: String? {
        guard let detail = request.detail, !detail.isEmpty, detail.count <= 8, !detail.contains(" "), !detail.contains("\n") else { return nil }
        return detail
    }

    var body: some View {
        Group {
            if let key {
                HStack(spacing: Theme.Space.md) {
                    Text(request.title).foregroundStyle(Theme.text)
                    Text(key).foregroundStyle(Theme.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.hair) {
                    Text(request.title).foregroundStyle(Theme.text)
                    if let detail = request.detail, !detail.isEmpty {
                        Text(detail)
                            .foregroundStyle(Theme.secondary)
                            .frame(width: Self.width(of: detail), alignment: .leading)
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
        .offset(placement)
        .opacity(size == .zero ? 0 : 1)
        .allowsHitTesting(false)
    }

    /// Centered over the anchor, clamped inside the panel; flips below when there's no room above.
    private var placement: CGSize {
        let a = request.anchor
        let margin: CGFloat = 8
        let x = min(max(a.midX - size.width / 2, margin), max(margin, bounds.width - margin - size.width))
        let y = a.minY - size.height - 6 >= margin ? a.minY - size.height - 6 : a.maxY + 6
        return CGSize(width: x, height: y)
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
    @Entry var tipCenter: TipCenter? = nil
}

private struct TipSpaceModifier: ViewModifier {
    @State private var center = TipCenter()
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(TipSpace.name))
            .environment(\.tipCenter, center)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay(alignment: .topLeading) {
                if let request = center.current {
                    TipBubble(request: request, bounds: size)
                        .transition(.opacity.animation(Theme.Motion.hover))
                }
            }
    }
}

extension View {
    /// Hosts tooltips for everything inside (use once, at the root of the panel).
    func tipSpace() -> some View { modifier(TipSpaceModifier()) }

    /// A tooltip for an icon-only control: `detail` is its key, or a short sentence. `focused` (the control's own
    /// focus) shows it after a second for keyboard users.
    func tip(_ title: String, _ detail: String? = nil, focused: Bool = false) -> some View {
        modifier(Tip(title: title, detail: detail, focused: focused))
    }
}
