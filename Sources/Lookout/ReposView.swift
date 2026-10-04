import SwiftUI

struct ReposView: View {
    let store: Store
    @State private var input = ""
    @State private var error: String?
    @State private var adding = false
    @FocusState private var fieldFocused: Bool

    private var matches: [String] {
        let q = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(store.suggestions.prefix(5)) }
        return Array(store.suggestions.filter { $0.lowercased().contains(q) }.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                addField
                ForEach(store.repos) { repo in
                    RepoCard(repo: repo, store: store)
                }
                if store.repos.isEmpty {
                    Text("Watch your own repos or any public one you contribute to. You'll only hear about the events you pick.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .task { await store.loadSuggestions() }
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary).font(.system(size: 12))
                    TextField("owner/repo or GitHub URL", text: $input)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { add(input) }
                    if adding { ProgressView().controlSize(.mini) }
                }
                .fieldStyle()
                Button { add(input) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.amber))
                }
                .buttonStyle(.plain)
                .disabled(input.isEmpty || adding)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.red).padding(.horizontal, 4)
            }
            if (fieldFocused || !input.isEmpty) && !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches, id: \.self) { name in
                        SuggestionRow(name: name) { add(name) }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
            }
        }
        .padding(.bottom, 4)
    }

    private func add(_ name: String) {
        guard !name.isEmpty, !adding else { return }
        adding = true
        error = nil
        Task {
            let err = await store.addRepo(name)
            adding = false
            error = err
            if err == nil { input = "" }
        }
    }
}

private struct SuggestionRow: View {
    let name: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Text(name.split(separator: "/").first.map { "\($0)/" } ?? "").foregroundStyle(Theme.tertiary)
                    + Text(name.split(separator: "/").last.map(String.init) ?? "").foregroundStyle(Theme.text)
                Spacer()
                if hover { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary) }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct RepoCard: View {
    let repo: RepoConfig
    let store: Store
    @State private var dropTarget = false
    @State private var hover = false
    @Environment(\.previewTip) private var previewTip

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.owner).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                Text(repo.name).font(.system(size: 13, weight: .semibold))
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
            Spacer(minLength: 6)
            if let error = store.repoErrors[repo.fullName] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 18, height: 24)
                    .tip("Sync failed", error)
            }
            HStack(spacing: 3) {
                ForEach(EventKind.repoToggles.filter { $0 != .ciMain }) { kind in
                    badge(kind)
                }
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 14).padding(.horizontal, 2)
                allCommentsBadge
                ciBadge
            }
            menu
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.hover : Theme.raised))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropTarget ? Theme.accent : Theme.stroke, lineWidth: dropTarget ? 1.5 : 1)
        )
        .onHover { hover = $0 }
        // Screenshots target one badge as "owner/repo|Tooltip title"; only that card shows it.
        .environment(\.previewTip, previewTip.flatMap { spec in
            spec.hasPrefix(repo.fullName + "|") ? String(spec.dropFirst(repo.fullName.count + 1)) : nil
        })
        .draggable(repo.fullName) {
            Text(repo.fullName)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Theme.bg))
                .foregroundStyle(Theme.text)
        }
        .dropDestination(for: String.self) { names, _ in
            guard let name = names.first else { return false }
            withAnimation(.spring(duration: 0.25)) { store.moveRepo(name, onto: repo.fullName) }
            return true
        } isTargeted: { dropTarget = $0 }
    }

    // MARK: Badges

    private func badge(_ kind: EventKind) -> some View {
        let on = repo.events.contains(kind)
        let filtered = kind != .issueOpened && kind != .prOpened && !repo.allComments
        let detail = filtered ? "Only on your threads, @mentions and replies to you" : kind.tipDetail
        return BadgeButton(symbol: kind.symbol, color: kind.color, on: on) { store.toggle(kind, on: repo) }
            .tip(kind.toggleLabel, detail + (on ? "" : "\nOff · click to turn on"))
    }

    private var allCommentsBadge: some View {
        let hasComments = !repo.events.isDisjoint(with: [.issueComment, .prComment, .reviewComment])
        return BadgeButton(symbol: "bubble.left.and.bubble.right.fill", color: Theme.accent, on: repo.allComments) {
            store.toggleAllComments(repo)
        }
        .opacity(hasComments ? 1 : 0.35)
        .disabled(!hasComments)
        .tip(repo.allComments ? "All comments" : "Comments for you",
             repo.allComments ? "Every comment in this repo" : "Click to get every comment, not only the ones for you")
    }

    private var ciBadge: some View {
        let on = repo.events.contains(.ciMain)
        let status = store.ci[repo.fullName]
        let state = status?.state ?? .none
        let symbol = on ? state.symbol : "seal"
        let branch = status?.branch ?? repo.defaultBranch ?? "main"
        var detail = on ? "\(branch) \(state.label)" : "Hidden from the pill · click to show"
        if on, state == .failure, let failing = status?.failing, !failing.isEmpty {
            detail += "\n" + failing.prefix(4).joined(separator: "\n")
        }
        return BadgeButton(symbol: symbol, color: state == .none ? Theme.secondary : state.color, on: on) {
            store.toggle(.ciMain, on: repo)
        }
        .tip("CI", detail)
    }

    private var menu: some View {
        Menu {
            Button("Open on GitHub") { NSWorkspace.shared.open(repo.url) }
            Button("Open Actions") { NSWorkspace.shared.open(repo.url.appendingPathComponent("actions")) }
            if let url = store.ci[repo.fullName]?.url {
                Button("Open latest commit checks") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Stop watching", role: .destructive) { store.removeRepo(repo) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.tertiary)
                .frame(width: 20, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct BadgeButton: View {
    let symbol: String
    let color: Color
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? color : Theme.tertiary.opacity(hover ? 1 : 0.7))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? color.opacity(hover ? 0.24 : 0.15) : Color.white.opacity(hover ? 0.07 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(on ? color.opacity(0.25) : Theme.stroke)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: on)
    }
}
