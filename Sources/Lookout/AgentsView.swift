import SwiftUI

/// A session's tile: its two letters (or emoji) on its status colour. Working agents get a pulsing dot in the
/// corner; pending sessions are a size smaller and dimmer.
struct AgentTile: View {
    let row: AgentRow
    var size: CGFloat = 26
    var selected = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
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
            .foregroundStyle(row.tint == nil ? Theme.text.opacity(0.88) : Color.black.opacity(0.78))
            .frame(width: size, height: size)
            .background(shape.fill(row.tint ?? Color.white.opacity(0.1)))
            .opacity(row.pending ? 0.55 : 1)
            .overlay {
                if selected { shape.strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5).padding(-3) }
            }
            .overlay(alignment: .topTrailing) {
                if row.session.running && !row.waitsForYou { WorkingDot().offset(x: 3, y: -3) }
            }
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

/// "Running swift test · 3m", ticking.
struct WorkingText: View {
    let row: AgentRow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(row.workingText(now: context.date)).foregroundStyle(row.waitsForYou ? Theme.amber : Theme.claude)
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
                Image(systemName: "text.bubble").font(.system(size: 9))
            }
            Text(session.folderName)
        }
    }
}

/// "Still working": a small clay dot that breathes.
struct WorkingDot: View {
    var size: CGFloat = 8
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(Theme.claude)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5).padding(-1.5))
            .opacity(breathe ? 0.5 : 1)
            .scaleEffect(breathe ? 0.85 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever()) { breathe = true }
            }
    }
}

// MARK: - Agents tab

struct AgentsView: View {
    let store: Store
    @Bindable var ui: UIState

    var body: some View {
        VStack(spacing: 0) {
            if store.claudeLink == .ok || store.claudeLink == .off {
                AddSessionField(store: store).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        let rows = store.agentRows
        switch store.claudeLink {
        case .missing, .unreadable:
            placeholder(symbol: "exclamationmark.triangle", tint: Theme.red, title: "Can't read Claude's sessions",
                        subtitle: store.claudeLink == .missing
                            ? "The Claude desktop app's session folder isn't there. Open the app once, then come back."
                            : "The Claude app changed how it stores sessions. Lookout's GitHub tabs keep working.")
        case .off, .ok:
            if rows.kept.isEmpty && rows.pending.isEmpty {
                placeholder(symbol: "asterisk", tint: Theme.claude, title: "No sessions yet",
                            subtitle: "Search above to add one, or wait: sessions with new activity show up here. Keep the ones you use to pin them to the pill.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if !rows.kept.isEmpty {
                                sectionTitle("Sessions", rows.kept.count, hint: "drag to reorder")
                                ForEach(store.groups(rows.kept), id: \.first!.id) { group in
                                    projectHeader(group[0])
                                    ForEach(group) { row in item(row, grouped: true).id(row.id) }
                                }
                            }
                            if !rows.pending.isEmpty {
                                sectionTitle("Pending", rows.pending.count, hint: "new activity, not kept")
                                    .padding(.top, rows.kept.isEmpty ? 0 : 10)
                                ForEach(rows.pending) { row in item(row).id(row.id) }
                            }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: ui.agentSelection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                }
            }
        }
    }

    private func item(_ row: AgentRow, grouped: Bool = false) -> some View {
        AgentListRow(row: row, store: store, selected: ui.agentSelection == row.id, grouped: grouped) { ui.agentSelection = row.id }
    }

    private func projectHeader(_ row: AgentRow) -> some View {
        ProjectLabel(session: row.session, color: row.color)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.leading, 14)
            .padding(.top, 8)
            .padding(.bottom, 1)
    }

    private func sectionTitle(_ title: String, _ count: Int, hint: String) -> some View {
        HStack {
            Text("\(title.uppercased())  \(count)")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
            Spacer()
            Text(hint).font(.system(size: 10.5))
        }
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func placeholder(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(tint)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Search your Claude sessions by name (or folder) and keep one in a click.
private struct AddSessionField: View {
    let store: Store
    @State private var query = ""
    @FocusState private var focused: Bool
    /// Keeps the list up while the pointer is on it: clicking a suggestion ends the editing before the click lands.
    @State private var overList = false

    var body: some View {
        let matches = store.agentCandidates(matching: query)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary).font(.system(size: 12))
                TextField("Add a session by name", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = matches.first { add(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary).font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .fieldStyle()
            if focused || overList {
                VStack(spacing: 0) {
                    if matches.isEmpty {
                        Text(query.isEmpty ? "Every session is in your list" : "No session matches “\(query)”")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                    }
                    ForEach(matches) { session in
                        SessionSuggestion(session: session) { add(session) }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                .onHover { overList = $0 }
            }
        }
    }

    private func add(_ session: ClaudeSession) {
        withAnimation(.spring(duration: 0.25)) { store.keepAgent(session.id) }
        query = ""
        focused = false
        overList = false
    }
}

private struct SessionSuggestion: View {
    let session: ClaudeSession
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(session.title).foregroundStyle(Theme.text).lineLimit(1)
                Text(session.folderName).foregroundStyle(Theme.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                if hover {
                    Label("Keep", systemImage: "pin.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                } else {
                    Text(session.running ? "working" : shortAgo(session.lastActivity))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(session.running ? Theme.claude : Theme.tertiary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct AgentListRow: View {
    let row: AgentRow
    let store: Store
    let selected: Bool
    /// Under its project's header: no need to repeat the folder.
    var grouped = false
    var onHover: () -> Void = {}
    @State private var isHovering = false
    @State private var editing = false
    @State private var dropTarget = false
    @Environment(\.previewHover) private var previewHover
    private var hover: Bool { isHovering || previewHover == row.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { editing = true } label: { AgentTile(row: row, size: 28) }
                .buttonStyle(.plain)
                .tip("Change label", "Two letters, an emoji, or another icon")
                .popover(isPresented: $editing, arrowEdge: .bottom) { LabelEditor(row: row, store: store) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.session.title)
                        .font(.system(size: 13, weight: row.unread ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !hover && !row.session.running {
                        Text(row.statusText)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(row.statusColor)
                    }
                }
                let waiting = !row.session.running && row.session.summary?.blocked == true
                if !grouped || row.session.running || waiting {
                    HStack(spacing: 4) {
                        if !grouped {
                            ProjectLabel(session: row.session, color: row.color)
                            if row.session.running || waiting { Text("·") }
                        }
                        if row.session.running {
                            WorkingText(row: row)
                        } else if waiting {
                            Text("waiting for you").foregroundStyle(row.unread ? Theme.amber : Theme.tertiary)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                }
                if let detail = row.session.summary?.detail, !detail.isEmpty, !row.session.running {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
                // Always there (hiding it on hover would shift the row under the pointer).
                if row.pending {
                    HStack(spacing: 6) {
                        Button { store.keepAgent(row.id) } label: {
                            Label("Keep", systemImage: "pin.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 9)
                                .frame(height: 22)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        Button { store.dismissAgent(row.id) } label: {
                            Text("Dismiss").font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.white.opacity(0.09) : hover ? Theme.hover : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropTarget ? Theme.accent : .clear, lineWidth: 1.5)
        )
        .overlay(alignment: .topTrailing) {
            if hover { AgentActions(row: row, store: store, keepsInline: true).padding(6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.openAgent(row.id) }
        .onHover { inside in
            isHovering = inside
            if inside { onHover() }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu { menu }
        .zIndex(hover ? 1 : 0)
        .modifier(Reorderable(row: row, store: store, dropTarget: $dropTarget))
    }

    @ViewBuilder private var menu: some View {
        Button("Open in Claude") { store.openAgent(row.id) }
        Button(row.unread ? "Mark as read" : "Mark as unread") { store.toggleAgentRead(row.id) }
        Button("Change label…") { editing = true }
        Divider()
        if row.pending {
            Button("Keep") { store.keepAgent(row.id) }
            Button("Dismiss") { store.dismissAgent(row.id) }
        } else {
            Button("Remove from list") { store.dismissAgent(row.id) }
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

/// Only kept sessions can be dragged; dropping on another kept one moves it there.
private struct Reorderable: ViewModifier {
    let row: AgentRow
    let store: Store
    @Binding var dropTarget: Bool

    func body(content: Content) -> some View {
        if row.pending {
            content
        } else {
            content
                .draggable("agent:" + row.id) {
                    Text(row.session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(Theme.bg))
                        .foregroundStyle(Theme.text)
                }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, id.hasPrefix("agent:") else { return false }
                    withAnimation(.spring(duration: 0.25)) { store.moveAgent(String(id.dropFirst(6)), onto: row.id) }
                    return true
                } isTargeted: { dropTarget = $0 }
        }
    }
}

/// Hover/selection actions, the same in the panel and the pill's drawer.
struct AgentActions: View {
    let row: AgentRow
    let store: Store
    var size: CGFloat = 24
    /// The row already shows Keep and Dismiss (the Agents tab): only read/unread and open here.
    var keepsInline = false

    var body: some View {
        HStack(spacing: 2) {
            if row.pending && !keepsInline {
                IconButton(symbol: "pin.fill", help: "Keep", detail: "Pins it to your list · \(store.shortcut(.keepSession).display)", size: size) {
                    store.keepAgent(row.id)
                }
                IconButton(symbol: "xmark", help: "Dismiss", detail: "Until its next activity · \(store.shortcut(.removeSession).display)", size: size) {
                    store.dismissAgent(row.id)
                }
            } else {
                if row.unread {
                    IconButton(symbol: "checkmark", help: "Mark as read", detail: store.shortcut(.toggleRead).display, size: size) {
                        store.toggleAgentRead(row.id)
                    }
                } else {
                    IconButton(symbol: "circle.fill", help: "Mark as unread", detail: store.shortcut(.toggleRead).display, size: size) {
                        store.toggleAgentRead(row.id)
                    }
                }
                if !row.pending {
                    IconButton(symbol: "xmark", help: "Remove", detail: "Comes back as pending on new activity · \(store.shortcut(.removeSession).display)", size: size) {
                        store.dismissAgent(row.id)
                    }
                }
            }
            IconButton(symbol: "arrow.up.right", help: "Open in Claude", detail: store.shortcut(.openItem).display, size: size) {
                store.openAgent(row.id)
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.bg))
        .overlay(Capsule().strokeBorder(Theme.stroke))
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
            Text("Label for \(row.session.title)").font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            Text("Two letters or an emoji; empty goes back to the \(row.entry.icon != nil ? "icon" : "letters")")
                .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
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
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            }
            if store.agents.iconsEnabled && store.hasTypesafeKey && row.entry.label == nil {
                Button(row.entry.icon == nil ? "Pick an icon" : "Pick another icon") {
                    store.repickIcon(row.id)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
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
