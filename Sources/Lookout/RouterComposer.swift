import AppKit
import SwiftUI

/// Where you write to the Router: Return sends, ⇧Return starts a new line (see `RouterKeys`). Over the field, the chips
/// that go with the message: the card it replies to and the projects tagged with @ (each with its ×; Backspace at the start
/// takes the last off). Typing @ suggests projects (↑↓, Return or Tab picks, Esc dismisses). Stop while the Router works; a
/// menu to start the conversation over.
struct RouterComposer: View {
    let store: Store
    @Bindable var model: RouterModel
    let agent: RouterAgent
    @FocusState private var focused: Bool
    /// The suggestions' height, to hang them over the field.
    @State private var listHeight: CGFloat = 0
    /// Where the field is in its window: tells its text view from every other one.
    @State private var anchor = FieldAnchor()
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let working = agent.phase == .working || agent.phase == .starting
        let on = model.canSend(store)
        let suggestions = model.suggestions(store)
        VStack(alignment: .leading, spacing: 6) {
            if model.replyTo != nil || !model.projects.isEmpty { chips }
            HStack(alignment: .bottom, spacing: 6) {
                menu
                field(on: on)
                    // Over the field, so it never pushes the chat about.
                    .overlay(alignment: .topLeading) {
                        if !suggestions.isEmpty {
                            MentionList(suggestions: suggestions, index: model.mentionIndex) { model.pickMention($0) }
                                .fixedSize()
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                                .offset(y: -listHeight - 6)
                                .transition(.opacity)
                        }
                    }
                    .zIndex(1)
                if working {
                    IconButton(symbol: "stop.fill", help: "Stop", detail: "Interrupts the Router's turn", size: Theme.Metrics.field) {
                        agent.stop()
                    }
                } else {
                    IconButton(symbol: "arrow.up", help: "Send", detail: "Return · ⇧Return for a new line", size: Theme.Metrics.field,
                               tint: Theme.accent) { model.send(store: store) }
                        .disabled(!on || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .motion(Theme.Motion.fade, value: suggestions.map(\.folder))
        .onAppear { if on { requestFocus() } }
        .onChange(of: model.focusRequest) { requestFocus() }
        .onChange(of: focused) { _, now in
            model.composerFocused = now
            if now { DispatchQueue.main.async { typePendingKeys() } }
        }
        .onDisappear { model.composerFocused = false }
        // The @ suggestions follow the caret, wherever it is in the text.
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { note in
            // Only the composer's own editor, while it edits: in its window, where its field is (not another window's, nor a
            // form's "Other…"), and still the window's first responder (ending its editing, when the composer loses the
            // keyboard, moves the editor's selection; that isn't the caret moving).
            guard let editor = note.object as? NSTextView, anchor.owns(editor), editor.window?.firstResponder === editor
            else { return }
            model.followCaret(editor)
        }
        .onChange(of: model.caretRequest) { _, request in
            guard let request else { return }
            model.caretRequest = nil
            // After the field has the new text.
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                let at = min(request, (editor.string as NSString).length)
                editor.setSelectedRange(NSRange(location: at, length: 0))
                model.followCaret(editor)
            }
        }
    }

    /// The reply first, then the projects, each removable.
    private var chips: some View {
        FlowLayout(spacing: 5) {
            if let id = model.replyTo, let card = store.router.cards.first(where: { $0.id == id }) {
                ComposerChip(symbol: "arrowshape.turn.up.left.fill", text: "Replying to \(card.title)", tint: card.kind.color,
                             removeLabel: "Stop replying to \(card.title)") { model.replyTo = nil }
            }
            ForEach(model.projects, id: \.self) { folder in
                let name = store.folderName(folder)
                ComposerChip(symbol: nil, text: "@" + name, tint: store.projectColor(folder) ?? Theme.secondary,
                             removeLabel: "Remove project \(name)") { model.projects.removeAll { $0 == folder } }
            }
        }
        .padding(.leading, 34)
    }

    private var menu: some View {
        Menu {
            Button("New Conversation") {
                if store.routerIsPretend { store.router.chat = [] } else { agent.newConversation() }
            }
            .disabled(store.router.chat.isEmpty && store.router.claudeSessionID == nil)
        } label: {
            Image(systemName: "ellipsis.circle").font(Theme.Typography.glyph(14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: Theme.Metrics.field)
        .accessibilityLabel("Router menu")
        .tip("More", "New conversation")
    }

    private func field(on: Bool) -> some View {
        TextField(model.replyTo == nil ? "Message the Router · @ for a project" : "Your reply", text: $model.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .lineLimit(1...6)
            .focused($focused)
            .focusEffectDisabled()
            .accessibilityLabel("Message the Router")
            .accessibilityHint("Return sends, Shift Return starts a new line, @ tags a project")
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minHeight: Theme.Metrics.field)
            .background(Theme.Radius.shape(Theme.Radius.md).fill(Theme.Fill.field))
            .overlay(Theme.Radius.shape(Theme.Radius.md)
                .strokeBorder(focused ? Theme.accent.opacity(0.6) : contrast == .increased ? Theme.text.opacity(0.5) : Theme.stroke))
            .background(AnchorView(anchor: anchor))
            .disabled(!on)
    }

    private func requestFocus() {
        DispatchQueue.main.async {
            focused = true
            DispatchQueue.main.async { typePendingKeys() }
        }
    }

    /// The keys that sent the focus here (typing with no field focused), typed into the composer in order.
    private func typePendingKeys() {
        guard !model.pendingKeys.isEmpty,
              let editor = (model.pendingKeys.first?.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView else { return }
        let keys = model.pendingKeys
        model.pendingKeys = []
        editor.moveToEndOfDocument(nil)
        keys.forEach(editor.keyDown(with:))
    }
}

/// A chip over the composer: what goes with the message, and an × to take it off.
struct ComposerChip: View {
    let symbol: String?
    let text: String
    let tint: Color
    let removeLabel: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(Theme.Typography.glyph(9)).foregroundStyle(tint).accessibilityHidden(true) }
            Text(text).font(Theme.Typography.control).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
            Button(action: remove) {
                Image(systemName: "xmark").font(Theme.Typography.glyph(8, .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(HoverFillButtonStyle(shape: Circle()))
            .foregroundStyle(Theme.tertiary)
            .accessibilityLabel(removeLabel)
        }
        .padding(.leading, symbol == nil ? 9 : 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text)
    }
}

/// The @ suggestions: the projects the word matches, the one ↑↓ picked lit.
struct MentionList: View {
    let suggestions: [(folder: String, name: String)]
    let index: Int
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.folder) { i, project in
                Button { pick(project.folder) } label: {
                    HStack(spacing: 8) {
                        Text("@" + project.name).font(Theme.Typography.body).foregroundStyle(Theme.text)
                        Spacer(minLength: 8)
                        Text(Self.shortPath(project.folder)).font(Theme.Typography.caption).foregroundStyle(Theme.tertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.Radius.shape(Theme.Radius.sm).fill(i == index ? Theme.Fill.selected : Theme.Fill.rest))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Project \(project.name)")
                .accessibilityAddTraits(i == index ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(width: 300)
        .background(Theme.Radius.shape(Theme.Radius.md).fill(Theme.popover))
        .overlay(Theme.Radius.shape(Theme.Radius.md).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Projects")
    }

    /// `~/code/lookout` rather than the whole path.
    static func shortPath(_ folder: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}

/// The composer field's place on screen, kept by an empty AppKit view behind it: a text view is the composer's when it is in
/// the same window and inside the field (SwiftUI doesn't hand out the field's own text view).
final class FieldAnchor {
    weak var view: NSView?

    func owns(_ editor: NSTextView) -> Bool {
        guard let view, let window = view.window, editor.window === window else { return false }
        let field = view.convert(view.bounds, to: nil)
        let text = editor.convert(editor.bounds, to: nil)
        return field.contains(CGPoint(x: text.midX, y: text.midY))
    }
}

private struct AnchorView: NSViewRepresentable {
    let anchor: FieldAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
