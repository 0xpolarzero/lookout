import SwiftUI

// Repositories (DESIGN.md 5.8): the add field, then one row per watched repository.

/// What a repository tells you about, in three words. A preset is a state of the flags the repository already has
/// (its five event kinds and `allComments`), not a new setting: `init(_:)` names the state, `Store.setPreset` makes
/// it. Anything else is Custom, which shows the flags as checkboxes.
enum RepoPreset: CaseIterable {
    case everything, forMe, custom

    var title: String {
        switch self {
        case .everything: "Everything"
        case .forMe: "Only what's for me"
        case .custom: "Custom"
        }
    }

    /// The kinds a preset is about; CI has its own switch on the row.
    static let kinds = Set(EventKind.repoToggles).subtracting([.ciMain])

    init(_ repo: RepoConfig) {
        guard repo.events.isSuperset(of: Self.kinds) else { self = .custom; return }
        self = repo.allComments ? .everything : .forMe
    }

    /// Whether the preset turns All comments on; nil for Custom, which keeps the flags as they are.
    var allComments: Bool? {
        switch self {
        case .everything: true
        case .forMe: false
        case .custom: nil
        }
    }
}

extension Store {
    /// Turns on every kind the preset covers and sets All comments to match, through the same calls the checkboxes
    /// make (so turning All comments off prunes what wasn't for you).
    func setPreset(_ preset: RepoPreset, on repo: RepoConfig) {
        guard let allComments = preset.allComments else { return }
        for kind in RepoPreset.kinds where !repo.events.contains(kind) { toggle(kind, on: repo) }
        if repo.allComments != allComments { toggleAllComments(repo) }
    }

    /// What it takes to bring a repository back after Stop watching: its row, its place in the list, and what
    /// `removeRepo` clears with it.
    struct StoppedRepo: Equatable {
        let repo: RepoConfig
        let index: Int
        let items: [InboxItem]
        let ci: CIStatus?
        let mutedCI: String?
    }

    func stopWatching(_ repo: RepoConfig) -> StoppedRepo? {
        guard let index = repos.firstIndex(where: { $0.id == repo.id }) else { return nil }
        let stopped = StoppedRepo(repo: repos[index], index: index,
                                  items: items.filter { $0.repo == repo.fullName && $0.kind != .reviewRequested },
                                  ci: ci[repo.fullName], mutedCI: mutedCI[repo.fullName])
        removeRepo(repo)
        return stopped
    }

    func resumeWatching(_ stopped: StoppedRepo) {
        guard !repos.contains(where: { $0.id == stopped.repo.id }) else { return }
        repos.insert(stopped.repo, at: min(stopped.index, repos.count))
        let known = Set(items.map(\.id))
        items.append(contentsOf: stopped.items.filter { !known.contains($0.id) })
        ci[stopped.repo.fullName] = stopped.ci
        mutedCI[stopped.repo.fullName] = stopped.mutedCI
        save()
    }

    /// Moves a repository one place up or down the list.
    func moveRepo(_ name: String, by step: Int) {
        guard let from = repos.firstIndex(where: { $0.fullName == name }), repos.indices.contains(from + step) else { return }
        moveRepo(name, onto: repos[from + step].fullName)
    }
}

struct ReposView: View {
    let store: Store
    @State private var input = ""
    @State private var error: String?
    @State private var adding = false
    /// The suggestion ↑↓ has picked.
    @State private var highlight: Int?
    @State private var stopped: Store.StoppedRepo?
    @FocusState private var fieldFocused: Bool
    /// Keeps the suggestions up while the pointer is on them: clicking one ends the editing before the click lands.
    @State private var overList = false
    @Environment(\.pagePreview) private var preview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var matches: [String] {
        let q = input.lowercased().trimmingCharacters(in: .whitespaces)
        let watched = Set(store.repos.map { $0.fullName.lowercased() })
        let open = store.suggestions.filter { !watched.contains($0.lowercased()) }
        guard !q.isEmpty else { return Array(open.prefix(store.repos.isEmpty ? 2 : 5)) }
        return Array(open.filter { $0.lowercased().contains(q) }.prefix(5))
    }

    private var showsSuggestions: Bool { fieldFocused || overList || preview.addQuery != nil }

    var body: some View {
        VStack(spacing: 0) {
            addRow
                .padding(.horizontal, Theme.Metrics.inset)
                .padding(.vertical, Theme.Space.md)
                // The suggestions hang over the list below.
                .zIndex(1)
            ScrollView {
                if store.repos.isEmpty {
                    EmptyBlock("Nothing watched yet", detail: "Watch your own repositories, or any public one you contribute to.")
                        .padding(.top, Theme.Space.xl)
                } else {
                    FormGroup(title: "Watching \(store.repos.count)") {
                        ForEach(Array(store.repos.enumerated()), id: \.element.id) { index, repo in
                            if index > 0 { FormDivider() }
                            RepoRow(repo: repo, store: store, isFirst: index == 0, isLast: index == store.repos.count - 1,
                                    stop: stopWatching)
                        }
                    }
                    .padding(.horizontal, Theme.Metrics.inset)
                    .padding(.bottom, Theme.Space.md)
                }
            }
            if let stopped {
                UndoLine(message: "Stopped watching \(stopped.repo.fullName)", undo: undoStop)
                    .padding(.horizontal, Theme.Metrics.inset)
                    .padding(.bottom, Theme.Metrics.inset)
                    // ⌘Z while the line is up.
                    .background(Button("Undo", action: undoStop).keyboardShortcut("z", modifiers: .command).hidden())
                    .task(id: stopped.repo.id) {
                        try? await Task.sleep(for: .seconds(6))
                        if !Task.isCancelled { withAnimation(Theme.Motion.fade.resolved(reduce: reduceMotion)) { self.stopped = nil } }
                    }
            }
        }
        .task { await store.loadSuggestions() }
        .onAppear {
            if let query = preview.addQuery {
                input = query
                DispatchQueue.main.async { highlight = preview.addHighlight }
            }
            // Nothing watched yet: the field is the one thing to do.
            if store.repos.isEmpty { DispatchQueue.main.async { fieldFocused = true } }
        }
        .onChange(of: input) { highlight = nil }
    }

    // MARK: Add

    private var addRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "plus").font(Theme.Typography.glyph(11, .semibold)).foregroundStyle(Theme.secondary)
                        .accessibilityHidden(true)
                    TextField("owner/repo or GitHub URL", text: $input)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                        .onKeyPress(.downArrow) { move(1) }
                        .onKeyPress(.upArrow) { move(-1) }
                        .onKeyPress(.escape) { closeSuggestions() }
                        .accessibilityLabel("Repository to watch")
                    if adding { ProgressView().controlSize(.mini) }
                }
                .fieldStyle(focused: fieldFocused)
                BorderedButton("Add") { add(input) }
                    .disabled(input.isEmpty || adding)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(Theme.Typography.meta).foregroundStyle(Theme.red)
                    .padding(.horizontal, Theme.Space.xs)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsSuggestions && (!matches.isEmpty || !input.isEmpty) {
                suggestions.padding(.top, Theme.Metrics.field + Theme.Space.xs)
            }
        }
    }

    private var suggestions: some View {
        VStack(spacing: 0) {
            if matches.isEmpty {
                Text("No match. Press Return to add owner/repo")
                    .font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, Theme.Space.md)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.menuRow, alignment: .leading)
            }
            ForEach(Array(matches.enumerated()), id: \.element) { index, name in
                SuggestionRow(name: name, picked: highlight == index) { add(name) }
            }
        }
        .padding(Theme.Space.xs)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(Theme.popover))
        .overlay(Theme.Radius.shape(Theme.Radius.row).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .onHover { overList = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    private func submit() {
        if let highlight, matches.indices.contains(highlight) { add(matches[highlight]) } else { add(input) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard showsSuggestions, !matches.isEmpty else { return .ignored }
        let next = (highlight ?? (step > 0 ? -1 : matches.count)) + step
        highlight = matches.indices.contains(next) ? next : nil
        return .handled
    }

    private func closeSuggestions() -> KeyPress.Result {
        guard showsSuggestions else { return .ignored }
        highlight = nil
        overList = false
        fieldFocused = false
        return .handled
    }

    private func add(_ name: String) {
        guard !name.isEmpty, !adding else { return }
        adding = true
        error = nil
        Task {
            let err = await store.addRepo(name)
            adding = false
            error = err
            if err == nil {
                input = ""
                fieldFocused = false
                overList = false
            }
        }
    }

    // MARK: Stop watching

    private func stopWatching(_ repo: RepoConfig) {
        guard let result = store.stopWatching(repo) else { return }
        withAnimation(Theme.Motion.fade.resolved(reduce: reduceMotion)) { stopped = result }
        AccessibilityNotification.Announcement("Stopped watching \(repo.fullName). Undo available").post()
    }

    private func undoStop() {
        guard let stopped else { return }
        store.resumeWatching(stopped)
        withAnimation(Theme.Motion.fade.resolved(reduce: reduceMotion)) { self.stopped = nil }
    }
}

private struct SuggestionRow: View {
    let name: String
    let picked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "book.closed").font(Theme.Typography.glyph(11, .regular)).foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
                (Text(name.split(separator: "/").first.map { "\($0)/" } ?? "").foregroundStyle(Theme.tertiary)
                    + Text(name.split(separator: "/").last.map(String.init) ?? "").foregroundStyle(Theme.text))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(Theme.Typography.body)
            .padding(.horizontal, Theme.Space.md)
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.menuRow, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillButtonStyle(shape: Theme.Radius.shape(Theme.Radius.tile), rest: picked ? Theme.Fill.selected : Theme.Fill.rest,
                                          hover: picked ? Theme.Fill.selected : Theme.Fill.hover))
        .accessibilityLabel("Watch \(name)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A watched repository: its name, what it tells you about, and CI. 36pt; 44 with a failure line under it.
struct RepoRow: View {
    let repo: RepoConfig
    let store: Store
    let isFirst: Bool
    let isLast: Bool
    let stop: (RepoConfig) -> Void
    @State private var customOpen = false
    @State private var dropTarget = false
    @Environment(\.pagePreview) private var preview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var failure: String? { store.repoErrors[repo.fullName] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                name
                Spacer(minLength: Theme.Space.md)
                preset
                Toggle(isOn: binding(.ciMain)) { Text("CI").font(Theme.Typography.body).foregroundStyle(Theme.text) }
                    .toggleStyle(SwitchStyle())
                    .fixedSize()
                    .accessibilityLabel("CI")
            }
            .frame(minHeight: Theme.Metrics.formRow)
            if let failure { failureLine(failure) }
            if customOpen { custom }
        }
        .overlay(alignment: .top) {
            if dropTarget { Capsule().fill(Theme.accent).frame(height: 2).offset(y: -1) }
        }
        .focusable()
        .focusRing(Theme.Radius.row, inset: true)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard press.modifiers == .option else { return .ignored }
            move(press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .draggable(repo.fullName) {
            Text(repo.fullName)
                .font(Theme.Typography.title)
                .padding(.horizontal, Theme.Space.lg)
                .frame(height: Theme.Metrics.tile)
                .background(Capsule().fill(Theme.popover))
                .foregroundStyle(Theme.text)
        }
        .dropDestination(for: String.self) { names, _ in
            guard let name = names.first else { return false }
            withAnimation(Theme.Motion.move.resolved(reduce: reduceMotion)) { store.moveRepo(name, onto: repo.fullName) }
            return true
        } isTargeted: { dropTarget = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(repo.fullName)
        .accessibilityAction(named: "Toggle issues") { toggle([.issueOpened, .issueComment]) }
        .accessibilityAction(named: "Toggle pull requests") { toggle([.prOpened, .prComment, .reviewComment]) }
        .accessibilityAction(named: "Toggle CI") { store.toggle(.ciMain, on: repo) }
        .accessibilityAction(named: "Move up") { move(-1) }
        .accessibilityAction(named: "Move down") { move(1) }
        .accessibilityAction(named: "Stop watching") { stop(repo) }
        .onAppear { customOpen = preview.expandedRepo == repo.fullName }
    }

    /// `owner/` quiet, the name in bold; the middle gives way first.
    private var name: some View {
        (Text("\(repo.owner)/").foregroundStyle(Theme.tertiary) + Text(repo.name).fontWeight(.semibold).foregroundStyle(Theme.text))
            .font(Theme.Typography.body)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: Preset

    private var preset: some View {
        let shown: RepoPreset = customOpen ? .custom : RepoPreset(repo)
        return PopUp(label: "Notify me about, \(repo.fullName)", value: shown.title) {
            ForEach(RepoPreset.allCases, id: \.self) { choice in
                Toggle(choice.title, isOn: Binding(get: { shown == choice }, set: { _ in choose(choice) }))
            }
        }
    }

    private func choose(_ choice: RepoPreset) {
        withAnimation(Theme.Motion.move.resolved(reduce: reduceMotion)) {
            if choice == .custom {
                customOpen.toggle()
            } else {
                customOpen = false
                store.setPreset(choice, on: repo)
            }
        }
    }

    // MARK: Custom

    private var custom: some View {
        let hasComments = !repo.events.isDisjoint(with: [.issueComment, .prComment, .reviewComment])
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.checkboxes, id: \.kind) { box in
                Toggle(box.title, isOn: binding(box.kind)).toggleStyle(.checkbox).frame(minHeight: Theme.Metrics.menuRow)
            }
            Toggle("Every comment, not only the ones for me", isOn: Binding(get: { repo.allComments }, set: { _ in store.toggleAllComments(repo) }))
                .toggleStyle(.checkbox)
                .frame(minHeight: Theme.Metrics.menuRow)
                .disabled(!hasComments)
            Text("Otherwise only comments on your issues and pull requests, mentioning you, or after you joined the conversation.")
                .font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.text)
        .padding(.bottom, Theme.Space.md)
        .transition(.opacity)
    }

    private static let checkboxes: [(kind: EventKind, title: String)] = [
        (.issueOpened, "Issues opened"), (.issueComment, "Issue comments"), (.prOpened, "Pull requests opened"),
        (.prComment, "Pull request comments"), (.reviewComment, "Review comments"),
    ]

    private func binding(_ kind: EventKind) -> Binding<Bool> {
        Binding(get: { repo.events.contains(kind) }, set: { _ in store.toggle(kind, on: repo) })
    }

    /// All on, or if any is on, all off.
    private func toggle(_ kinds: [EventKind]) {
        let turnOn = !kinds.contains { repo.events.contains($0) }
        for kind in kinds where repo.events.contains(kind) != turnOn { store.toggle(kind, on: repo) }
    }

    // MARK: Failure

    /// A line of its own under the name: the sentence truncates, Retry keeps its place at the end. It overlaps the
    /// 36pt row's empty margin, which makes the row 44.
    private func failureLine(_ message: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.circle.fill").font(Theme.Typography.glyph(11, .regular)).foregroundStyle(Theme.red)
                .accessibilityHidden(true)
            Text("Couldn't sync: \(message)").font(Theme.Typography.meta).foregroundStyle(Theme.red).lineLimit(1)
            Spacer(minLength: Theme.Space.md)
            Button(action: store.refreshNow) {
                Text("Retry").font(Theme.Typography.control).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, Theme.Space.xs)
                    .frame(minHeight: Theme.Metrics.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(Theme.Radius.small)
        }
        .frame(height: 14)
        .padding(.top, -6)
        .padding(.bottom, Theme.Space.sm)
        .accessibilityElement(children: .contain)
    }

    // MARK: Menu and order

    @ViewBuilder private var menu: some View {
        Button("Open on GitHub", systemImage: "arrow.up.right") { NSWorkspace.shared.open(repo.url) }
        Button("Open Actions", systemImage: "play.circle") { NSWorkspace.shared.open(repo.url.appendingPathComponent("actions")) }
        if let url = store.ci[repo.fullName]?.url {
            Button("Open latest commit checks", systemImage: "checkmark.circle") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Move up", systemImage: "arrow.up") { move(-1) }.disabled(isFirst)
        Button("Move down", systemImage: "arrow.down") { move(1) }.disabled(isLast)
        Divider()
        Button("Stop watching", systemImage: "eye.slash", role: .destructive) { stop(repo) }
    }

    private func move(_ step: Int) {
        withAnimation(Theme.Motion.move.resolved(reduce: reduceMotion)) { store.moveRepo(repo.fullName, by: step) }
    }
}
