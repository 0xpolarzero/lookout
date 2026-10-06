import AppKit
import SwiftUI

// Session and inbox views shared by the hub: rows, actions, label editor, update button, and the
// menus / status lines the hub ports next (claude link, rate limit, session and inbox context menus).

/// "Running swift test · 3m", ticking.
struct WorkingText: View {
    let row: AgentRow

    var body: some View {
        Ticking { now in
            Text(row.workingText(now: now)).foregroundStyle(row.waitsForYou ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Theme.secondary))
        }
    }
}

/// A project's colour dot and name.
struct ProjectLabel: View {
    let session: ClaudeSession
    let color: Color?

    var body: some View {
        HStack(spacing: 5) {
            if let color {
                Circle().fill(color).frame(width: 6, height: 6)
            } else {
                Image(systemName: "text.bubble").font(Theme.Typography.glyph(9, .regular))
            }
            Text(session.folderName)
        }
    }
}

/// One line per subagent or command still running, with what a subagent is on and how long it's been going.
struct TaskLines: View {
    let tasks: [ClaudeTask]

    var body: some View {
        Ticking { now in
            VStack(alignment: .leading, spacing: 3) {
                ForEach(tasks) { task in
                    HStack(spacing: 6) {
                        Image(systemName: task.kind == .agent ? "asterisk" : "terminal")
                            .font(Theme.Typography.glyph(9))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 12)
                        Text(task.title).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(status(task, now: now))
                            .font(Theme.Typography.numeral)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }
        }
        .font(.system(size: 11))
    }

    private func status(_ task: ClaudeTask, now: Date) -> String {
        let elapsed = AgentRow.duration(now.timeIntervalSince(task.since))
        guard let activity = task.activity?.text else { return elapsed }
        return "\(activity) · \(elapsed)"
    }
}

/// Only kept sessions can be dragged; dropping on another kept one moves it there.
struct Reorderable: ViewModifier {
    let row: AgentRow
    let store: Store
    @Binding var dropTarget: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        if row.pending {
            content
        } else {
            content
                .draggable("agent:" + row.id) {
                    Text(row.session.title)
                        .font(Theme.Typography.title)
                        .padding(.horizontal, 10)
                        .frame(height: Theme.Metrics.tile)
                        .background(Capsule().fill(Theme.bg))
                        .foregroundStyle(Theme.text)
                }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, id.hasPrefix("agent:") else { return false }
                    withAnimation(Theme.Motion.move.resolved(reduce: reduce)) { store.moveAgent(String(id.dropFirst(6)), onto: row.id) }
                    return true
                } isTargeted: { dropTarget = $0 }
        }
    }
}

/// Hover/selection actions, the same in the panel and the pill's drawer.
struct AgentActions: View {
    let row: AgentRow
    let store: Store
    /// The row already shows Keep and Hide: only read/unread and open here.
    var keepsInline = false

    var body: some View {
        RowActions {
            if row.pending && !keepsInline {
                IconButton(symbol: "bookmark", help: "Keep", detail: "Keeps it in your list · \(store.shortcut(.keepSession).display)") {
                    store.keepAgent(row.id)
                }
                IconButton(symbol: "eye.slash", help: "Hide", detail: "Comes back on new activity · \(store.shortcut(.removeSession).display)") {
                    store.dismissAgent(row.id)
                }
            } else {
                if row.unread {
                    IconButton(symbol: "checkmark", help: "Mark as read", detail: store.shortcut(.toggleRead).display) {
                        store.toggleAgentRead(row.id)
                    }
                } else {
                    IconButton(symbol: "circle.fill", help: "Mark as unread", detail: store.shortcut(.toggleRead).display) {
                        store.toggleAgentRead(row.id)
                    }
                }
                if !row.pending {
                    IconButton(symbol: "eye.slash", help: "Hide", detail: "Comes back on new activity · \(store.shortcut(.removeSession).display)") {
                        store.dismissAgent(row.id)
                    }
                }
            }
            IconButton(symbol: "arrow.up.right", help: "Open in Claude", detail: store.shortcut(.openItem).display) {
                store.openAgent(row.id)
            }
        }
    }
}

/// Two letters or an emoji; empty goes back to letters from the title.
struct LabelEditor: View {
    let row: AgentRow
    let store: Store
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Label for \(row.session.title)").font(Theme.Typography.title).lineLimit(1)
            Text("Two letters or an emoji; empty goes back to the \(row.entry.icon != nil ? "icon" : "letters")")
                .font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
            HStack(spacing: 6) {
                TextField(row.label, text: $text)
                    .focused($focused)
                    .fieldStyle()
                    .frame(width: 90)
                    .onSubmit(save)
                IconButton(symbol: "face.smiling", help: "Emoji") {
                    focused = true
                    NSApp.orderFrontCharacterPalette(nil)
                }
                Button("Save", action: save).controlSize(.small)
            }
            if row.entry.label != nil {
                Button(row.entry.icon != nil ? "Use the picked icon" : "Use letters from the title") {
                    store.setAgentLabel(row.id, nil)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.accent)
            }
            if store.agents.iconsEnabled && store.hasTypesafeKey && row.entry.label == nil {
                Button(row.entry.icon == nil ? "Pick an icon" : "Pick another icon") {
                    store.repickIcon(row.id)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(12)
        .frame(width: 240)
        .onAppear {
            text = row.entry.label ?? ""
            focused = true
        }
    }

    private func save() {
        store.setAgentLabel(row.id, text.isEmpty ? nil : text)
        dismiss()
    }
}

/// A new release, fetched in the background: an icon that says what it is on hover; click to restart into it
/// (or to download it, with a ring for progress, if that didn't happen on its own). Right-click for the release
/// notes or to skip that version.
struct UpdateButton: View {
    let updater: Updater
    let horizontal: Bool

    var body: some View {
        let version = updater.release?.version ?? ""
        Button { updater.advance() } label: { UpdateLabel(updater: updater, horizontal: horizontal, version: version) }
        .buttonStyle(HoverFillButtonStyle(shape: Capsule(), hover: Theme.Fill.hover))
        .accessibilityLabel(Self.label(updater.phase, version: version))
        .accessibilityHint(tooltip(version).0)
        .tip(tooltip(version).0, tooltip(version).1)
        .contextMenu {
            if let page = updater.release?.page {
                Button("What's new in \(version)") { NSWorkspace.shared.open(page) }
            }
            Button("Skip \(version)") { updater.skip() }
        }
    }

    /// The tooltip: what it is, and what a click does.
    private func tooltip(_ version: String) -> (String, String?) {
        switch updater.phase {
        case .available: ("Lookout \(version) is available", "Click to download it · right-click for more")
        case .downloading(let fraction): ("Downloading Lookout \(version)… \(Int(fraction * 100))%", nil)
        case .ready: ("Lookout \(version) is ready", "Click to restart into it")
        case .installing: ("Installing Lookout \(version)…", nil)
        case .failed(let message): ("Update failed: \(message)", "Click to try again")
        case .idle: ("", nil)
        }
    }

    fileprivate static func label(_ phase: Updater.Phase, version: String) -> String {
        switch phase {
        case .downloading(let fraction): "\(Int(fraction * 100))%"
        case .ready, .installing: "Restart to update"
        case .failed: "Retry update"
        default: "Update to \(version)"
        }
    }
}

/// The update button's face: its icon (a progress ring while downloading), and its name beside it on hover.
private struct UpdateLabel: View {
    let updater: Updater
    let horizontal: Bool
    let version: String
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if case .downloading(let fraction) = updater.phase {
                    Circle().stroke(Theme.Fill.selected, lineWidth: 2).padding(3)
                    Circle().trim(from: 0, to: max(0.03, fraction))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                }
                if updater.phase == .installing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(Theme.Typography.glyph(12, .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 28, height: 28)
            if horizontal && hover {
                Text(UpdateButton.label(updater.phase, version: version))
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.text)
                    .padding(.trailing, 8)
            }
        }
        .motion(Theme.Motion.hover, value: hover)
    }

    private var symbol: String {
        switch updater.phase {
        case .ready: "arrow.clockwise"
        case .failed: "exclamationmark"
        default: "arrow.down"
        }
    }

    private var tint: AnyShapeStyle {
        switch updater.phase {
        case .ready: AnyShapeStyle(Theme.green)
        case .failed: AnyShapeStyle(Theme.red)
        case .downloading: AnyShapeStyle(Theme.secondary)
        default: AnyShapeStyle(Theme.accent)
        }
    }
}


struct DrawerRow: View {
    let row: AgentRow
    let store: Store
    @Bindable var ui: UIState
    /// Unused (the switcher numbers are gone); kept so older call sites compile.
    var number: Int = 0
    /// Under/over a horizontal pill: tile, title, then project and status on a second line.
    var twoLines = false
    /// Search: the words to highlight in the title.
    var highlight: String?
    /// Search results mix kept sessions and others: say which aren't in your list.
    var showsKept = false
    /// In the hub, beside its bar tile: padded and highlighted like the inbox's rows (`.rowHighlight`).
    var inHub = false
    /// Inside a larger block that draws the highlight itself (title and details hover as one).
    var plain = false

    var body: some View {
        let selected = ui.drawerSelection == row.id
        // The hub's one-line rows get the shared row look; the two-line and drawer rows pad and fill by hand.
        let hubRow = inHub && !twoLines
        let content = HStack(spacing: 9) {
            if twoLines { AgentTile(row: row, size: 24) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(row.unread ? Theme.Typography.title : Theme.Typography.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if twoLines {
                    HStack(spacing: 4) {
                        ProjectLabel(session: row.session, color: row.color).foregroundStyle(Theme.tertiary)
                        Text("·").foregroundStyle(Theme.tertiary)
                        status
                        if showsKept && !row.entry.kept {
                            Text("· not in your list").foregroundStyle(Theme.tertiary)
                        }
                    }
                    .font(Theme.Typography.meta)
                    .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)

            if selected && !plain {
                AgentActions(row: row, store: store)
            } else if !twoLines {
                // In a hub block the actions are laid over this spot instead: the status steps aside without the
                // row changing size.
                status.font(Theme.Typography.numeral).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: busy ? 170 : 110, alignment: .trailing)
                    .fixedSize(horizontal: busy, vertical: false)
                    .layoutPriority(busy ? 2 : 0)
                    .opacity(selected && plain ? 0 : 1)
            }
        }
        Group {
            if hubRow {
                content.rowHighlight(hover: selected && !plain)
            } else {
                content
                    .padding(.leading, 10)
                    .padding(.trailing, selected ? 3 : 10)
                    .frame(height: twoLines ? Theme.Metrics.twoLineRow : nil)
                    .frame(maxHeight: twoLines ? Theme.Metrics.twoLineRow : .infinity)
                    .background(Theme.Radius.shape(Theme.Radius.row).fill(selected && !plain ? Theme.Fill.hover : Theme.Fill.rest))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.openAgent(row.id) }
        .onHover { if $0 { ui.drawerSelection = row.id } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.session.title)
        .accessibilityValue(row.stateName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.openAgent(row.id) }
    }

    /// Working, or done with something still running: the status says more than the end of the title.
    private var busy: Bool { row.session.running || !row.tasks.isEmpty }

    /// The title, with what you typed picked out.
    private var title: AttributedString {
        var text = AttributedString(row.session.title)
        let lower = row.session.title.lowercased()
        for word in (highlight ?? "").lowercased().split(separator: " ") {
            var from = lower.startIndex
            while let range = lower.range(of: word, range: from..<lower.endIndex) {
                if let r = Range(NSRange(range, in: lower), in: text) { text[r].foregroundColor = Theme.amber }
                from = range.upperBound
            }
        }
        return text
    }

    @ViewBuilder private var status: some View {
        if row.session.running {
            WorkingText(row: row)
        } else {
            HStack(spacing: 4) {
                Text(row.pending && !row.unread ? (row.entry.kept || showsKept ? row.statusText : "new activity") : row.statusText)
                    .foregroundStyle(row.statusColor)
                if let tasks = row.tasksText {
                    Text("·").foregroundStyle(Theme.tertiary)
                    Text(tasks).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

/// The drawer's last row: a new scratch session on the row itself, one in a listed project from its tile, and
/// every option by name in the menu when there are more projects than tiles.
struct NewSessionRow: View {
    let store: Store
    var style: Style = .drawer

    enum Style {
        /// The pill's drawer: a small "+" before the label.
        case drawer
        /// The hub, beside its bar cell (the cell is the "+"): the label and the project tiles, padded like a row.
        case detail
        /// The hub's two-line session rows (top and bottom edges): a 24pt "+" tile where theirs sit, 44pt tall.
        case twoLines
    }

    static let maxTiles = 4

    var body: some View {
        let folders = store.agentFolders
        HStack(spacing: 5) {
            Button { store.startScratchSession() } label: { NewSessionLabel(style: style) }
                .buttonStyle(HoverFillButtonStyle())
                .tip("New session", "Scratch chat, no folder · or pick a project")

            let shown = Array(folders.prefix(Self.maxTiles))
            let initials = Self.initials(shown.map { URL(fileURLWithPath: $0).lastPathComponent })
            ForEach(Array(shown.enumerated()), id: \.element) { i, folder in
                ProjectTile(folder: folder, initials: initials[i], color: store.projectColor(folder)) { store.startAgent(in: folder) }
            }
            if folders.count > Self.maxTiles { menu(folders) }
        }
        .padding(.trailing, style == .drawer ? 4 : 8)
        .frame(height: style == .twoLines ? 44 : nil)
        .frame(minHeight: style == .detail ? Theme.Metrics.line : nil)
    }

    private func menu(_ folders: [String]) -> some View {
        Menu {
            Button("Scratch (no folder)") { store.startScratchSession() }
            Divider()
            ForEach(folders, id: \.self) { folder in
                Button(URL(fileURLWithPath: folder).lastPathComponent) { store.startAgent(in: folder) }
            }
        } label: {
            Image(systemName: "chevron.down").font(Theme.Typography.glyph(9))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.tertiary)
        .frame(width: 20, height: 22)
        .tip("New session in…", "Every project, by name")
    }

    /// Two letters per project, told apart from the others shown: the first letters of its first two words
    /// ("lcu-research" → LR), else its first two; on a clash, its first and last.
    static func initials(_ names: [String]) -> [String] {
        func first(_ name: String) -> String {
            let words = name.split { !$0.isLetter && !$0.isNumber }
            if words.count >= 2 { return String([words[0].first!, words[1].first!]) }
            return String(name.filter { $0.isLetter || $0.isNumber }.prefix(2))
        }
        var out = names.map { first($0).uppercased() }
        for i in out.indices where out.firstIndex(of: out[i]) != i {
            let letters = names[i].filter { $0.isLetter || $0.isNumber }
            if let a = letters.first, let b = letters.last { out[i] = String([a, b]).uppercased() }
        }
        return out.map { $0.isEmpty ? "?" : $0 }
    }

    /// The app's new-session link with no folder opens its composer with none picked: a scratch session.
    static func startScratch() {
        guard let url = URL(string: "claude://code/new") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The new-session row's button face: a "+" (except beside a bar cell) and the label, brighter on hover.
private struct NewSessionLabel: View {
    let style: NewSessionRow.Style
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        HStack(spacing: 9) {
            if style != .detail { plus }
            Text("New session").font(Theme.Typography.body).foregroundStyle(hover ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.secondary))
            Spacer(minLength: 4)
        }
        .padding(.leading, leading)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var leading: CGFloat {
        switch style {
        case .drawer: 6
        case .detail: 8
        case .twoLines: 10
        }
    }

    @ViewBuilder private var plus: some View {
        let size: CGFloat = style == .twoLines ? 24 : 18
        Image(systemName: "plus")
            .font(Theme.Typography.glyph(style == .twoLines ? 11 : 10, .bold))
            .foregroundStyle(hover ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.secondary))
            .frame(width: size, height: size)
            .background(Tile.shape(size).fill(hover ? Theme.Fill.selected : Theme.Fill.field))
    }
}

/// A listed project in the new-session row: its colour, its initials, its name on hover.
private struct ProjectTile: View {
    let folder: String
    let initials: String
    let color: Color?
    let action: () -> Void

    var body: some View {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        Button(action: action) { ProjectTileFace(initials: initials, color: color) }
            // The face does its own hover look (a ring), so the style adds no fill.
            .buttonStyle(HoverFillButtonStyle(shape: Theme.Radius.shape(Theme.Radius.small), hover: .clear, pressed: .clear))
            .accessibilityLabel("New session in \(name)")
            .tip("New session in \(name)", folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }
}

private struct ProjectTileFace: View {
    let initials: String
    let color: Color?
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        let shape = Theme.Radius.shape(Theme.Radius.tile)
        Text(initials)
            .font(Theme.Typography.tile)
            .foregroundStyle(color == nil ? Theme.text.opacity(0.88) : Theme.onTint)
            .frame(width: 22, height: 22)
            .background(shape.fill(color ?? Theme.Fill.tile))
            .opacity(hover ? 1 : 0.8)
            .overlay { if hover { shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5).padding(-2.5) } }
            .contentShape(shape)
            .motion(Theme.Motion.hover, value: hover)
    }
}

// MARK: - Kept for the hub to adopt (the classic UI's menus and warnings)

/// A session's context menu: open, read state, label, keep/remove, project colour, mute.
struct SessionMenu: View {
    let row: AgentRow
    let store: Store
    /// Opens the label editor (`LabelEditor`) wherever the caller hosts it.
    var editLabel: () -> Void = {}

    var body: some View {
        Button("Open in Claude") { store.openAgent(row.id) }
        Button(row.unread ? "Mark as read" : "Mark as unread") { store.toggleAgentRead(row.id) }
        Button("Change label…") { editLabel() }
        Divider()
        if row.pending {
            Button("Keep") { store.keepAgent(row.id) }
            Button("Hide") { store.dismissAgent(row.id) }
        } else {
            Button("Hide") { store.dismissAgent(row.id) }
        }
        if !row.session.folderKey.isEmpty {
            Menu("Colour for \(row.session.folderName)") {
                ForEach(Theme.projectColorNames.indices, id: \.self) { i in
                    Button(Theme.projectColorNames[i]) { store.setProjectColor(row.session.folderKey, i) }
                }
            }
        }
        Button("Mute \(row.session.folderName)") { store.setFolderMuted(row.session.folderKey, true) }
    }
}

/// The Claude link's state as a dot and a line ("Synced with Claude", "Claude's sessions not found"…).
struct ClaudeLinkStatus: View {
    let store: Store

    var body: some View {
        let (color, text, detail): (AnyShapeStyle, String, String) = switch store.claudeLink {
        case .ok where Claude.isRunning: (AnyShapeStyle(Theme.tertiary), "Synced with Claude", "Updates as the Claude app writes its session files")
        case .ok, .off: (AnyShapeStyle(Theme.tertiary), "Claude isn't running", "Sessions update again when the app is open")
        case .missing: (AnyShapeStyle(Theme.red), "Claude's sessions not found", "Open the Claude desktop app once")
        case .unreadable: (AnyShapeStyle(Theme.red), "Can't read Claude's sessions", "The app's session format changed")
        }
        Circle().fill(color).frame(width: 6, height: 6)
        Text(text).tip(text, detail)
    }
}

/// "N API calls left this hour", only when the shared GitHub rate limit is running low.
struct RateLimitWarning: View {
    let store: Store

    var body: some View {
        if let rate = store.rateRemaining, rate < 500 {
            Label("\(rate.formatted()) API calls left this hour", systemImage: "exclamationmark.triangle.fill")
                .monospacedDigit()
                .foregroundStyle(Theme.amber)
                .tip("GitHub rate limit low",
                     "Shared with gh and other tools using your account. Syncing pauses at 0 until the hour resets.")
        }
    }
}

extension EnvironmentValues {
    /// Playground only: force a tooltip to show.
    @Entry var previewTip: String? = nil
}
