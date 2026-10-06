import AppKit
import SwiftUI

// CI: its cell in the bar, header, and one line per state.

/// A repo in CI's lines: its name (and how many checks fail), opening its latest run.
struct RepoChip: View {
    let repo: RepoConfig
    let status: CIStatus?
    let state: CIState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(repo.name).font(Theme.Typography.control).foregroundStyle(Theme.text)
                if state == .failure, let n = status?.failing.count, n > 0 {
                    Text(plural(n, "check")).font(Theme.Typography.meta).foregroundStyle(Theme.red)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
        }
        .buttonStyle(HoverFillButtonStyle(shape: Capsule(), rest: Theme.Fill.hover, hover: Theme.Fill.selected))
        .accessibilityLabel("\(repo.name), \(state == .none ? "no runs" : state.label)")
        .accessibilityHint("Opens its latest checks")
        .tip(repo.fullName, detail)
    }

    private var detail: String {
        var lines = [status?.branch ?? repo.defaultBranch ?? "default branch"]
        if let title = status?.title, !title.isEmpty { lines[0] += " · " + title }
        if state == .failure, let failing = status?.failing, !failing.isEmpty {
            lines.append("Failing: " + failing.joined(separator: ", "))
        }
        lines.append("Click to open its checks")
        return lines.joined(separator: "\n")
    }
}

extension LookoutHub {
    // MARK: CI

    /// One order for CI everywhere: what needs attention first.
    static let ciOrder: [CIState] = [.failure, .pending, .success]
    /// `ciOrder`, then the repos without a run: for the lines that list repos (the bar's counts keep `ciOrder`).
    /// Repo chips on one CI line before the rest fold into "+N".
    static let ciChipLimit = 4
    static let ciLineOrder: [CIState] = ciOrder + [.none]

    /// The repos in a CI state; `.none` is the ones with no run (nothing known yet, or no checks).
    func ciRepos(listedIn state: CIState) -> [RepoConfig] {
        Self.ciRepos(listedIn: state, in: store.ciRepos, status: store.ci)
    }

    /// Pure form of `ciRepos(listedIn:)`: a repo with no status at all, or one stored as `CIState.none`, is "no runs".
    static func ciRepos(listedIn state: CIState, in repos: [RepoConfig], status: [String: CIStatus]) -> [RepoConfig] {
        repos.filter { (status[$0.fullName]?.state ?? CIState.none) == state }
    }

    /// CI's icon in the bar, tinted by the worst state; hovering lists the repos in each.
    var ciCell: some View {
        let worst = store.worstCI
        let counts = Self.ciOrder.compactMap { state -> String? in
            let n = ciRepos(listedIn: state).count
            return n == 0 ? nil : "\(n) \(state.label)"
        }
        return Image(systemName: worst == .failure ? "xmark.seal.fill" : "checkmark.seal.fill")
            .font(Theme.Typography.glyph(15))
            .foregroundStyle(worst.color)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: Theme.Metrics.line, height: Theme.Metrics.line)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("CI: \(worst == CIState.none ? "no runs" : worst.label)")
            .accessibilityValue(counts.joined(separator: ", "))
    }

    /// CI's section header: "CI" and how it's going, worst first.
    var ciHeader: some View {
        // Shrunk (another section focused), its lines are gone: every state's count, in its colour.
        let status: [(String, Color)] = shrunk(.ci)
            ? Self.ciOrder.compactMap { state in
                let n = ciRepos(listedIn: state).count
                return n == 0 ? nil : ("\(n) \(state.label)", state.color)
            } + (ciRepos(listedIn: .none).isEmpty ? [] : [("\(ciRepos(listedIn: .none).count) no runs", CIState.none.color)])
            : ciStatus.map { [$0] } ?? []
        return sectionHeader("CI", status: status) { if showsDetail { focusButton(.ci) } }
    }

    /// "2 failing" in red; "1 running" while nothing fails but something runs; "all passing" once everything has.
    var ciStatus: (String, Color)? {
        let failing = ciRepos(listedIn: .failure).count
        let running = ciRepos(listedIn: .pending).count
        let passing = ciRepos(listedIn: .success).count
        if failing > 0 { return ("\(failing) failing", Theme.red) }
        if running > 0 { return ("\(running) running", Theme.secondary) }
        // "All" only when every repo shown has passed; some without a run yet make it a count.
        if passing > 0 { return (ciRepos(listedIn: CIState.none).isEmpty ? "all passing" : "\(passing) passing", Theme.tertiary) }
        return store.ciRepos.isEmpty ? nil : ("no runs", Theme.tertiary)
    }

    /// The number of repos in a CI state, beside its line; hovering lists them.
    func ciCount(_ state: CIState) -> some View {
        let n = ciRepos(listedIn: state).count
        return Text("\(n)")
            .font(Theme.Typography.numeral)
            .foregroundStyle(n == 0 ? Theme.tertiary : state.color)
            .contentTransition(.numericText(value: Double(n)))
            .frame(width: 32, height: Theme.Metrics.line)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(n) \(state.label)")
    }

    /// The repos in a CI state, as chips that open their checks.
    /// `compact`: along the top and bottom, where lines don't have to match the bar's cells.
    func ciLine(_ state: CIState, compact: Bool = false) -> some View {
        let repos = ciRepos(listedIn: state)
        // Repos without a run only get a line when there are some.
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(state == CIState.none ? "No runs" : state.title)
                .font(Theme.Typography.numeral)
                .foregroundStyle(repos.isEmpty ? Theme.tertiary : state.color)
                .frame(width: 52, alignment: .leading)
            if repos.isEmpty {
                Text("—").font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
            } else {
                // A few chips, then "+N": a line never grows with the number of repos (it'd push the hub off the screen).
                FlowLayout(spacing: 5) {
                    ForEach(repos.prefix(Self.ciChipLimit), id: \.fullName) { repo in
                        RepoChip(repo: repo, status: store.ci[repo.fullName], state: state) { store.openChecks(repo) }
                    }
                    if repos.count > Self.ciChipLimit {
                        let rest = repos.dropFirst(Self.ciChipLimit)
                        Text("+\(rest.count)").font(Theme.Typography.control).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8).frame(height: 22)
                            .accessibilityLabel("\(rest.count) more")
                            .tip("\(rest.count) more", rest.map(\.fullName).joined(separator: "\n"))
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, compact ? 1 : Theme.Space.xs)
        .frame(maxWidth: .infinity, minHeight: compact ? 24 : Theme.Metrics.line, alignment: .leading)
    }

    var ciColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.ciRepos.isEmpty {
                linkRow("No CI configured", action: "Choose repositories") { hub.go(.repos) }
            } else {
                // The state's name starts each line, coloured; its count is in the strip above.
                ForEach(Self.ciLineOrder, id: \.self) { state in
                    if state != CIState.none || !ciRepos(listedIn: .none).isEmpty { ciLine(state, compact: true) }
                }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if ciHeight != $0 { ciHeight = $0 } }
        .opacity(searching ? 0.4 : 1)
    }
}
