import SwiftUI

// Settings and Repositories: a page that takes the rows' place while the bar stays.

extension LookoutHub {
    // MARK: Pages

    var page: some View {
        VStack(spacing: 0) {
            pageHeader
            Rectangle().fill(Theme.stroke).frame(height: 1)
            Group {
                if hub.page == .repos { ReposView(store: store) } else { SettingsView(store: store) }
            }
            .id(hub.page)
            .transition(Self.reduceMotion ? .opacity : .push(from: hub.forward ? .trailing : .leading))
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
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", help: "Back", detail: "Esc", size: IconButton.Size.header) { hub.back() }
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
        HStack(spacing: 2) {
            ForEach([HubPage.settings, .repos], id: \.self) { p in
                Chip(label: p == .settings ? "Settings" : "Repositories", selected: hub.page == p) { hub.go(p) }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }
}
