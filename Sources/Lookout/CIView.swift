import SwiftUI

/// CI on the default branch of every repo shown on the pill, worst first.
struct CIView: View {
    let store: Store
    @Bindable var ui: UIState

    private let order: [CIState] = [.failure, .pending, .success, .none]

    var body: some View {
        let repos = store.ciRepos
        let hidden = store.repos.count - repos.count
        if repos.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.tertiary)
                Text("No CI shown").font(.system(size: 14, weight: .semibold))
                Text("Turn on the CI badge of a repository to follow its default branch here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                Button("Choose repositories") { ui.tab = .repos }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    ForEach(order, id: \.self) { state in
                        let group = store.ciRepos(in: state) + (state == .none ? repos.filter { store.ci[$0.fullName] == nil } : [])
                        if !group.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(state.title.uppercased())  \(group.count)")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(Theme.tertiary)
                                    .padding(.leading, 4)
                                ForEach(group) { repo in
                                    CIRow(repo: repo, status: store.ci[repo.fullName])
                                }
                            }
                        }
                    }
                    if hidden > 0 {
                        Button { ui.tab = .repos } label: {
                            Text("\(hidden) repo\(hidden == 1 ? "" : "s") with CI hidden · manage in Repositories")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 4)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.never)
        }
    }

    private var summary: some View {
        HStack(spacing: 6) {
            ForEach([CIState.success, .failure, .pending], id: \.self) { state in
                let count = store.ciRepos(in: state).count
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        CIDot(state: count == 0 ? .none : state, size: 7)
                        Text(state.title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Text("\(count)")
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(count == 0 ? Theme.tertiary : Theme.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(count > 0 && state == .failure ? Theme.red.opacity(0.35) : Theme.stroke))
            }
        }
    }
}

private struct CIRow: View {
    let repo: RepoConfig
    let status: CIStatus?
    @State private var hover = false

    var body: some View {
        let state = status?.state ?? .none
        Button {
            NSWorkspace.shared.open(status?.url ?? repo.url.appendingPathComponent("actions"))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(state.color)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        (Text("\(repo.owner)/").foregroundStyle(Theme.tertiary)
                            + Text(repo.name).foregroundStyle(Theme.text).fontWeight(.semibold))
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if let date = status?.updatedAt ?? status?.checkedAt {
                            Text(shortAgo(date)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                        }
                    }
                    HStack(spacing: 5) {
                        Label(status?.branch ?? repo.defaultBranch ?? "main", systemImage: "arrow.triangle.branch")
                        if let sha = status?.sha {
                            Text(sha.prefix(7)).font(.system(size: 10.5, design: .monospaced))
                        }
                        if let title = status?.title {
                            Text("·")
                            Text(title).lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .labelStyle(CompactLabel())
                    if state == .failure, let failing = status?.failing, !failing.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(failing, id: \.self) { name in
                                Label(name, systemImage: "xmark")
                                    .labelStyle(CompactLabel())
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.red)
                                    .padding(.horizontal, 7)
                                    .frame(height: 20)
                                    .background(Capsule().fill(Theme.red.opacity(0.12)))
                            }
                        }
                        .padding(.top, 3)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.hover : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open latest commit checks") { if let url = status?.url { NSWorkspace.shared.open(url) } }
            Button("Open Actions") { NSWorkspace.shared.open(repo.url.appendingPathComponent("actions")) }
        }
    }
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}
