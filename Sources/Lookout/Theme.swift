import AppKit
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let raised = Color.white.opacity(0.045)
    static let hover = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.085)
    static let text = Color.white.opacity(0.93)
    /// ~7.97:1 on `bg`.
    static let secondary = Color.white.opacity(0.64)
    /// ~4.67:1 on `bg` (was .34, 3.1:1). Still clearly below `secondary`.
    static let tertiary = Color.white.opacity(0.46)
    static let accent = Color(red: 0.40, green: 0.58, blue: 1.0)
    static let amber = Color(red: 0.99, green: 0.74, blue: 0.27)
    static let green = Color(red: 0.32, green: 0.82, blue: 0.50)
    static let red = Color(red: 0.97, green: 0.38, blue: 0.38)
    static let purple = Color(red: 0.68, green: 0.55, blue: 1.0)
    /// Claude's clay, for anything about Claude sessions.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// Project colours for Claude sessions: as far apart as possible, and nowhere near the status colours (amber
    /// needs you, blue unread, clay working) or CI's red. In assignment order, so the first projects differ most.
    static let projectColors: [Color] = [
        Color(red: 0.30, green: 0.82, blue: 0.47),  // green
        Color(red: 0.67, green: 0.52, blue: 1.00),  // violet
        Color(red: 0.96, green: 0.42, blue: 0.75),  // pink
        Color(red: 0.24, green: 0.82, blue: 0.93),  // cyan
        Color(red: 0.78, green: 0.90, blue: 0.24),  // lime
        Color(red: 0.86, green: 0.86, blue: 0.90),  // silver
    ]
    static let projectColorNames = ["Green", "Violet", "Pink", "Cyan", "Lime", "Silver"]
}

func shortAgo(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    if s < 7 * 86400 { return "\(s / 86400)d" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    /// What VoiceOver says; defaults to `help`. Give one when `help` is empty: icon-only buttons need a label.
    var label: String? = nil
    var detail: String? = nil
    var size: CGFloat = 26
    var tint: Color = Theme.secondary
    var active = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) { IconButtonLabel(symbol: symbol, size: size, tint: tint, active: active) }
            .buttonStyle(HoverFillButtonStyle(shape: Circle(), hover: Color.white.opacity(0.08), isActive: active))
            .accessibilityLabel(label ?? help)
            .accessibilityHint(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "")

        // The pill's window is too small to host our tooltip bubble: `.tip` falls back to the system one there.
        if help.isEmpty {
            button
        } else {
            button.tip(help, detail)
        }
    }
}

private struct IconButtonLabel: View {
    let symbol: String
    let size: CGFloat
    let tint: Color
    let active: Bool
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(active || hover ? Theme.text : tint)
            .frame(width: size, height: size)
    }
}

extension IconButton {
    /// The hub's three button sizes: one per kind of place, so the same action looks the same everywhere.
    enum Size {
        /// The bar and its trailing group (pin, repositories, settings).
        static let bar: CGFloat = 28
        /// A section header's actions (mark all read, back).
        static let header: CGFloat = 24
        /// A row's hover actions, in their capsule.
        static let row: CGFloat = 22
    }
}

/// A key as printed on a keycap, e.g. "Esc" or "⌘K": one look everywhere a key is shown.
struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 26
    /// Shown as initials until (or unless) the picture is there.
    var name: String?

    @State private var loaded: (url: URL, image: NSImage)?

    var body: some View {
        let sized = Self.sizedURL(url, size: size)
        // A cached image is there on the first frame; otherwise a placeholder, then a quick fade-in.
        let image = loaded.flatMap { $0.url == sized ? $0.image : nil } ?? ImageCache.shared.cached(sized)
        ZStack {
            Circle().fill(Color.white.opacity(0.1))
            if image == nil { placeholder }
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.08)))
        .task(id: sized) {
            guard let sized, ImageCache.shared.cached(sized) == nil else { loaded = nil; return }
            loaded = nil
            let img = await ImageCache.shared.load(sized)
            guard !Task.isCancelled, let img else { return }
            withAnimation(.easeOut(duration: 0.15)) { loaded = (sized, img) }
        }
    }

    /// Initials of the name, or a person glyph without one.
    @ViewBuilder private var placeholder: some View {
        let initials = name.map { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap(\.first).map(String.init).joined().uppercased() } ?? ""
        if initials.isEmpty {
            Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(Color.white.opacity(0.35))
        } else {
            Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(Color.white.opacity(0.55))
        }
    }

    /// The avatar URL asking GitHub for twice the point size, in pixels.
    static func sizedURL(_ url: URL?, size: CGFloat) -> URL? {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: "\(Int(size * 2))")]
        return comps.url
    }
}

struct CIDot: View {
    let state: CIState
    var size: CGFloat = 8

    var body: some View {
        if state == .pending {
            // Breathing: a render-server animation, with no glow (a shadow can't animate cheaply).
            Pulse(from: 1, to: 0.35, duration: 0.9) {
                Circle().fill(state.color).frame(width: size, height: size)
            }
            .frame(width: size, height: size)
        } else {
            Circle()
                .fill(state.color)
                .frame(width: size, height: size)
                .shadow(color: state == .none ? .clear : state.color.opacity(0.6), radius: 3)
        }
    }
}

struct Chip: View {
    let label: String
    var count: Int? = nil
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                if let count, count > 0 { CountBadge(count, tint: selected ? Theme.amber : nil) }
            }
            .font(Theme.Typography.control)
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: Theme.Metrics.chip)
        }
        .buttonStyle(HoverFillButtonStyle(shape: Capsule(), hover: Theme.Fill.field, active: Theme.Fill.selected, isActive: selected))
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: Theme.Metrics.field)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.Fill.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.stroke))
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }

    func card() -> some View {
        self
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg + 2, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg + 2, style: .continuous).strokeBorder(Theme.stroke))
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

/// A quick, styled tooltip (the system one waits ~1s and looks out of place on the dark panel).
/// Badges only *request* a tooltip; the nearest `.tipSpace()` draws it in one top layer, so nothing
/// (headers, neighbouring rows, scroll views) can cover or clip it.
@Observable
final class TipCenter {
    struct Request: Equatable {
        let id: UUID
        let title: String
        let detail: String?
        var anchor: CGRect
    }

    var current: Request?
}

private struct Tip: ViewModifier {
    let title: String
    let detail: String?
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
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        show()
                    }
                } else if center?.current?.id == id {
                    center?.current = nil
                }
            }
            .onDisappear { if center?.current?.id == id { center?.current = nil } }
    }

    private func show() {
        center?.current = TipCenter.Request(id: id, title: title, detail: detail, anchor: anchor)
    }
}

private struct TipBubble: View {
    let request: TipCenter.Request
    let bounds: CGSize
    @State private var size = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text)
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: Self.width(of: detail), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
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
        let font = NSFont.systemFont(ofSize: 10.5)
        let widest = text.split(separator: "\n").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(ceil(widest) + 2, 210)
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
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                }
            }
    }
}

extension View {
    /// Hosts tooltips for everything inside (use once, at the root of the panel).
    func tipSpace() -> some View { modifier(TipSpaceModifier()) }

    func tip(_ title: String, _ detail: String? = nil) -> some View {
        modifier(Tip(title: title, detail: detail))
    }
}
