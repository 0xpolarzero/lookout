import AppKit
import SwiftUI

// The hub's sections: what goes in the bar's cells and beside them.
//
// One set of measures for every piece, so the sections read as one surface:
// - section headers are 30pt: title 12 semibold secondary, then a status in its state's colour, trailing actions
//   as header-size (24) IconButtons;
// - rows pad their content 8 × 6 inside a 9pt continuous rounded fill (white 0.06 on hover or when picked);
//   the layout adds the one outer inset, so nothing here pads itself from the outside;
// - every control has a tooltip: a verb phrase, then what it does and its shortcut, read from the user's settings.

extension LookoutHub {
    // MARK: Links

    /// A line of text with a link after it, padded like a row ("No CI configured  Choose repositories").
    func linkRow(_ text: String, action: String, _ perform: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(Theme.tertiary)
            Button(action, action: perform).buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.control)
        .padding(.horizontal, Theme.Space.md)
        .frame(minHeight: Theme.Metrics.line)
    }

    // MARK: Section headers

    /// A section's header: its title and status on the left, its actions on the right; 30pt tall.
    func sectionHeader<Trailing: View>(_ title: String, status: [(String, AnyShapeStyle)] = [],
                                       @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Typography.title).foregroundStyle(Theme.secondary).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(status.enumerated()), id: \.offset) { _, part in
                Text(part.0).font(Theme.Typography.numeral).foregroundStyle(part.1).lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, Theme.Space.md)
        .padding(.trailing, 3)
        .frame(height: Theme.Metrics.line)
        .motion(Theme.Motion.fade, value: status.map(\.0))
    }

    // MARK: Agents

    var claudeMark: some View {
        Image(systemName: "asterisk")
            .font(Theme.Typography.glyph(14, .bold))
            .foregroundStyle(Theme.tertiary)
            .frame(width: Theme.Metrics.line, height: Theme.Metrics.line)
            .contentShape(Rectangle())
            .accessibilityLabel("Sessions")
    }

    /// "Sessions", then what's waiting for you (amber) and what's done and unread (blue).
    var agentsHeader: some View {
        let counts = store.agentCounts
        var status: [(String, AnyShapeStyle)] = []
        if counts.blocked > 0 { status.append(("\(counts.blocked) waiting", AnyShapeStyle(Theme.amber))) }
        if counts.done > 0 { status.append(("\(counts.done) done", AnyShapeStyle(Theme.accent))) }
        // Claude's files missing or unreadable: the notice under the header says so; this stays when the list is shrunk.
        switch store.claudeLink {
        case .missing, .unreadable: status.append(("!", AnyShapeStyle(Theme.red)))
        default: break
        }
        return sectionHeader("Sessions", status: status) { if showsDetail { focusButton(.agents) } }
    }

    /// A session's tile in the bar; opens it in Claude.
    func tile(_ r: AgentRow, size: CGFloat) -> some View {
        BarTile(row: r, size: size, axis: barAxis, onRail: !edge.isHorizontal, store: store, ui: ui, hub: hub)
    }

    /// The "+" in the bar, a tile like the sessions' above it: a scratch session.
    var newSessionCell: some View {
        NewSessionTile(size: Theme.Metrics.tile) { store.startScratchSession() }
            .frame(height: Theme.Metrics.pitch)
    }

    /// Beside the "+": the label and the projects to start a session in.
    var newSessionDetail: some View { NewSessionRow(store: store, style: .detail) }
}
