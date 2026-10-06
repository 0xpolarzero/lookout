import SwiftUI

// Settings and Repositories: a page beside the bar (under the strip along the top and bottom), which stays as at rest.

extension LookoutHub {
    // MARK: Pages

    /// The page's header, a hairline, then its form. Switching pages cross-fades; the page slides in once.
    var page: some View {
        VStack(spacing: 0) {
            pageHeader
            Hairline()
            Group {
                if hub.page == .repos { ReposView(store: store) } else { SettingsView(store: store) }
            }
            .id(hub.page)
            .transition(.opacity.animation(Theme.Motion.fade.resolved(reduce: reduce)))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hub.page == .repos ? "Repositories" : "Settings")
    }

    /// 36pt: what page this is (a title; Settings' panes take its place), and the one way back.
    var pageHeader: some View {
        HStack(spacing: Theme.Space.md) {
            Text(hub.page == .repos ? "Repositories" : "Settings")
                .font(Theme.Typography.title).foregroundStyle(Theme.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .id(hub.page)
                .transition(.opacity.animation(Theme.Motion.fade.resolved(reduce: reduce)))
            Spacer(minLength: 0)
            Button { hub.back() } label: {
                Text("Done").font(Theme.Typography.control).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, Theme.Space.sm)
                    .frame(minHeight: Theme.Metrics.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(Theme.Radius.small)
            .help("Done  Esc")
            .accessibilityLabel("Done")
            .accessibilityHint("Closes \(hub.page == .repos ? "Repositories" : "Settings")")
        }
        .padding(.leading, Theme.Metrics.contentEdge)
        .padding(.trailing, Theme.Space.md)
        .frame(height: Theme.Metrics.pitch)
    }
}
