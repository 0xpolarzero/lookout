import SwiftUI

// Settings and Repositories: a page that takes the rows' place while the bar stays.

extension LookoutHub {
    // MARK: Pages

    /// Every page is as tall as the hub opens (the callers' frame), whatever its pane holds: moving between panes
    /// never resizes the panel, and the rail keeps its cells. The scroll view inside takes up the difference.
    var page: some View {
        VStack(spacing: 0) {
            pageHeader
            Hairline()
            Group {
                if hub.page == .repos { ReposView(store: store) } else { SettingsView(store: store, openRepos: { hub.go(.repos) }) }
            }
            .id(hub.page)
            .transition(reduce ? .opacity.animation(Theme.Motion.fade) : .push(from: hub.forward ? .trailing : .leading))
            .frame(maxHeight: .infinity, alignment: .top)
            // Cut short by the hub's height: the last line fades into the bottom padding instead of hitting the edge.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 12)
                }
            }
        }
    }

    /// The one way back, and the switch between the two pages (which doubles as their title).
    var pageHeader: some View {
        HStack(spacing: Theme.Space.sm) {
            IconButton(symbol: "chevron.left", help: "Back", detail: "Esc") { hub.back() }
            // The switch is the title: it says which page is open.
            pageSwitch
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.inset + 4)
        .padding(.trailing, Self.inset + 2)
        .frame(height: 42)
    }

    /// "Settings | Repositories", the open one picked.
    var pageSwitch: some View {
        Tabs(label: "Page", tabs: [HubPage.settings, .repos].map { Tabs.Tab(id: $0, title: $0 == .settings ? "Settings" : "Repositories") },
             selection: hub.page) { hub.go($0) }
            .padding(2)
            .background(Capsule().fill(Theme.Fill.group))
    }
}
