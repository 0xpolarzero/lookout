import SwiftUI

// Repositories (DESIGN.md 5.8): the add field, then one row per watched repository.

/// What a repository tells you about, in three words. A preset is a state of the flags the repository already has
/// (its five event kinds and `allComments`), not a new setting: `init(_:)` names the state, `Store.setPreset` makes
/// it. Anything else is Custom, which shows the flags as checkboxes.
///
///   Everything          new issues and PRs, and every comment
///   Only what's for me  comments only, and only the ones for you (the rest of what is on your issues and PRs,
///                       mentions and threads you joined is judged by `Store.isRelevant`)
///
/// A repository that follows new issues and PRs but only the comments for you, which is how Lookout always started
/// them, is Custom: it is neither of the two.
enum RepoPreset: CaseIterable {
    case everything, forMe, custom

    var title: String {
        switch self {
        case .everything: "Everything"
        case .forMe: "Only what's for me"
        case .custom: "Custom"
        }
    }

    /// The kinds that are comments: the only ones "for me" can judge.
    static let comments: Set<EventKind> = [.issueComment, .prComment, .reviewComment]
    /// The kinds that are somebody opening something, which is never "for me" until it is commented on.
    static let opened: Set<EventKind> = [.issueOpened, .prOpened]
    /// The kinds a preset is about; CI has its own switch on the row.
    static let kinds = comments.union(opened)

    init(_ repo: RepoConfig) {
        let events = repo.events.intersection(Self.kinds)
        if events == Self.kinds, repo.allComments { self = .everything }
        else if events == Self.comments, !repo.allComments { self = .forMe }
        else { self = .custom }
    }

    /// The kinds the preset leaves on (and the rest off); nil for Custom, which keeps the flags as they are.
    var events: Set<EventKind>? {
        switch self {
        case .everything: Self.kinds
        case .forMe: Self.comments
        case .custom: nil
        }
    }

    /// Whether the preset turns All comments on; nil for Custom.
    var allComments: Bool? {
        switch self {
        case .everything: true
        case .forMe: false
        case .custom: nil
        }
    }

    /// What a repository's flags amount to, in a sentence: "New PRs and PR comments for you".
    static func summary(_ repo: RepoConfig) -> String {
        var parts: [String] = []
        if repo.events.contains(.issueOpened) { parts.append("new issues") }
        if repo.events.contains(.prOpened) { parts.append("new PRs") }
        let kinds = [(EventKind.issueComment, "issue"), (.prComment, "PR"), (.reviewComment, "review")].filter { repo.events.contains($0.0) }
        if !kinds.isEmpty {
            let which = kinds.count == comments.count ? "" : kinds.map(\.1).joined(separator: kinds.count == 2 ? " and " : ", ") + " "
            parts.append((repo.allComments ? "all " : "") + which + "comments" + (repo.allComments ? "" : " for you"))
        }
        guard !parts.isEmpty else { return "Nothing" }
        let sentence = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}

/// What went wrong with a repository, as a sentence about it. GitHub's and the system's own wording ("Forbidden",
/// "Not Found") has no subject and is worded differently for the same cause, so it goes in a tooltip and
/// VoiceOver's value, and the line says what it means for this repository.
enum RepoFailure: Equatable {
    case notFound, forbidden, rateLimited, badToken, unreachable

    /// Nil for a reason that is not one of these, which is left as it is.
    init?(reason: String) {
        let r = reason.lowercased()
        if r.contains("rate limit") { self = .rateLimited }
        else if r.contains("not found") { self = .notFound }
        else if r.contains("forbidden") { self = .forbidden }
        else if r.contains("rejected the token") || r.contains("bad credentials") { self = .badToken }
        else if ["internet connection", "network connection", "offline", "timed out", "could not connect", "hostname"].contains(where: r.contains) {
            self = .unreachable
        } else { return nil }
    }

    /// The line under a watched repository.
    func sync(of repo: String) -> String {
        switch self {
        case .notFound: "Couldn't find \(repo), or no access to it"
        case .forbidden: "No access to \(repo)"
        default: general
        }
    }

    /// The line under the add field, for what was typed.
    func add(_ name: String) -> String {
        switch self {
        case .notFound: "Couldn't find \(name) on GitHub. Check the owner/repo."
        case .forbidden: "No access to \(name)"
        default: general
        }
    }

    private var general: String {
        switch self {
        case .rateLimited: "GitHub is rate limiting requests"
        case .badToken: "GitHub rejected your token"
        default: "Couldn't reach GitHub"
        }
    }

    /// The row's line for a reason: unrecognised ones say the repository didn't sync, and nothing more.
    static func sync(_ reason: String, of repo: String) -> String {
        RepoFailure(reason: reason)?.sync(of: repo) ?? "Couldn't sync \(repo)"
    }

    /// Store's own sentences about what was typed: they are already a sentence about it.
    static let badFormat = "Use the owner/repo format"
    static func alreadyWatching(_ name: String) -> String { "Already watching \(name)" }

    /// The add field's line for a reason about `input`, which is what was submitted (a suggestion's name or what was
    /// typed): Store's own sentences are kept, and GitHub's or the system's wording is never shown as it is.
    static func add(_ reason: String, input: String) -> String {
        let name = repoName(from: input)
        if reason == badFormat || reason == alreadyWatching(name) { return reason }
        return RepoFailure(reason: reason)?.add(name) ?? "Couldn't add \(name)."
    }

    /// `owner/repo` out of what was typed (a GitHub URL too), as `Store.addRepo` reads it.
    static func repoName(from input: String) -> String {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "github.com/") { name = String(name[range.upperBound...]) }
        return name.split(separator: "/").prefix(2).joined(separator: "/")
    }
}

extension Store {
    /// Turns the preset's kinds on and the others off, and sets All comments to match, through the same calls the
    /// checkboxes make. What those calls remove from the inbox (issues and PRs that were opened, comments that
    /// weren't for you) does not come back by choosing the other preset: only `changePreset`'s undo restores it.
    func setPreset(_ preset: RepoPreset, on repo: RepoConfig) {
        guard let events = preset.events, let allComments = preset.allComments else { return }
        for kind in RepoPreset.kinds where repo.events.contains(kind) != events.contains(kind) { toggle(kind, on: repo) }
        if repo.allComments != allComments { toggleAllComments(repo) }
    }

    /// `setPreset` from the pop-up: when it changed anything, an undo line (and ⌘Z) puts the flags and the removed
    /// items back.
    func changePreset(_ preset: RepoPreset, on repo: RepoConfig) {
        guard let before = repos.first(where: { $0.id == repo.id }), preset.events != nil else { return }
        let itemsBefore = items.filter { $0.repo == repo.fullName }
        setPreset(preset, on: before)
        guard let after = repos.first(where: { $0.id == repo.id }),
              after.events != before.events || after.allComments != before.allComments else { return }
        // The flags this change moved, and nothing else: a checkbox chosen since stays as it is when it is undone.
        let moved = RepoPreset.kinds.filter { before.events.contains($0) != after.events.contains($0) }
        let movedAllComments = after.allComments != before.allComments
        let now = Set(items.map(\.id))
        let removed = itemsBefore.filter { !now.contains($0.id) }
        let message = "\(repo.name): \(preset.title)" + (removed.isEmpty ? "" : ", \(plural(removed.count, "item")) removed")
        repoUndo.push(message, announcement: "\(repo.fullName) set to \(preset.title). Undo available") { [self] in
            guard let i = repos.firstIndex(where: { $0.id == before.id }) else { return }
            for kind in moved {
                if before.events.contains(kind) { repos[i].events.insert(kind) } else { repos[i].events.remove(kind) }
            }
            if movedAllComments { repos[i].allComments = before.allComments }
            let known = Set(items.map(\.id))
            items.append(contentsOf: removed.filter { !known.contains($0.id) })
            save()
        }
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

    /// Stops watching, with an undo line and ⌘Z for 30 s that bring it all back.
    @discardableResult
    func stopWatching(_ repo: RepoConfig) -> StoppedRepo? {
        guard let index = repos.firstIndex(where: { $0.id == repo.id }) else { return nil }
        let stopped = StoppedRepo(repo: repos[index], index: index,
                                  items: items.filter { $0.repo == repo.fullName && $0.kind != .reviewRequested },
                                  ci: ci[repo.fullName], mutedCI: mutedCI[repo.fullName])
        removeRepo(repo)
        repoUndo.push("Stopped watching \(repo.fullName)") { [self] in resumeWatching(stopped) }
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
    /// What the last Add said went wrong, with the repository it was for: the field may have changed since.
    @State private var failure: (name: String, reason: String)?
    @State private var adding = false
    /// The suggestion ↑↓ has picked.
    @State private var highlight: Int?
    @FocusState private var fieldFocused: Bool
    /// Keeps the suggestions up while the pointer is on them: clicking one ends the editing before the click lands.
    @State private var overList = false
    /// The repositories whose Custom checkboxes are open. Kept here, not in each row, so a row that is rebuilt
    /// stays as it was.
    @State private var customOpen: Set<String> = []
    @Environment(\.pagePreview) private var preview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var matches: [String] {
        let q = input.lowercased().trimmingCharacters(in: .whitespaces)
        let watched = Set(store.repos.map { $0.fullName.lowercased() })
        let open = store.suggestions.filter { !watched.contains($0.lowercased()) }
        guard !q.isEmpty else { return Array(open.prefix(store.repos.isEmpty ? 2 : 5)) }
        return Array(open.filter { $0.lowercased().contains(q) }.prefix(5))
    }

    /// Whether the overlay is up. Not while an error is showing: the overlay starts right under the field, where the
    /// error is, and the error is what the last Return was about.
    private var showsSuggestions: Bool {
        failure == nil && (fieldFocused || overList || preview.addQuery != nil) && (!matches.isEmpty || !input.isEmpty)
    }

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
                                    customOpen: Binding(get: { customOpen.contains(repo.id) },
                                                        set: { if $0 { customOpen.insert(repo.id) } else { customOpen.remove(repo.id) } }))
                        }
                    }
                    .padding(.horizontal, Theme.Metrics.inset)
                    .padding(.bottom, Theme.Space.md)
                }
            }
            if let undo = store.repoUndo.visible {
                UndoLine(message: undo.message) { store.repoUndo.undo() }
                    .padding(.horizontal, Theme.Metrics.inset)
                    .padding(.bottom, Theme.Metrics.inset)
            }
        }
        .motion(Theme.Motion.fade, value: store.repoUndo.visibleID)
        .task { await store.loadSuggestions() }
        .onAppear {
            if let query = preview.addQuery {
                input = query
                // After the typing above has been seen: a change of the input clears an error.
                DispatchQueue.main.async {
                    highlight = preview.addHighlight
                    failure = preview.addError.map { (preview.addSubmitted ?? query, $0) }
                }
            }
            if let name = preview.expandedRepo { customOpen.insert(name) }
            // Nothing watched yet: the field is the one thing to do.
            if store.repos.isEmpty { DispatchQueue.main.async { fieldFocused = true } }
        }
        .onChange(of: input) {
            highlight = nil
            failure = nil
        }
        // A highlight that moves is read out: the field keeps VoiceOver's focus, but Return now adds that repository.
        .onChange(of: highlight) { _, now in
            guard let now, matches.indices.contains(now) else { return }
            AccessibilityNotification.Announcement("\(matches[now]), \(now + 1) of \(matches.count)").post()
        }
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
                        .accessibilityLabel("Repository to watch")
                    if adding { ProgressView().controlSize(.mini) }
                }
                .fieldStyle(focused: fieldFocused)
                BorderedButton("Add") { add(input) }
                    .disabled(input.isEmpty || adding)
            }
            if let failure {
                let sentence = RepoFailure.add(failure.reason, input: failure.name)
                Label(sentence, systemImage: "exclamationmark.circle.fill")
                    .font(Theme.Typography.meta).foregroundStyle(Theme.red)
                    .padding(.horizontal, Theme.Space.xs)
                    // What GitHub said, for whoever wants it.
                    .help(sentence == failure.reason ? "" : failure.reason)
                    .accessibilityValue(sentence == failure.reason ? "" : failure.reason)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsSuggestions { suggestions.padding(.top, Theme.Metrics.field + Theme.Space.xs) }
        }
        // Esc closes the suggestions before it goes back a page: the hub's key handler asks first.
        .cancelsOnEscape(showsSuggestions, perform: closeSuggestions)
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

    private func closeSuggestions() {
        highlight = nil
        overList = false
        fieldFocused = false
    }

    private func add(_ name: String) {
        guard !name.isEmpty, !adding else { return }
        adding = true
        failure = nil
        Task {
            let reason = await store.addRepo(name)
            adding = false
            failure = reason.map { (name, $0) }
            if reason == nil {
                input = ""
                fieldFocused = false
                overList = false
            } else {
                // The overlay is gone with the error showing; the pointer that was over it is not any more.
                overList = false
                highlight = nil
            }
        }
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

/// A watched repository: its name, what it tells you about, and CI. 36pt; 44 with a second line under the name (a
/// failure, or what Custom amounts to).
struct RepoRow: View {
    let repo: RepoConfig
    let store: Store
    let isFirst: Bool
    let isLast: Bool
    /// Whether the Custom checkboxes are showing.
    @Binding var customOpen: Bool
    @State private var dropTarget = false
    @FocusState private var retryFocused: Bool
    @Environment(\.pagePreview) private var preview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var failure: String? { store.repoErrors[repo.fullName] }
    /// What the pop-up says: Custom while its checkboxes are open, whatever the flags amount to.
    private var shown: RepoPreset { customOpen ? .custom : RepoPreset(repo) }

    var body: some View {
        let twoLines = failure != nil || shown == .custom
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
            .frame(minHeight: twoLines ? Self.firstLine : Theme.Metrics.formRow)
            if let failure { failureLine(failure) }
            if shown == .custom { summaryLine.padding(.top, failure == nil ? 0 : Theme.Space.hair) }
            if customOpen { custom }
        }
        // A second line sits close to the next divider otherwise.
        .padding(.bottom, twoLines && !customOpen ? Theme.Space.xs : 0)
        .overlay(alignment: .top) {
            if dropTarget || preview.dropTarget == repo.fullName { Capsule().fill(Theme.accent).frame(height: 2).offset(y: -1) }
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
        .accessibilityAction(named: "Stop watching") { store.stopWatching(repo) }
    }

    /// The first line of a row with a second one: a pop-up's height and a hairline of margin.
    private static let firstLine: CGFloat = Theme.Metrics.button + 2

    /// `owner/` quiet, the name in bold; the middle gives way first.
    private var name: some View {
        (Text("\(repo.owner)/").foregroundStyle(Theme.tertiary) + Text(repo.name).fontWeight(.semibold).foregroundStyle(Theme.text))
            .font(Theme.Typography.body)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: Preset

    /// Every row's pop-up is as wide as the longest title, so the pop-ups, the CI switches and the names line up as
    /// columns, and a name has the same room whichever preset its row is on.
    private var preset: some View {
        PopUp(label: "Notify me about, \(repo.fullName)", value: shown.title, room: RepoPreset.allCases.map(\.title)) {
            ForEach(RepoPreset.allCases, id: \.self) { choice in
                Toggle(choice.title, isOn: Binding(get: { shown == choice }, set: { _ in choose(choice) }))
            }
        }
    }

    private func choose(_ choice: RepoPreset) {
        withAnimation(Theme.Motion.move.resolved(reduce: reduceMotion)) {
            // Custom only picks Custom (it shows its checkboxes); closing them is the disclosure's job.
            if choice == .custom {
                customOpen = true
            } else {
                customOpen = false
                store.changePreset(choice, on: repo)
            }
        }
    }

    // MARK: Custom

    /// What Custom amounts to, which is also the disclosure: it opens and closes the checkboxes under it.
    private var summaryLine: some View {
        Button { withAnimation(Theme.Motion.move.resolved(reduce: reduceMotion)) { customOpen.toggle() } } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(RepoPreset.summary(repo)).font(Theme.Typography.meta).foregroundStyle(Theme.secondary).lineLimit(1)
                Image(systemName: customOpen ? "chevron.down" : "chevron.right").font(Theme.Typography.glyph(9, .bold))
                    .foregroundStyle(Theme.tertiary).accessibilityHidden(true)
            }
            .frame(height: Self.line)
            // 24pt to hit, without taking the room.
            .contentShape(Rectangle().inset(by: -(Theme.Metrics.iconButton - Self.line) / 2))
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.small)
        .accessibilityLabel(RepoPreset.summary(repo))
        .accessibilityValue(customOpen ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows what Custom follows")
    }

    private static let line: CGFloat = 14

    private var custom: some View {
        let hasComments = !repo.events.isDisjoint(with: RepoPreset.comments)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.checkboxes, id: \.kind) { box in
                Toggle(box.title, isOn: binding(box.kind)).toggleStyle(CheckboxStyle())
            }
            Toggle("Every comment, not only the ones for me", isOn: Binding(get: { repo.allComments }, set: { _ in store.toggleAllComments(repo) }))
                .toggleStyle(CheckboxStyle())
                .disabled(!hasComments)
            Text(hasComments
                 ? "Otherwise only comments on your issues and pull requests, mentioning you, or after you joined the conversation."
                 : "Turn on a kind of comment above first.")
                .font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // Under the label, not the box: 14 + 8.
                .padding(.leading, 22)
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.text)
        .padding(.leading, Theme.Metrics.contentEdge)
        .padding(.top, Theme.Space.xs)
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

    /// A line of its own under the name: the sentence truncates, Retry keeps its place at the end.
    private func failureLine(_ message: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.circle.fill").font(Theme.Typography.glyph(11, .regular)).foregroundStyle(Theme.red)
                .accessibilityHidden(true)
            Text(RepoFailure.sync(message, of: repo.fullName)).font(Theme.Typography.meta).foregroundStyle(Theme.red).lineLimit(1)
                .help(message)
            Spacer(minLength: Theme.Space.md)
            Button(action: store.refreshNow) {
                Text("Retry").font(Theme.Typography.control).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, Theme.Space.xs)
                    .frame(height: Self.line)
                    // 24pt to hit, and a ring that stays within the line, without taking the room.
                    .contentShape(Rectangle().inset(by: -(Theme.Metrics.iconButton - Self.line) / 2))
            }
            .buttonStyle(.plain)
            .focused($retryFocused)
            .focusRing(Theme.Radius.small, isFocused: retryFocused || preview.retryFocused == repo.fullName)
        }
        .frame(height: Self.line)
        .accessibilityElement(children: .contain)
        .accessibilityValue(message)
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
        Button("Stop watching", systemImage: "eye.slash", role: .destructive) { store.stopWatching(repo) }
    }

    private func move(_ step: Int) {
        withAnimation(Theme.Motion.move.resolved(reduce: reduceMotion)) { store.moveRepo(repo.fullName, by: step) }
    }
}
