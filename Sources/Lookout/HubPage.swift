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
        .accessibilityLabel(pageName)
    }

    /// The page's name: for its accessibility label and what Done closes.
    var pageName: String { hub.page == .repos ? "Repositories" : "Settings" }

    /// What the header says (DESIGN.md 5.8): the page's title. Settings' pane tabs (General, Notifications, Shortcuts,
    /// Claude) take this slot over from the title; the open pane is held here and handed to `SettingsView`, so the one
    /// header carries both the tabs and Done.
    @ViewBuilder var pageHeading: some View {
        PageTitle(pageName)
    }

    /// 36pt: what page this is (a title; Settings' panes take its place), and the one way back.
    var pageHeader: some View {
        PageHeader(closes: pageName, onDone: { hub.back() }) {
            pageHeading
                .id(hub.page)
                .transition(.opacity.animation(Theme.Motion.fade.resolved(reduce: reduce)))
        }
    }
}

/// A page's title, as a heading for VoiceOver.
struct PageTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.Typography.title).foregroundStyle(Theme.text).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A page's header row, 36pt: the heading slot (a title, or Settings' pane tabs, which take all the room Done leaves)
/// and, at the trailing end, Done.
struct PageHeader<Heading: View>: View {
    /// What Done closes, for VoiceOver.
    let closes: String
    let onDone: () -> Void
    @ViewBuilder var heading: Heading

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            heading
            Spacer(minLength: 0)
            Button(action: onDone) {
                Text("Done").font(Theme.Typography.control).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, Theme.Space.sm)
                    .frame(minHeight: Theme.Metrics.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(Theme.Radius.small)
            .help("Done  Esc")
            .accessibilityLabel("Done")
            .accessibilityHint("Closes \(closes)")
        }
        .padding(.leading, Theme.Metrics.contentEdge)
        .padding(.trailing, Theme.Space.md)
        .frame(height: Theme.Metrics.pitch)
    }
}
