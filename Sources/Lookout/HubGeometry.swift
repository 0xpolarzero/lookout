import SwiftUI

/// The hub's measures and where it sits on its edge, as arithmetic over numbers: what the layout is built from and what
/// the geometry tests check (DESIGN.md 3.4, 5.3).
enum HubGeometry {
    /// What the bar leaves at its ends along its axis, so its first cell starts this far from the rounded end.
    static let lead = (Theme.Metrics.bar - Theme.Metrics.pitch) / 2

    /// Kept open on the sides: what sits beside the 46pt rail.
    static let sideDetail: CGFloat = 420
    /// Kept open along the top and bottom: the inbox and CI column, the sessions column and the gutter between them.
    static let leftColumn: CGFloat = 420
    static let rightColumn: CGFloat = 400
    static let gutter: CGFloat = 12
    static let maxColumns: CGFloat = 860
    /// A focused section is one column: the inbox up to this wide (its meta joins the title's line from here), CI and
    /// the sessions as wide as their own column.
    static let focusedInbox: CGFloat = 560
    static let focusedAgents: CGFloat = 480
    /// A page beside the bar and under the strip.
    static let pageSide: CGFloat = 420
    static let pageStrip: CGFloat = 480

    /// The one outer inset, and the hub's own depth beyond the rail.
    static let inset = Theme.Metrics.inset

    /// The width of the full view along the top and bottom: both columns (the sessions' only with the extension on),
    /// or the one column of a focused section; never more than the screen leaves.
    static func stripWidth(focus: HubSection?, sessions: Bool, room: CGFloat) -> CGFloat {
        let width: CGFloat = switch focus {
        case .inbox: focusedInbox
        case .ci: leftColumn
        case .agents: focusedAgents
        default: sessions ? min(leftColumn + gutter + rightColumn, maxColumns) : leftColumn
        }
        return min(width, max(room - 2 * inset, 0))
    }

    /// Where the hub's start lies along its edge: where the bar starts at rest, which it never leaves as the view
    /// opens. Only a hub too long to fit below that anchor moves, by the least that keeps both insets; one shorter than
    /// the bar stays where it is.
    static func along(length: CGFloat, position: Double, restLength: CGFloat, own: CGFloat) -> CGFloat {
        let start = length * position - restLength / 2
        let anchor = min(max(start, inset), max(length - restLength - inset, inset))
        return min(anchor, max(length - own - inset, inset))
    }

    /// Where a hover panel starts along the bar's axis (from the bar's start): at `start`, level with its cell, unless
    /// that would leave it hanging past `reach` (how far the screen lets it go); then up by the least that doesn't,
    /// never above the bar's start.
    static func peekStart(_ start: CGFloat, length: CGFloat, reach: CGFloat) -> CGFloat {
        max(min(start, reach - length), 0)
    }

    /// The hub's origin in a window `bounds` spanning the edge, flush with the screen on its own side.
    static func origin(edge: DockEdge, position: Double, restLength: CGFloat, size: CGSize, in bounds: CGRect) -> CGPoint {
        switch edge {
        case .right: CGPoint(x: bounds.maxX - size.width, y: bounds.minY + along(length: bounds.height, position: position, restLength: restLength, own: size.height))
        case .left: CGPoint(x: bounds.minX, y: bounds.minY + along(length: bounds.height, position: position, restLength: restLength, own: size.height))
        case .top: CGPoint(x: bounds.minX + along(length: bounds.width, position: position, restLength: restLength, own: size.width), y: bounds.minY)
        case .bottom: CGPoint(x: bounds.minX + along(length: bounds.width, position: position, restLength: restLength, own: size.width), y: bounds.maxY - size.height)
        }
    }

    /// The longest the hub may be along its depth axis: the screen's usable height less both insets, never a floor.
    static func maxLength(visibleHeight: CGFloat) -> CGFloat { max(visibleHeight - 2 * inset, 0) }

    /// The longest the full view may be on the sides: what lies below the anchor the bar starts from at rest, so the
    /// inbox tile stays where it is (§5.3: only the strip's horizontal edges may clamp). A bar resting so low that
    /// even the fixed parts don't fit below it is the one case `along` still moves.
    static func sideLength(visibleHeight: CGFloat, position: Double, restLength: CGFloat) -> CGFloat {
        let anchor = along(length: visibleHeight, position: position, restLength: restLength, own: restLength)
        return max(visibleHeight - anchor - inset, 0)
    }

    /// The height along the top and bottom between the strip and the footer, for the columns: what the screen leaves
    /// less both, the padding and the hairlines.
    static func stripRoom(maxLength: CGFloat) -> CGFloat {
        maxLength - Theme.Metrics.bar - Theme.Metrics.pitch - 2 * lead - 2
    }

    /// A hairline between sections, with its room.
    static let stripRule = 2 * Theme.Space.xs + 1

    /// What the two columns' lists may take of `room`, the strip's body. The inbox and CI are the first column: the
    /// inbox takes what CI leaves (`leftFixed` is CI's block). The sessions never cut the inbox, but a column of
    /// sessions taller than that one is cut to it, to whole rows with "+N more" under them, so the columns end together
    /// (a gap of up to `tolerance`, a row, is left rather than a row cut for the sake of a few points). A column shorter
    /// than the first one has nothing to fill the rest with: the void is at the end of its list. `rightFixed`: what the
    /// sessions' column has besides the list (New session, the notice). Heights are as the lists measured themselves
    /// (nil until they have: taken to use all the room). `matchesAll`: a search, whose results are listed flat and all
    /// there is to read: the sessions take the room they need, whatever the inbox's short column would leave.
    static func stripCaps(room: CGFloat, leftFixed: CGFloat, inbox: ListHeights?, rightFixed: CGFloat, sessions: ListHeights?,
                          tolerance: CGFloat = Theme.Metrics.twoLineRow, matchesAll: Bool = false) -> (inbox: CGFloat, sessions: CGFloat) {
        let floor: CGFloat = 120
        let inboxCap = max(room - leftFixed, floor)
        let leftHeight = leftFixed + min(inbox?.shown ?? inboxCap, inboxCap)
        let sessionsRoom = max(room - rightFixed, floor)
        let rightHeight = rightFixed + min(sessions?.content ?? .infinity, sessionsRoom)
        if matchesAll || rightHeight <= leftHeight + tolerance { return (inboxCap, sessionsRoom) }
        // At least two rows and the line that says there are more.
        let least = 2 * Theme.Metrics.twoLineRow + Theme.Metrics.pitch
        return (inboxCap, min(max(leftHeight - rightFixed, least), sessionsRoom))
    }

    /// The first cell's centre, along the bar's axis from the hub's own start: the same at rest and kept open, which is
    /// why the inbox tile stays where it is.
    static var firstCellCenter: CGFloat { lead + Theme.Metrics.pitch / 2 }

    /// Whether the window takes the mouse at `point` (screen coordinates): over the hub or the peek's panel, or over a
    /// tooltip's bubble or the way to it, which lie outside both.
    static func takesMouse(_ point: CGPoint, hub: CGRect, panel: CGRect?, tip: CGRect?) -> Bool {
        hub.insetBy(dx: -1, dy: -1).contains(point)
            || panel?.insetBy(dx: -2, dy: -2).contains(point) == true
            || tip?.contains(point) == true
    }
}
