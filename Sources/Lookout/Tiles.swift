import AppKit
import SwiftUI

// A session's tile, as the bar draws it.

extension AgentRow {
    /// Claude is answering, or a subagent or command it started is still running after the turn. Never while it waits
    /// for you, however it waits (stopped mid-turn, or finished with a question): its amber fill is the mark.
    var working: Bool { status != .blocked && (session.running || !tasks.isEmpty) }
}

/// A session's tile: its two letters (or emoji) on its status colour. Working agents carry the working arc;
/// pending sessions are a size smaller and dimmer.
struct AgentTile: View {
    let row: AgentRow
    var size: CGFloat = 26
    var selected = false

    var body: some View {
        // Busy: the arc, on the neutral face, where it holds 3:1; unread stays a dot.
        let busy = row.working
        AgentTileFace(row: row, size: size, tint: busy ? nil : row.tint)
            .overlay { WorkingArc(size: size, working: busy) }
            .overlay(alignment: .topTrailing) { if busy && row.unread { UnreadDot().offset(x: 3, y: -3) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.session.title)
            .accessibilityValue(row.stateName)
            .focusRing(size * Tile.ratio, isFocused: selected)
            // The project's colour, as an underline.
            .overlay(alignment: .bottom) {
                if let color = row.color {
                    Capsule().fill(color.opacity(row.pending ? 0.6 : 1))
                        .frame(width: size * 0.62, height: max(2.5, size * 0.12))
                        .offset(y: size * 0.12 + 2.5)
                }
            }
    }
}

/// The tile itself, without its marks.
private struct AgentTileFace: View {
    let row: AgentRow
    var size: CGFloat
    /// The fill, or nil for the neutral tile.
    var tint: Color?
    @Environment(\.resolved) private var resolved

    var body: some View {
        let shape = Tile.shape(size)
        let emoji = row.label.unicodeScalars.first.map { $0.properties.isEmoji && $0.value > 0xFF } ?? false
        Group {
            if let icon = row.icon {
                Image(systemName: icon)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
            } else {
                Text(row.label)
                    .font(.system(size: emoji ? size * 0.55 : size * 0.4, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
            .foregroundStyle(tint == nil ? Theme.text.opacity(0.88) : Theme.onTint)
            .frame(width: size, height: size)
            .background(shape.fill(tint ?? Theme.Fill.tile))
            // Waiting is amber, which a colour-blind eye may not tell from the grey tile: a dark outline says it too.
            .overlay { if resolved.differentiate, tint == Theme.amber { shape.inset(by: 1).strokeBorder(Theme.onTint, lineWidth: 1.5) } }
            .opacity(row.pending ? 0.55 : 1)
    }
}

/// Unread on a tile that is busy: a 7pt accent dot with a halo in the bar's own colour.
private struct UnreadDot: View {
    var body: some View {
        Circle().fill(Theme.accent)
            .frame(width: 7, height: 7)
            .padding(1.5)
            .background(Circle().fill(Theme.bg))
            .accessibilityHidden(true)
    }
}

/// A session's tile in the bar; opens it in Claude. Its highlight is compared here, in its own body, so hovering a
/// tile doesn't rebuild the whole hub. No tooltip: hovering opens the sessions' panel, a row beside each tile.
struct BarTile: View {
    let row: AgentRow
    let size: CGFloat
    let store: Store
    let ui: UIState
    let hub: HubState

    var body: some View {
        Button { store.openAgent(row.id) } label: {
            AgentTile(row: row, size: size, selected: hub.selection == "a:" + row.id)
        }
        .buttonStyle(.plain)
        .frame(height: Theme.Metrics.pitch)
        .accessibilityLabel(row.session.title)
        .accessibilityValue(row.stateName)
        .accessibilityHint("Opens it in Claude")
        .sessionMenu(row, store)
        .onHover {
            if $0 {
                hub.selection = "a:" + row.id
                ui.drawerSelection = row.id
            }
        }
    }
}

/// The working mark: a 270° arc hugging the tile's edge, 1pt in, that breathes with the heartbeat while Core
/// Animation runs it (see `Pulse`: every arc is in phase, none runs while the window is hidden). Nothing at all
/// when not `working`, so a tile can carry it unconditionally. Static at full opacity under Reduce Motion. A
/// state mark for sighted users only: the tile's own accessibility value says "working".
struct WorkingArc: View {
    var size: CGFloat = Theme.Metrics.tile
    var working = true

    var body: some View {
        if working {
            Pulse(id: size) { ArcShape(size: size) }
                .frame(width: size, height: size)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The arc itself, as `Pulse` renders it once to an image.
struct ArcShape: View {
    let size: CGFloat
    @Environment(\.resolved) private var resolved

    var body: some View {
        // The stroke's outer edge sits 1pt inside the tile's.
        Tile.shape(size).inset(by: 1 + resolved.arcWidth / 2)
            .trim(from: 0, to: 0.75)
            .stroke(Theme.text, style: StrokeStyle(lineWidth: resolved.arcWidth, lineCap: .round))
            .frame(width: size, height: size)
    }
}
