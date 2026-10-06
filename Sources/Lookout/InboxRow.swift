import AppKit
import SwiftUI

// An inbox item: its row, its context menu and what VoiceOver says about it.

extension EventKind {
    /// The 10pt glyph before the meta line: a comment, a pull request, an issue, a review request.
    var rowSymbol: String {
        switch self {
        case .issueOpened: "exclamationmark.circle"
        case .prOpened: "arrow.triangle.pull"
        case .reviewRequested: "eye"
        default: "text.bubble"
        }
    }
}

extension ItemState {
    /// What became of an item that is no longer open: Done, Addressed (you replied) or Resolved (the thread was).
    var doneLabel: String {
        switch self {
        case .addressed: "Addressed"
        case .resolved: "Resolved"
        default: "Done"
        }
    }

    var doneSymbol: String {
        switch self {
        // Neither is the Restore button's arrow or the Done checkmark, which sit on the same row.
        case .addressed: "bubble.left"
        case .resolved: "checkmark.bubble"
        default: "checkmark"
        }
    }
}

/// An inbox item on two lines, 44pt in every tab (see DESIGN.md 4.4):
/// `[dot][avatar] title … age / kind · meta … action`; from `wideFrom` points of row, on the title's baseline:
/// `[dot][avatar] title kind · meta … age action`. The one action (Done, or Restore) shows on hover, on the
/// keyboard's pick and on VoiceOver focus; everything else is in the context menu, a key and the
/// accessibility actions. A click opens the item on GitHub and reads it.
struct InboxRow: View {
    let item: InboxItem
    let store: Store
    let ui: UIState
    let hub: HubState
    /// Set by the list that holds the row, so the "Unread" rotor can find it.
    var rotor: Namespace.ID?
    @State private var hover = false
    /// The row is wide enough (a focused inbox along the top or bottom) for the meta to join the title's line.
    @State private var wide = false
    @AccessibilityFocusState private var spoken: Bool
    @Environment(\.resolved) private var resolved

    /// How wide a row is before its meta moves up beside the title (the focused inbox, 560 with its insets).
    static let wideFrom: CGFloat = 520

    /// Compared here, in this row's own body: hovering another row doesn't rebuild the whole hub.
    private var selected: Bool { hub.selection == key }
    private var key: String { "i:" + item.id }
    /// The content's height: the row is `twoLineRow` whatever line 2 holds (the highlight pads 6 above and below).
    private static let contentHeight = Theme.Metrics.twoLineRow - 12
    private var unread: Bool { item.state == .unread }
    private var isOpen: Bool { item.state.isOpen }
    private var low: Bool { store.isLowPriority(item) }
    /// What the keyboard picked (not the pointer): its detail shows as a tip, which `.help` can't do for a key.
    private var keyboardPicked: Bool { selected && hub.keyboardSelection?.id == key }
    /// The one date the row's age is counted from, shown and spoken: when it arrived, or in Done when it was cleared.
    private var ageDate: Date { isOpen ? item.createdAt : item.clearedAt ?? item.createdAt }

    var body: some View {
        // The age and what VoiceOver says of it come from the same minute, so they never part.
        Ticking(coarse: true) { now in row(now) }
    }

    private func row(_ now: Date) -> some View {
        let showsAction = hover || selected || spoken
        return ZStack(alignment: wide ? .trailing : .bottomTrailing) {
            Button { store.open(item) } label: { label(now) }
                .buttonStyle(.plain)
                .focusable(false)
                .help(tooltip)
            if showsAction {
                // In the room line 2 keeps for it (`secondLine`), level with it and with the age above.
                action
                    .padding(.trailing, Theme.Metrics.rowPadding)
                    .padding(.bottom, wide ? 0 : 1)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideFrom } action: { if wide != $0 { wide = $0 } }
        .tip(item.title, tipDetail, focused: keyboardPicked, hover: false)
        .onHover(perform: hovered)
        .motion(Theme.Motion.hover, value: showsAction)
        .contextMenu { InboxRowMenu(item: item, store: store, low: low) }
        .rowMenuTarget(key, hub: hub)
        // One element: the visible action is reached through the actions below.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(now))
        .accessibilityValue(isOpen ? (unread ? "Unread" : "") : item.state.doneLabel)
        .accessibilityHint("Opens on GitHub. More actions available.")
        .accessibilityAddTraits(.isButton)
        .accessibilityFocused($spoken)
        .voiceOverTarget(key, hub: hub, focus: $spoken)
        .accessibilityAction { store.open(item) }
        .accessibilityActions {
            Button("Open on GitHub") { store.open(item) }
            if isOpen { Button(unread ? "Mark as read" : "Mark as unread") { toggleRead() } }
            Button(isOpen ? "Done" : "Restore") { if isOpen { store.done(item) } else { store.restore(item) } }
            Button("Copy link") { copyLink(item) }
        }
        .modifier(RotorEntry(id: item.id, namespace: rotor))
    }

    private func label(_ now: Date) -> some View {
        Group {
            if wide {
                // The request is what the row is for: the title keeps its whole text while anything of the meta can give
                // (its kind's word, then everything but the stack's own cut), and a title that still doesn't fit with the
                // meta on its line goes back to the two lines, where the author is what is cut.
                ViewThatFits(in: .horizontal) {
                    line(now, .wide(kind: true))
                    line(now, .wide(kind: false))
                    line(now, .stacked)
                }
            } else {
                line(now, .stacked)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.contentHeight, alignment: .top)
        .rowHighlight(hover: hover, picked: selected && !hover)
    }

    private enum Layout: Equatable {
        case stacked
        case wide(kind: Bool)
    }

    private func line(_ now: Date, _ layout: Layout) -> some View {
        HStack(alignment: .top, spacing: 0) {
            dot.padding(.top, layout == .stacked ? 0 : 8)
            Avatar(url: item.avatar, name: item.author)
                .padding(.top, 4)
                .accessibilityHidden(true)
            Group {
                switch layout {
                case .stacked:
                    VStack(alignment: .leading, spacing: Theme.Space.hair) {
                        firstLine(now)
                        secondLine
                    }
                case .wide(let kind):
                    wideLine(now, kind: kind)
                }
            }
            .padding(.leading, Theme.Space.md)
        }
    }

    /// Unread: a 6pt dot, amber (grey for a bot), with a white ring under Differentiate Without Colour.
    private var dot: some View {
        Circle()
            .fill(unread ? (low ? AnyShapeStyle(Theme.tertiary) : AnyShapeStyle(Theme.amber)) : AnyShapeStyle(.clear))
            .overlay { if unread && resolved.differentiate { Circle().strokeBorder(.white, lineWidth: 1).padding(-1) } }
            .frame(width: 6, height: 6)
            .frame(width: Theme.Metrics.dotSlot, height: 16, alignment: .leading)
            .accessibilityHidden(true)
    }

    private func firstLine(_ now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            title
            Spacer(minLength: 0)
            age(now)
            // A wide list keeps its ages in one column: a row that fell back to two lines leaves the action's room as the
            // rows on one line do.
            if wide { Color.clear.frame(width: Theme.Metrics.iconButton - Theme.Space.sm, height: 1) }
        }
    }

    private var title: some View {
        Text(item.title)
            .font(unread ? Theme.Typography.title : Theme.Typography.body)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
    }

    /// In Done, when it was cleared; elsewhere, when it arrived.
    private func age(_ now: Date) -> some View {
        Text(shortAgo(ageDate, now: now))
            .font(Theme.Typography.numeral)
            .foregroundStyle(Theme.secondary)
            .frame(width: Theme.Metrics.ageColumn, alignment: .trailing)
    }

    /// The wide row: everything on the title's baseline, the meta after it, then the age and the action's room (always
    /// kept). The title keeps its whole text.
    private func wideLine(_ now: Date, kind: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            title.fixedSize()
            HStack(spacing: Theme.Space.xs) {
                glyph(item.kind.rowSymbol)
                meta(kind: kind)
            }
            .foregroundStyle(Theme.tertiary)
            .layoutPriority(1)
            Spacer(minLength: 0)
            age(now)
            Color.clear.frame(width: Theme.Metrics.iconButton, height: 1)
        }
        .frame(height: Self.contentHeight)
    }

    /// The kind's glyph and the meta line; then, for Addressed and Resolved, what became of it. The state is the
    /// news, so it keeps its word: the kind's word goes first (its glyph stays), then the author is cut. The action's
    /// room is always kept at the end (whether it shows or not), so what the line says never changes under the pointer.
    @ViewBuilder private var secondLine: some View {
        HStack(spacing: Theme.Space.xs) {
            glyph(item.kind.rowSymbol)
            ViewThatFits(in: .horizontal) {
                meta(kind: true)
                meta(kind: false)
            }
        }
        .padding(.trailing, Theme.Metrics.iconButton + Theme.Space.xs)
        .foregroundStyle(Theme.tertiary)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(Theme.Typography.glyph(10, .regular)).frame(width: 12)
    }

    private func meta(kind: Bool) -> some View {
        HStack(spacing: 0) {
            Text("\(item.repo.split(separator: "/").last ?? "")#\(item.number) · \(kind ? item.kind.label + " · " : "")@\(item.author)")
                .lineLimit(1)
            if let state = inlineState {
                Text(" · ").fixedSize()
                HStack(spacing: Theme.Space.xs) {
                    glyph(state.doneSymbol)
                    Text(state.doneLabel).lineLimit(1)
                }
                .foregroundStyle(Theme.secondary)
                .fixedSize()
                .layoutPriority(1)
            }
        }
        .font(Theme.Typography.meta)
    }

    /// Shown unless it is what the tab already says: in Done, a plain Done needs no word.
    private var inlineState: ItemState? {
        guard !isOpen, !(hub.filter == .done && hub.query.isEmpty && item.state == .discarded) else { return nil }
        return item.state
    }

    private var action: some View {
        Group {
            if isOpen {
                IconButton(symbol: "checkmark", help: "Done", detail: store.shortcut(.discard).display, tabStop: false) { store.done(item) }
            } else {
                IconButton(symbol: "arrow.uturn.backward", help: "Restore", detail: store.shortcut(.discard).display, tabStop: false) { store.restore(item) }
            }
        }
    }

    /// Pointer over the row: the keys act on it. Once the pointer leaves, they stop, unless the keyboard made the pick.
    private func hovered(_ inside: Bool) {
        hover = inside
        if inside {
            hub.selection = key
            ui.drawerSelection = nil
        } else if hub.selection == key, hub.keyboardSelection?.id != key {
            hub.selection = nil
        }
    }

    private func toggleRead() {
        if unread { store.markRead(item) } else { store.markUnread(item) }
    }

    /// The first lines of the comment.
    private var tipDetail: String? {
        let lines = item.snippet.split(separator: "\n", omittingEmptySubsequences: true).prefix(3).map(String.init)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The title and the first lines of the comment.
    private var tooltip: String { ([item.title] + (tipDetail.map { [$0] } ?? [])).joined(separator: "\n") }

    /// "Review comment from andrewrk on zig #21877: std.Io: add vectored reads to File, 3 minutes ago".
    private func spokenLabel(_ now: Date) -> String {
        let name = item.repo.split(separator: "/").last.map(String.init) ?? item.repo
        return "\(item.kind.label) from \(item.author) on \(name) #\(item.number): \(item.title), \(spokenAgo(ageDate, now: now))"
    }
}

/// The row as a stop on the "Unread" rotor, when its list gave it a namespace.
private struct RotorEntry: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.accessibilityRotorEntry(id: id, in: namespace) } else { content }
    }
}

private func copyLink(_ item: InboxItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
}

/// "3 minutes ago", for a screen reader (the row shows "3m").
private func spokenAgo(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    func ago(_ n: Int, _ unit: String) -> String { "\(plural(n, unit)) ago" }
    if s < 60 { return "just now" }
    if s < 3600 { return ago(s / 60, "minute") }
    if s < 86400 { return ago(s / 3600, "hour") }
    if s < 7 * 86400 { return ago(s / 86400, "day") }
    return "on " + date.formatted(.dateTime.month(.wide).day())
}

// MARK: - Context menu

extension Shortcut {
    /// The key equivalent a menu item shows for this shortcut; nil for combinations SwiftUI has no name for.
    var menuShortcut: KeyboardShortcut? {
        guard !isModifierTap, mouseButton == nil else { return nil }
        let key: KeyEquivalent? = switch keyCode {
        case 36: .return
        case 49: .space
        case 51: .delete
        case 48: .tab
        case 53: .escape
        default: Self.keyName(keyCode).lowercased().first.map { KeyEquivalent($0) }
        }
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return key.map { KeyboardShortcut($0, modifiers: modifiers) }
    }
}

/// An inbox item's context menu (DESIGN.md 5.4): open, read state, link, bot, Done last.
struct InboxRowMenu: View {
    let item: InboxItem
    let store: Store
    /// Items already in the low-priority list offer "Stop treating as a bot" instead.
    let low: Bool

    var body: some View {
        let unread = item.state == .unread
        entry("Open on GitHub", "arrow.up.right.square", store.shortcut(.openItem)) { store.open(item) }
        if item.state.isOpen {
            entry(unread ? "Mark as read" : "Mark as unread", unread ? "envelope.open" : "envelope.badge", store.shortcut(.toggleRead)) {
                if unread { store.markRead(item) } else { store.markUnread(item) }
            }
        }
        entry("Copy link", "link") { copyLink(item) }
        Divider()
        if !low {
            entry("Treat @\(item.author) as a bot", "cpu") { store.addBot(item.author) }
        } else if store.settings.botHandles.contains(where: { $0.caseInsensitiveCompare(item.author) == .orderedSame }) {
            entry("Stop treating @\(item.author) as a bot", "cpu") {
                store.settings.botHandles.removeAll { $0.caseInsensitiveCompare(item.author) == .orderedSame }
            }
        }
        Divider()
        if item.state.isOpen {
            entry("Done", "checkmark", store.shortcut(.discard)) { store.done(item) }
        } else {
            entry("Restore", "arrow.uturn.backward", store.shortcut(.discard)) { store.restore(item) }
        }
    }

    private func entry(_ title: String, _ symbol: String, _ shortcut: Shortcut? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .keyboardShortcut(shortcut?.menuShortcut)
    }
}
