import SwiftUI

struct ReposView: View {
    let store: Store
    @State private var input = ""
    @State private var error: String?
    @State private var adding = false
    @FocusState private var fieldFocused: Bool
    /// Keeps the suggestions up while the pointer is on them: clicking one ends the editing before the click lands.
    @State private var overList = false

    private var matches: [String] {
        let q = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(store.suggestions.prefix(5)) }
        return Array(store.suggestions.filter { $0.lowercased().contains(q) }.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                addField
                if !store.repos.isEmpty { legend }
                ForEach(store.repos) { repo in
                    RepoCard(repo: repo, store: store)
                }
                if store.repos.isEmpty {
                    Text("Watch your own repos or any public one you contribute to. You'll only hear about the events you pick.")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Theme.Space.xs)
                        .padding(.top, Theme.Space.xs)
                }
            }
            .padding(Theme.Space.lg)
        }
        .scrollIndicators(.never)
        .task { await store.loadSuggestions() }
    }

    /// Column header over the toggles of every card, in the same order and spacing as the badges.
    private var legend: some View {
        HStack(spacing: 10) {
            Eyebrow("Watching", count: store.repos.count)
            Spacer(minLength: Theme.Space.sm)
            RepoToggleColumns.legend
            Color.clear.frame(width: 20, height: 1)
        }
        .foregroundStyle(Theme.tertiary)
        .padding(.leading, Theme.Space.lg)
        .padding(.trailing, Theme.Space.sm)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary).font(Theme.Typography.control)
                    TextField("owner/repo or GitHub URL", text: $input)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Repository to add")
                        .focused($fieldFocused)
                        .onSubmit { add(input) }
                    if adding { ProgressView().controlSize(.mini) }
                }
                .fieldStyle()
                Button { add(input) } label: {
                    Image(systemName: "plus")
                        .font(Theme.Typography.glyph(13, .bold))
                        .foregroundStyle(Theme.onTint)
                        .frame(width: Theme.Metrics.field, height: Theme.Metrics.field)
                }
                .buttonStyle(HoverFillButtonStyle(rest: Theme.amber, hover: Theme.amber.opacity(0.85), pressed: Theme.amber.opacity(0.7)))
                .disabled(input.isEmpty || adding)
                .accessibilityLabel("Watch repository")
                .tip("Watch repository", "Add the repo typed on the left")
            }
            if let error {
                Text(error).font(Theme.Typography.meta).foregroundStyle(Theme.red).padding(.horizontal, Theme.Space.xs)
            }
            if (fieldFocused || overList) && !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches, id: \.self) { name in
                        SuggestionRow(name: name) { add(name) }
                    }
                }
                .padding(Theme.Space.xs)
                .background(Theme.Radius.shape(Theme.Radius.lg).fill(Theme.raised))
                .overlay(Theme.Radius.shape(Theme.Radius.lg).strokeBorder(Theme.stroke))
                .onHover { overList = $0 }
            }
        }
        .padding(.bottom, Theme.Space.xs)
    }

    private func add(_ name: String) {
        guard !name.isEmpty, !adding else { return }
        adding = true
        error = nil
        let draft = input
        Task {
            let err = await store.addRepo(name)
            adding = false
            error = Self.said(err)
            if err == nil {
                // The field stays editable while the add runs: whatever was typed meanwhile is the next one, and stays.
                input = Self.field(afterAdding: draft, typed: input)
                if input.isEmpty { fieldFocused = false }
                overList = false
            }
        }
    }

    /// The sentence that appears under the field is said too, once (the list it joins is not what VoiceOver is on).
    static func said(_ failure: String?) -> String? {
        if let failure { Announce.say(failure) }
        return failure
    }

    /// What the field holds once the add of `draft` went through: emptied, unless something else was typed meanwhile.
    static func field(afterAdding draft: String, typed: String) -> String { typed == draft ? "" : typed }
}

private struct SuggestionRow: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SuggestionLabel(name: name)
        }
        .buttonStyle(HoverFillButtonStyle(shape: Theme.Radius.shape(Theme.Radius.sm)))
        .accessibilityLabel("Watch \(name)")
    }
}

private struct SuggestionLabel: View {
    let name: String
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "book.closed").font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
                Text(name.split(separator: "/").first.map { "\($0)/" } ?? "").foregroundStyle(Theme.tertiary)
                    + Text(name.split(separator: "/").last.map(String.init) ?? "").foregroundStyle(Theme.text)
                Spacer()
                if hover { Image(systemName: "plus").font(Theme.Typography.glyph(11)).foregroundStyle(Theme.secondary) }
            }
            .font(Theme.Typography.body)
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 28)
    }
}

/// Shared geometry so the legend lines up with the badges.
private enum RepoToggleColumns {
    static let spacing: CGFloat = 3
    static var kinds: [EventKind] { EventKind.repoToggles.filter { $0 != .ciMain } }

    /// Group captions with a bracket underneath, spanning the badge columns they describe:
    /// issues (opened, comments), pull requests (opened, comments, review comments), all-comments ("All") and CI.
    static var legend: some View {
        HStack(spacing: 3) {
            group("Issues", columns: 2)
            group("Pull requests", columns: 3)
            Color.clear.frame(width: 5, height: 1)
            group("All", columns: 1)
            group("CI", columns: 1)
        }
    }

    private static func group(_ text: String, columns: Int) -> some View {
        let width = CGFloat(columns) * 24 + CGFloat(columns - 1) * spacing
        return VStack(spacing: 2) {
            Text(text).font(Theme.Typography.glyph(9, .medium)).lineLimit(1).fixedSize()
            Hairline()
        }
        .frame(width: width)
    }
}

struct RepoCard: View {
    let repo: RepoConfig
    let store: Store
    @State private var dropTarget = false
    @State private var hover = false
    @FocusState private var menuFocused: Bool
    @Environment(\.previewTip) private var previewTip
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.owner).font(Theme.Typography.caption).foregroundStyle(Theme.tertiary)
                Text(repo.name).font(Theme.Typography.title)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.sm)
            if let error = store.repoErrors[repo.fullName] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.amber)
                    .frame(width: 18, height: 24)
                    .accessibilityLabel("Sync failed: \(error)")
                    .tip("Sync failed", error)
            }
            HStack(spacing: RepoToggleColumns.spacing) {
                ForEach(RepoToggleColumns.kinds) { kind in
                    badge(kind)
                }
                Hairline(axis: .vertical).frame(height: 14).padding(.horizontal, 2)
                allCommentsBadge
                ciBadge
            }
            menu
        }
        .padding(.leading, Theme.Space.lg)
        .padding(.trailing, Theme.Space.sm)
        .padding(.vertical, Theme.Space.md)
        .background(Theme.Radius.shape(Theme.Radius.lg).fill(hover ? Theme.Fill.hover : Theme.raised))
        .motion(Theme.Motion.hover, value: hover)
        .overlay(
            Theme.Radius.shape(Theme.Radius.lg)
                .strokeBorder(dropTarget ? Theme.accent : Theme.stroke, lineWidth: dropTarget ? 1.5 : 1)
        )
        .onHover { hover = $0 }
        // Screenshots target one badge as "owner/repo|Tooltip title"; only that card shows it.
        .environment(\.previewTip, previewTip.flatMap { spec in
            spec.hasPrefix(repo.fullName + "|") ? String(spec.dropFirst(repo.fullName.count + 1)) : nil
        })
        .draggable(repo.fullName) {
            Text(repo.fullName)
                .font(Theme.Typography.heading)
                .padding(.horizontal, 10)
                .frame(height: Theme.Metrics.chip)
                .background(Capsule().fill(Theme.bg))
                .foregroundStyle(Theme.text)
        }
        .dropDestination(for: String.self) { names, _ in
            guard let name = names.first else { return false }
            withAnimation(Theme.Motion.spring.resolved(reduce: reduceMotion)) { store.moveRepo(name, onto: repo.fullName) }
            return true
        } isTargeted: { dropTarget = $0 }
    }

    // MARK: Badges

    private func badge(_ kind: EventKind) -> some View {
        let on = repo.events.contains(kind)
        let filtered = kind != .issueOpened && kind != .prOpened && !repo.allComments
        let detail = filtered ? "Only on your threads, @mentions and replies to you" : kind.tipDetail
        return BadgeButton(symbol: kind.symbol, color: kind.color, on: on, label: kind.toggleLabel,
                           tip: detail + (on ? "" : "\nOff · click to turn on")) { store.toggle(kind, on: repo) }
    }

    private var allCommentsBadge: some View {
        let hasComments = !repo.events.isDisjoint(with: [.issueComment, .prComment, .reviewComment])
        return BadgeButton(symbol: "bubble.left.and.bubble.right.fill", color: Theme.accent, on: repo.allComments,
                           label: "All comments", tipTitle: repo.allComments ? "All comments" : "Comments for you",
                           tip: repo.allComments ? "Every comment in this repo" : "Click to get every comment, not only the ones for you") {
            store.toggleAllComments(repo)
        }
        .opacity(hasComments ? 1 : 0.35)
        .disabled(!hasComments)
    }

    private var ciBadge: some View {
        let on = repo.events.contains(.ciMain)
        let status = store.ci[repo.fullName]
        let state = status?.state ?? .none
        let symbol = on ? state.symbol : "seal"
        let branch = status?.branch ?? repo.defaultBranch ?? "default branch"
        var detail = on ? "\(branch) \(state.label)" : "Hidden from the bar · click to show"
        if on, state == .failure, let failing = status?.failing, !failing.isEmpty {
            detail += "\n" + failing.prefix(4).joined(separator: "\n")
        }
        return BadgeButton(symbol: symbol, color: state == .none ? Theme.secondary : state.color, on: on, label: "CI",
                           value: on ? "\(state.label), shown on the bar" : "Hidden from the bar", tip: detail) {
            store.toggle(.ciMain, on: repo)
        }
    }

    private var menu: some View {
        Menu {
            Button("Open on GitHub") { NSWorkspace.shared.open(repo.url) }
            Button("Open Actions") { NSWorkspace.shared.open(repo.url.appendingPathComponent("actions")) }
            if store.ci[repo.fullName]?.url != nil {
                Button("Open latest commit checks") { store.openChecks(repo) }
            }
            Divider()
            Button("Stop watching", role: .destructive) { store.removeRepo(repo) }
        } label: {
            Image(systemName: "ellipsis").font(Theme.Typography.glyph(11, .bold)).foregroundStyle(Theme.tertiary)
                .frame(width: 20, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(repo.fullName)")
        .focused($menuFocused)
        .tip("More", "Open on GitHub, or stop watching", focused: menuFocused)
    }
}

private struct BadgeButton: View {
    let symbol: String
    let color: Color
    let on: Bool
    var label = ""
    /// What VoiceOver reads as the state; defaults to On/Off.
    var value: String? = nil
    /// Its tooltip: the title (the label, unless another says more) and what it adds.
    var tipTitle: String? = nil
    let tip: String
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) { BadgeLabel(symbol: symbol, color: color, on: on) }
            .buttonStyle(HoverFillButtonStyle(
                shape: Theme.Radius.shape(Theme.Radius.sm),
                rest: on ? color.opacity(0.15) : Theme.Fill.rest,
                hover: on ? color.opacity(0.24) : Theme.Fill.hover,
                pressed: on ? color.opacity(0.32) : Theme.Fill.selected))
            .accessibilityLabel(label)
            .accessibilityValue(value ?? (on ? "On" : "Off"))
            .focused($focused)
            .tip(tipTitle ?? label, tip, focused: focused)
    }
}

private struct BadgeLabel: View {
    let symbol: String
    let color: Color
    let on: Bool
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        Image(systemName: symbol)
            .font(Theme.Typography.glyph(10.5))
            .foregroundStyle(on ? color : Theme.tertiary.opacity(hover ? 1 : 0.7))
            .frame(width: 24, height: 24)
            .overlay(Theme.Radius.shape(Theme.Radius.sm).strokeBorder(on ? color.opacity(0.25) : Theme.stroke))
    }
}
