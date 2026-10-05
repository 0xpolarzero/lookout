import AppKit
import SwiftUI

// Prototype: the pill as one bar stuck to its edge, which expands into a peek at everything on hover.
// Rendered with `--bar <dir>`.

/// What the bar shows when hovered: a short version of each section, inbox, CI and agents.
struct BarPeek: View {
    let store: Store
    let ui: UIState

    private let column: CGFloat = 290

    var body: some View {
        let layout = ui.edge.isHorizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            inbox.frame(width: column)
            divider
            ci.frame(width: column)
            if store.agents.enabled {
                divider
                agents.frame(width: column)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke)
            .frame(width: ui.edge.isHorizontal ? 1 : nil, height: ui.edge.isHorizontal ? nil : 1)
            .padding(ui.edge.isHorizontal ? .vertical : .horizontal, 12)
    }

    private func section<Content: View>(_ symbol: String, _ title: String, _ tint: Color, _ detail: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            content()
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var inbox: some View {
        let items = store.list(.needsYou)
        let bots = store.unreadCount(.bots)
        return section("tray.fill", "Needs you", Theme.amber, bots > 0 ? "\(bots) from bots" : "") {
            ForEach(items.prefix(4)) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(item.state == .unread ? Theme.amber : Color.white.opacity(0.3)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 12.5, weight: item.state == .unread ? .semibold : .regular))
                            .foregroundStyle(Theme.text).lineLimit(1)
                        Text("\(item.repo.split(separator: "/").last ?? "")#\(item.number) · \(age(item.createdAt))")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            if items.count > 4 { more("\(items.count - 4) more") }
        }
    }

    private var ci: some View {
        let order: [CIState] = [.failure, .pending, .success, .none]
        let repos = store.ciRepos.sorted {
            order.firstIndex(of: store.ci[$0.fullName]?.state ?? .none)! < order.firstIndex(of: store.ci[$1.fullName]?.state ?? .none)!
        }
        let failing = store.ciRepos(in: .failure).count
        return section("checkmark.seal.fill", "CI", failing > 0 ? Theme.red : Theme.green,
                       failing > 0 ? "\(failing) failing" : "all passing") {
            ForEach(repos.prefix(5), id: \.fullName) { repo in
                let state = store.ci[repo.fullName]?.state ?? .none
                HStack(spacing: 9) {
                    CIDot(state: state, size: 7).frame(width: 18)
                    Text(repo.name).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(store.ci[repo.fullName]?.branch ?? "main").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 0)
                    Text(state.label).font(.system(size: 11, weight: .medium)).foregroundStyle(state.color)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
            }
            if repos.count > 5 { more("\(repos.count - 5) more") }
        }
    }

    private var agents: some View {
        let rows = store.agentRows
        let counts = store.agentCounts
        return section("asterisk", "Agents", Theme.claude, counts.blocked > 0 ? "\(counts.blocked) waiting" : "") {
            ForEach(Array((rows.kept + rows.pending).prefix(4).enumerated()), id: \.element.id) { i, row in
                DrawerRow(row: row, store: store, ui: ui, number: i, twoLines: true)
            }
            if rows.kept.count + rows.pending.count > 4 { more("\(rows.kept.count + rows.pending.count - 4) more") }
        }
    }

    private func more(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 8).padding(.top, 4)
    }

    private func age(_ date: Date) -> String {
        let m = Int(-date.timeIntervalSinceNow / 60)
        return m < 60 ? "\(max(m, 1))m" : m < 1440 ? "\(m / 60)h" : "\(m / 1440)d"
    }
}

/// The bar and its peek in one shape, the peek on the side away from the screen edge.
struct ExpandedBar: View {
    let store: Store
    let ui: UIState

    var body: some View {
        let bar = PillView(store: store, ui: ui, actions: PillActions(toggle: { _ in }), merged: true, chrome: false)
        let peek = BarPeek(store: store, ui: ui)
        let line = Rectangle().fill(Theme.stroke)
        Group {
            switch ui.edge {
            case .right: HStack(alignment: .top, spacing: 0) { peek; line.frame(width: 1); bar }
            case .left: HStack(alignment: .top, spacing: 0) { bar; line.frame(width: 1); peek }
            case .top: VStack(spacing: 0) { bar; line.frame(height: 1); peek }
            case .bottom: VStack(spacing: 0) { peek; line.frame(height: 1); bar }
            }
        }
        .fixedSize()
        .background(PillView.barShape(ui.edge, radius: 22).fill(Theme.bg))
        .overlay(PillView.barShape(ui.edge, radius: 22).strokeBorder(Theme.stroke))
    }
}

private struct EdgeScene<Pill: View>: View {
    let edge: DockEdge
    let pill: Pill

    var body: some View {
        let wallpaper = LinearGradient(colors: [Color(red: 0.23, green: 0.30, blue: 0.45), Color(red: 0.55, green: 0.44, blue: 0.55)],
                                       startPoint: .top, endPoint: .bottom)
        let bezel = Rectangle().fill(Color.black)
        switch edge {
        case .right:
            HStack(alignment: .top, spacing: 0) { Spacer(minLength: 40); pill; bezel.frame(width: 8) }
                .padding(.vertical, 30).background(wallpaper)
        case .left:
            HStack(alignment: .top, spacing: 0) { bezel.frame(width: 8); pill; Spacer(minLength: 40) }
                .padding(.vertical, 30).background(wallpaper)
        case .top:
            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.2)).frame(height: 24)
                pill
                Spacer(minLength: 30)
            }
            .padding(.horizontal, 40).background(wallpaper)
        case .bottom:
            VStack(spacing: 0) { Spacer(minLength: 30); pill; bezel.frame(height: 8) }
                .padding(.horizontal, 40).background(wallpaper)
        }
    }
}

@MainActor
enum BarSnapshot {
    static func run(to dir: String) {
        var windows: [(String, NSWindow)] = []
        func host(_ name: String, _ view: some View) {
            let hosting = NSHostingView(rootView: view)
            hosting.frame.size = hosting.fittingSize
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderFrontRegardless()
            windows.append((name, window))
        }
        let store = Store()
        Demo.populate(store, .agents)
        store.agents.expanded = false
        let actions = PillActions(toggle: { _ in })
        for (i, edge) in [DockEdge.right, .top, .left, .bottom].enumerated() {
            let ui = UIState(persists: false, edge: edge)
            host("\(i + 1)a-\(edge.rawValue)-rest", EdgeScene(edge: edge, pill: PillView(store: store, ui: ui, actions: actions, merged: true)))
            host("\(i + 1)b-\(edge.rawValue)-hover", EdgeScene(edge: edge, pill: ExpandedBar(store: store, ui: UIState(persists: false, edge: edge))))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for (_, window) in windows { window.contentView?.layoutSubtreeIfNeeded() }
            for (name, window) in windows {
                guard let view = window.contentView else { continue }
                window.setContentSize(view.fittingSize)
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
            exit(0)
        }
    }
}
