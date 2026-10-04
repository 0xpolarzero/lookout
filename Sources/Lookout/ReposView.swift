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
    @State private var hover = false

    var body: some View {
        let status = store.ci[repo.fullName]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.owner).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Text(repo.name).font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                if repo.events.contains(.ciMain) {
                    Button {
                        if let url = status?.url { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 6) {
                            CIDot(state: status?.state ?? .none, size: 7)
                            Text("\(status?.branch ?? repo.defaultBranch ?? "main") \(status?.state.label ?? "…")")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(status?.failing.isEmpty == false ? "Failing: " + status!.failing.joined(separator: ", ") : "Open latest commit")
                }
                Menu {
                    Button("Open on GitHub") { NSWorkspace.shared.open(repo.url) }
                    Button("Open Actions") { NSWorkspace.shared.open(repo.url.appendingPathComponent("actions")) }
                    Divider()
                    Button("Stop watching", role: .destructive) { store.removeRepo(repo) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.secondary)
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if let failing = status?.failing, status?.state == .failure, !failing.isEmpty {
                Text("✕ " + failing.prefix(3).joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.red.opacity(0.9))
                    .lineLimit(1)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(EventKind.repoToggles) { kind in
                    EventToggle(kind: kind, isOn: repo.events.contains(kind)) { store.toggle(kind, on: repo) }
                }
            }
            allCommentsRow
            if let error = store.repoErrors[repo.fullName] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.amber)
            }
        }
        .card()
    }
}

extension RepoCard {
    private var allCommentsRow: some View {
        let hasComments = !repo.events.isDisjoint(with: [.issueComment, .prComment, .reviewComment])
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("All comments").font(.system(size: 12.5, weight: .medium))
                Text(repo.allComments ? "Every comment in this repo"
                                      : "Only on your issues & PRs, @mentions, and replies after you")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { repo.allComments }, set: { _ in store.toggleAllComments(repo) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 2)
        .opacity(hasComments ? 1 : 0.4)
        .disabled(!hasComments)
    }
}

private struct EventToggle: View {
    let kind: EventKind
    let isOn: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isOn ? kind.color : Theme.tertiary)
                    .frame(width: 14)
                Text(kind.toggleLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isOn ? Theme.text : Theme.tertiary)
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(kind.color)
                    .opacity(isOn ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn ? kind.color.opacity(0.12) : Color.white.opacity(hover ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOn ? kind.color.opacity(0.28) : Theme.stroke)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}
