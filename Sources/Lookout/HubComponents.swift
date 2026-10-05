import AppKit
import SwiftUI

// Building blocks of the hub.

/// Scrolls only once its content is taller than `cap`; otherwise exactly as tall as the content. Follows the
/// keyboard selection.
struct CappedScroll<Content: View>: View {
    let cap: CGFloat
    var selection: String?
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        // The first measure lands as is (the hub's own spring reveals it); later ones glide.
                        if height == 0 { height = h } else { withAnimation(.easeOut(duration: 0.2)) { height = h } }
                    }
            }
            // No scroller: a legacy one ("Show scroll bars: Always") would take its width out of the rows and push
            // them off the bar's cells they line up with.
            .scrollIndicators(.never)
            .scrollDisabled(height <= cap)
            .frame(height: min(max(height, 1), cap))
            // Cut short: the last visible row fades out, so it reads as "more below" rather than clipped.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(height > cap ? 0.15 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                }
            }
            .onChange(of: selection) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
    }
}

/// An inbox item on two short lines; its actions show on hover or when picked with the keys.
struct CompactItemRow: View {
    let item: InboxItem
    let store: Store
    let selected: Bool
    let low: Bool
    var onHover: () -> Void = {}
    @State private var hover = false

    private var open: Bool { hover || selected }
    private var unread: Bool { item.state == .unread }

    var body: some View {
        Button { store.open(item) } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(unread ? (low ? Theme.secondary : Theme.amber) : .clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 8)
                ZStack(alignment: .bottomTrailing) {
                    Avatar(url: item.avatar, size: 22)
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .frame(width: 11, height: 11)
                        .background(Circle().fill(item.kind.color))
                        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: unread ? .semibold : .regular))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // The actions take the timestamp's place; the title stops short of them.
                        Text(shortAgo(item.createdAt)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
                            .opacity(open ? 0 : 1)
                            .frame(width: open ? actionsWidth - 6 : nil, alignment: .trailing)
                    }
                    Text("\(item.repo.split(separator: "/").last ?? "")#\(item.number) · \(item.kind.label) · @\(item.author)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(open ? Color.white.opacity(0.06) : .clear))
            .opacity(unread || open ? 1 : 0.72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // Centred on the title line (6pt row padding + half its 15pt line = 13.5; the capsule is 26 tall).
            if open { actions.padding(.top, 1).padding(.trailing, 4).transition(.opacity) }
        }
        .onHover { hover = $0; if $0 { onHover() } }
        .animation(.easeOut(duration: 0.15), value: open)
    }

    /// Room the action capsule takes over the title line: its buttons, its 2pt insets, and its 4pt from the edge.
    private var actionsWidth: CGFloat { CGFloat(item.state.isOpen ? 3 : 2) * IconButton.Size.row + 4 + 4 }

    private var actions: some View {
        let size = IconButton.Size.row
        return RowActions {
            if item.state.isOpen {
                IconButton(symbol: unread ? "checkmark" : "circle.fill", help: unread ? "Mark as read" : "Mark as unread",
                           detail: store.shortcut(.toggleRead).display, size: size) { unread ? store.markRead(item) : store.markUnread(item) }
                IconButton(symbol: "xmark", help: "Done", detail: "Moves it out of the inbox · \(store.shortcut(.discard).display)",
                           size: size) { store.discard(item) }
            } else {
                IconButton(symbol: "arrow.uturn.backward", help: "Back to inbox", detail: store.shortcut(.discard).display,
                           size: size) { store.restore(item) }
            }
            IconButton(symbol: "arrow.up.right", help: "Open on GitHub", detail: store.shortcut(.openItem).display, size: size) {
                store.open(item)
            }
        }
    }
}

/// A row's actions on hover, the same for inbox items and sessions: icon buttons in a capsule laid over the row's
/// right end (so showing them never changes the row's size).
struct RowActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(2)
            .background(Capsule().fill(Color(white: 0.16)))
            .overlay(Capsule().strokeBorder(Theme.stroke))
    }
}

extension AnyTransition {
    /// Content of the expanded view: fades in once the shape has started to grow, and out at once on close.
    static var hubReveal: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)),
                    removal: .opacity.animation(.easeIn(duration: 0.08)))
    }
}

/// A blinking text cursor for the typed search.
struct Caret: View {
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 1.5, height: 14)
            .opacity(on ? 1 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = false } }
    }
}

extension Store {
    /// The inbox as the hub shows it: the picked filter, or every item matching the search.
    func hubItems(_ hub: HubState) -> [InboxItem] {
        let words = hub.query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return list(hub.filter) }
        return items.filter { item in
            let text = "\(item.title) \(item.repo) #\(item.number) @\(item.author) \(item.snippet)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        .sorted { ($0.state.isOpen ? 0 : 1, $1.createdAt) < ($1.state.isOpen ? 0 : 1, $0.createdAt) }
    }

    /// A repo's latest CI run on GitHub (its Actions page until a run is known); the playground reports it instead.
    func openChecks(_ repo: RepoConfig) {
        let url = ci[repo.fullName]?.url ?? repo.url.appendingPathComponent("actions")
        if let interceptOpen { interceptOpen("Open checks · \(repo.fullName)") } else { NSWorkspace.shared.open(url) }
    }

    /// A scratch Claude session (no folder), through the same interception as every other open.
    func startScratchSession() {
        if let interceptOpen { interceptOpen("New Claude session in Scratch"); return }
        NewSessionRow.startScratch()
    }

    /// Sessions as the hub lists them: yours and the pending ones, or any session matching the search.
    func hubSessions(_ hub: HubState) -> [AgentRow] {
        guard agents.enabled else { return [] }
        if !hub.query.trimmingCharacters(in: .whitespaces).isEmpty { return searchSessions(hub.query) }
        let rows = agentRows
        return rows.kept + rows.pending.prefix(PillView.pendingTiles)
    }
}

/// The inbox in the bar: the tray, and under it (beside it along the top and bottom) one count. Amber for what
/// needs you; the bots' count, grey, only when nothing does. Nothing sits on top of the icon.
struct InboxCell: View {
    let needsYou: Int
    let bots: Int
    let vertical: Bool
    /// Off while the filter chips beside it already show the counts.
    var showsCount = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if vertical {
                    // Always as tall as icon + count, so the bar never shifts: the tray just slides to the middle.
                    ZStack(alignment: .top) {
                        icon.offset(y: badge == nil ? 9 : 0)
                        if let badge { badge.offset(y: 32) }
                    }
                    .frame(height: 47, alignment: .top)
                } else {
                    HStack(spacing: 6) {
                        icon
                        if let badge { badge }
                    }
                }
            }
            .padding(.vertical, vertical ? 7 : 5)
            .padding(.horizontal, vertical ? 4 : 7)
            .frame(minWidth: vertical ? 36 : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.snappy, value: needsYou)
        .animation(.snappy, value: bots)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: showsCount)
    }

    /// The tray; on a solid amber tile (like a session's) when something needs you, so it shows from afar.
    private var icon: some View {
        let lit = needsYou > 0
        return Image(systemName: lit ? "tray.full.fill" : "tray.fill")
            .font(.system(size: lit ? 13.5 : 15, weight: .semibold))
            .foregroundStyle(lit ? Color.black.opacity(0.78) : hover ? Theme.text : Theme.secondary)
            .frame(width: 28, height: 28)
            // Hover brightens the tile (or the tray), no box around it.
            .background(RoundedRectangle(cornerRadius: 8.4, style: .continuous)
                .fill(lit ? Theme.amber : Color.white.opacity(hover ? 0.08 : 0)))
            .brightness(lit && hover ? 0.06 : 0)
            .animation(.snappy, value: lit)
    }

    private var badge: AnyView? {
        guard showsCount else { return nil }
        // The tile is already amber: the count beside it stays quiet.
        if needsYou > 0 { return AnyView(count(needsYou, fill: Color.white.opacity(0.14), text: Theme.text)) }
        if bots > 0 { return AnyView(count(bots, fill: Color.white.opacity(0.08), text: Theme.secondary)) }
        return nil
    }

    private func count(_ n: Int, fill: Color, text: Color) -> some View {
        Text(n > 99 ? "99+" : "\(n)")
            .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
            .contentTransition(.numericText(value: Double(n)))
            .foregroundStyle(text)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 15)
            .background(Capsule().fill(fill))
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

}

/// A repo in CI's lines: its name (and how many checks fail), opening its latest run.
struct RepoChip: View {
    let repo: RepoConfig
    let status: CIStatus?
    let state: CIState
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(repo.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
                if state == .failure, let n = status?.failing.count, n > 0 {
                    Text("\(n) check\(n == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(Theme.red)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .tip(repo.fullName, detail)
    }

    private var detail: String {
        var lines = [status?.branch ?? "main"]
        if let title = status?.title, !title.isEmpty { lines[0] += " · " + title }
        if state == .failure, let failing = status?.failing, !failing.isEmpty {
            lines.append("Failing: " + failing.joined(separator: ", "))
        }
        lines.append("Click to open its checks")
        return lines.joined(separator: "\n")
    }
}

/// The "+" tile: shaped and filled like a session's tile, so it reads as the next one in the column.
struct NewSessionTile: View {
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(hover ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(shape.fill(Color.white.opacity(hover ? 0.1 : 0.06)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .tip("New session", "Scratch chat · or pick a project")
    }
}

/// What a session left running, on one line: each subagent and command with its icon.
struct RunningLine: View {
    let tasks: [ClaudeTask]

    var body: some View {
        tasks.enumerated().reduce(Text("")) { line, item in
            let (i, task) = item
            let icon = Text(Image(systemName: task.kind == .agent ? "asterisk" : "terminal")).foregroundStyle(Theme.claude)
            return line + (i == 0 ? Text("") : Text("   ")) + icon + Text(" " + task.title).foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
