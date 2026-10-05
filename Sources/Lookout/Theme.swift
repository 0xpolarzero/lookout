import AppKit
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let raised = Color.white.opacity(0.045)
    static let hover = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.085)
    static let text = Color.white.opacity(0.93)
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
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
    var detail: String? = nil
    var size: CGFloat = 26
    var tint: Color = Theme.secondary
    var active = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.systemHelp) private var systemHelp

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(active || hover ? Theme.text : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(active ? 0.13 : hover ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)

        // The pill's window is too small to host our tooltip bubble, so it keeps the system one.
        if systemHelp || help.isEmpty {
            button.help(help)
        } else {
            button.tip(help, detail)
        }
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 26

    var body: some View {
        AsyncImage(url: sized) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                Circle().fill(Color.white.opacity(0.1))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.08)))
    }

    private var sized: URL? {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: "\(Int(size * 2))")]
        return comps.url
    }
}

struct CIDot: View {
    let state: CIState
    var size: CGFloat = 8
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .shadow(color: state == .none ? .clear : state.color.opacity(0.6), radius: 3)
            .opacity(state == .pending && breathe ? 0.35 : 1)
            .onAppear { breathe = true }
            .animation(state == .pending ? .easeInOut(duration: 0.9).repeatForever() : .default, value: breathe)
    }
}

struct Chip: View {
    let label: String
    var count: Int? = nil
    var selected = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(selected ? Color.black.opacity(0.8) : Theme.secondary)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Capsule().fill(selected ? Theme.amber : Color.white.opacity(0.1)))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.11 : hover ? 0.06 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke))
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }

    func card() -> some View {
        self
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
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

    func body(content: Content) -> some View {
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
