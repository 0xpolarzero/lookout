import AppKit
import SwiftUI

// A session's tile, and the cell every piece of the bar sits in.

/// What a session's tile says besides its letters (DESIGN.md 4.1). Each is a shape before it is a colour: a solid
/// amber tile, a ring, a dot. Waiting never shows a ring; working and unread show both.
struct TileMarks: Equatable {
    /// Stopped on you (a question, a plan) or finished with something for you: the whole tile turns amber.
    var waiting = false
    /// Answering, or finished with a subagent or command still running: a ring around the tile.
    var working = false
    /// Finished and not looked at: a dot on its corner.
    var unread = false
}

extension AgentRow {
    var tileMarks: TileMarks {
        let waiting = waitsForYou || (!session.running && unread && session.summary?.blocked == true)
        // Never while it waits for you, however it waits: what a finished question left running behind it is not work
        // until you have read it (then the tile is not amber any more, and the ring says what is still going).
        return TileMarks(waiting: waiting, working: !waiting && (session.running || !tasks.isEmpty), unread: unread && !waiting)
    }

    /// "waiting for you", "working", "finished, unread": the state as VoiceOver says it, never colour alone.
    var tileState: String {
        let marks = tileMarks
        if marks.waiting { return "waiting for you" }
        if session.running { return "working" }
        let running = tasks.isEmpty ? "" : ", \(tasks.count) running"
        if unread { return "finished, unread" + running }
        if !tasks.isEmpty { return "finished" + running }
        return pending ? "new activity" : "idle"
    }

    /// What VoiceOver reads after the title: "waiting for you, lcu, 4 minutes".
    func tileValue(now: Date = Date()) -> String {
        "\(tileState), \(projectName), \(Self.spoken(now.timeIntervalSince(session.lastActivity)))"
    }

    /// The question it is stopped on, else what it said last: the hint under the value.
    var tileHint: String {
        let said = (waitsForYou ? activity?.text : nil) ?? session.summary?.detail
        return said.flatMap { $0.isEmpty ? nil : $0 } ?? "Opens it in Claude"
    }

    private static func spoken(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return plural(s / 60, "minute") }
        if s < 86400 { return plural(s / 3600, "hour") }
        return plural(s / 86400, "day")
    }
}

/// A 26pt tile: letters, an emoji or a symbol, and the marks of `TileMarks`. Plain content, no button: the bar
/// puts it in a `BarCell`, the session rows beside the bar use it as their avatar.
struct StatusTile: View {
    var label = ""
    var symbol: String? = nil
    var marks = TileMarks()
    var size: CGFloat = Theme.Metrics.tile
    /// The pointer is over it: neutral tiles take a step more fill.
    var hovering = false
    /// The surface the unread dot's halo cuts into: the rail beside the screen edge, else the strip's `bg`.
    var onRail = false
    @Environment(\.resolved) private var resolved

    var body: some View {
        let shape = Tile.shape(size)
        face
            .foregroundStyle(marks.waiting ? Theme.onTint : Theme.text)
            .frame(width: size, height: size)
            .background(shape.fill(marks.waiting ? Theme.amber : resolved.fill(hovering ? Theme.Fill.selected : Theme.Fill.tile)))
            // Amber may not tell from the grey tile to a colour-blind eye: a dark outline says it too.
            .overlay {
                if resolved.differentiate, marks.waiting { shape.inset(by: 1).strokeBorder(Theme.onTint, lineWidth: 1.5) }
            }
            .overlay { if marks.working { WorkingRing(size: size) } }
            .overlay(alignment: .topTrailing) { if marks.unread { UnreadDot(onRail: onRail).offset(x: 5, y: -5) } }
            .brightness(marks.waiting && hovering ? 0.06 : 0)
    }

    @ViewBuilder private var face: some View {
        if let symbol {
            Image(systemName: symbol).font(Theme.Typography.glyph(12)).symbolRenderingMode(.monochrome)
        } else if label.unicodeScalars.first.map({ $0.properties.isEmoji && $0.value > 0xFF }) == true {
            Text(label).font(.system(size: 14)).lineLimit(1)
        } else {
            Text(label).font(Theme.Typography.tile).lineLimit(1)
        }
    }
}

/// The unread mark: a 7pt accent dot on the corner of the tile's working ring (where it would be), with a 1.5pt halo in
/// the surface's own colour, so it reads against the tile it overlaps; under Differentiate Without Colour a 1pt white
/// ring too.
private struct UnreadDot: View {
    let onRail: Bool
    @Environment(\.resolved) private var resolved

    var body: some View {
        Circle().fill(Theme.accent)
            .frame(width: 7, height: 7)
            .padding(resolved.differentiate ? 1 : 0)
            .background { if resolved.differentiate { Circle().fill(.white) } }
            .padding(1.5)
            .background {
                Circle().fill(Theme.bg).overlay { if onRail { Circle().fill(Theme.rail) } }
            }
            .accessibilityHidden(true)
    }
}

/// A session's tile where the rows show it (the avatar beside its title): the status tile, named for VoiceOver.
struct AgentTile: View {
    let row: AgentRow
    var size: CGFloat = 26
    var selected = false

    var body: some View {
        StatusTile(label: row.label, symbol: row.icon, marks: row.tileMarks, size: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.session.title)
            .accessibilityValue(row.tileState)
            .focusRing(size * Tile.ratio, isFocused: selected)
    }
}

// MARK: - The bar's cell

/// A tooltip: what the cell is, and what a click does or the key that does it.
struct BarHelp {
    let title: String
    var detail: String? = nil
}

/// An action VoiceOver offers on a cell beyond its click.
struct BarAction: Identifiable {
    let name: String
    let run: () -> Void
    var id: String { name }
}

/// The one element type of the bar: a 36pt slot along the bar's axis, as deep as the bar across it, holding a
/// 26pt face centred. A button with a label, a value and a hint, and a `Show` action that keeps the hub open on its
/// section (which Return on a focused cell does too). `face` is told when the pointer is over the cell; the focus ring
/// (Tab, or the keyboard pick) is drawn round it.
struct BarCell<Face: View>: View {
    /// The bar's own axis: vertical on the sides, horizontal along the top and bottom.
    let axis: Axis
    let name: String
    var value = ""
    var hint = ""
    var help: BarHelp? = nil
    /// The keyboard or the pointer picked it (a session's tile): ringed like a focused one.
    var picked = false
    var show: (() -> Void)? = nil
    /// What VoiceOver's press does where it should differ from a click (a click has its panel under the pointer already).
    var press: (() -> Void)? = nil
    var actions: [BarAction] = []
    let action: () -> Void
    @ViewBuilder let face: (_ hovering: Bool) -> Face
    @State private var hovering = false
    @FocusState private var focused: Bool

    static var depth: CGFloat { Theme.Metrics.bar }

    var body: some View {
        Button(action: action) {
            face(hovering)
                .focusRing(Theme.Radius.tile, isFocused: focused || picked)
                .frame(width: axis == .vertical ? Self.depth : Theme.Metrics.pitch,
                       height: axis == .vertical ? Theme.Metrics.pitch : Self.depth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .reportsControlFocus(focused)
        // Return and Space on a focused cell keep the hub open on its section (DESIGN.md 6.1); a click does what it did.
        .onKeyPress(keys: [.return, .space]) { press in
            guard let show, press.modifiers.isEmpty else { return .ignored }
            show()
            return .handled
        }
        .onHover { hovering = $0 }
        .motion(Theme.Motion.hover, value: hovering)
        .modifier(BarCellHelp(help: help, focused: focused))
        .accessibilityLabel(name)
        .accessibilityValue(value)
        .accessibilityHint(hint)
        .modifier(BarCellPress(press: press))
        .accessibilityActions {
            if let show { Button("Show", action: show) }
            ForEach(actions) { Button($0.name, action: $0.run) }
        }
    }
}

private struct BarCellPress: ViewModifier {
    let press: (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let press { content.accessibilityAction(.default, press) } else { content }
    }
}

private struct BarCellHelp: ViewModifier {
    let help: BarHelp?
    /// The cell's own keyboard focus: its tip shows after a second.
    let focused: Bool
    @Environment(\.tipBeside) private var beside

    @ViewBuilder func body(content: Content) -> some View {
        if let help { content.tip(help.title, help.detail, focused: focused, beside: beside) } else { content }
    }
}

/// A session's tile in the bar; opens it in Claude. Its picked look is compared here, in its own body, so hovering
/// a tile doesn't rebuild the whole hub. No tooltip: hovering opens the sessions' panel, a row beside each tile.
struct BarTile: View {
    let row: AgentRow
    var size: CGFloat = Theme.Metrics.tile
    let axis: Axis
    var onRail = false
    let store: Store
    let ui: UIState
    let hub: HubState
    var show: (() -> Void)? = nil

    /// Observed, so turning VoiceOver on mounts the clock and turning it off lets it go.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// The age VoiceOver speaks follows the minute clock, which at rest only a screen reader needs: nothing ticks for
    /// a bar nobody is listening to.
    @ViewBuilder var body: some View {
        if voiceOver {
            Ticking(coarse: true) { cell(now: $0) }
        } else {
            cell(now: Date())
        }
    }

    private func cell(now: Date) -> some View {
        BarCell(axis: axis, name: row.session.title, value: row.tileValue(now: now), hint: row.tileHint,
                picked: hub.selected("a:" + row.id), show: show, press: show, action: { store.openAgent(row.id) }) { hovering in
            StatusTile(label: row.label, symbol: row.icon, marks: row.tileMarks, size: size, hovering: hovering, onRail: onRail)
        }
        .sessionMenu(row, store, hub)
        .onHover { inside in
            if inside {
                hub.selection = "a:" + row.id
                ui.drawerSelection = row.id
            } else if hub.keyboardSelection?.id != "a:" + row.id {
                // The pointer left: no ring on the tile, nor a lit row in the peek, unless the keyboard picked it.
                if ui.drawerSelection == row.id { ui.drawerSelection = nil }
                if hub.selection == "a:" + row.id { hub.selection = nil }
            }
        }
    }
}

/// The working mark (DESIGN.md 10.1): a full outline round the tile, 1.5pt, drawn 2pt outside it and concentric with
/// it, that breathes with the heartbeat while Core Animation runs it (see `Pulse`: every ring is in phase, none runs
/// while the window is hidden). Nothing at all when not `working`, so a tile can carry it unconditionally. Static at
/// full opacity under Reduce Motion. A state mark for sighted users only: the tile's own accessibility value says
/// "working".
struct WorkingRing: View {
    static let width: CGFloat = 1.5
    /// Between the tile's edge and the ring's.
    static let gap: CGFloat = 2
    /// From the tile's edge to the ring's outer one.
    static let reach = gap + width

    var size: CGFloat = Theme.Metrics.tile
    var working = true

    var body: some View {
        if working {
            Pulse(id: size) { RingShape(size: size) }
                .frame(width: size + 2 * Self.reach, height: size + 2 * Self.reach)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The ring itself, as `Pulse` renders it once to an image.
struct RingShape: View {
    let size: CGFloat
    @Environment(\.resolved) private var resolved

    var body: some View {
        // The outer edge's radius is the tile's plus the ring's reach: the two are concentric.
        Theme.Radius.shape(size * Tile.ratio + WorkingRing.reach).inset(by: WorkingRing.width / 2)
            .stroke(resolved.workingRing, lineWidth: WorkingRing.width)
            .frame(width: size + 2 * WorkingRing.reach, height: size + 2 * WorkingRing.reach)
    }
}
