import AppKit
import SwiftUI
import Testing
@testable import Lookout

/// One element of the accessibility tree VoiceOver would read, as SwiftUI builds it for a hosted view.
struct AXNode {
    let role: String
    let label: String
    let value: String
    let help: String
    let selected: Bool
    let actions: [String]
    let children: [AXNode]

    /// This element and everything under it.
    var all: [AXNode] { [self] + children.flatMap(\.all) }
    func descendants(_ role: String) -> [AXNode] { all.filter { $0.role == role } }
    func first(_ role: String, _ label: String) -> AXNode? { all.first { $0.role == role && $0.label == label } }

    /// The controls: what a screen reader user presses, ticks or types in, so each must say what it is.
    static let controls: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField",
                                        "AXTextArea", "AXSlider", "AXLink", "AXComboBox"]
}

/// The hub in a window of its own, offscreen, and its accessibility tree.
@MainActor
enum AccessibilityTree {
    /// Rendering needs SwiftUI to believe an assistive technology is attached: it builds the tree only then.
    private static let enabled: Void = {
        _ = NSApplication.shared
        NSApp.perform(NSSelectorFromString("setAccessibilityEnhancedUserInterface:"), with: true as NSNumber)
    }()

    /// The tree of a hub on `edge`, put in the state `configure` asks for once it is on screen.
    static func render(edge: DockEdge = .right, scenario: Demo.Scenario = .agents, size: CGSize = CGSize(width: 900, height: 800),
                       openLength: CGFloat = 700, pressing button: String? = nil,
                       configure: (Store, HubState) -> Void = { _, _ in }) async throws -> AXNode {
        _ = enabled
        let store = Store()
        Demo.populate(store, scenario)
        store.agents.expanded = true
        let hub = HubState()
        let view = LookoutHub(store: store, ui: UIState(persists: false, edge: edge), hub: hub, maxLength: 700, openLength: openLength,
                              maxWidth: size.width, barLength: 700)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow.offscreen(hosting, size: size)
        defer { window.close() }
        configure(store, hub)
        try await Task.sleep(for: .seconds(0.7))
        hosting.layoutSubtreeIfNeeded()
        // What VoiceOver's own activation does: the default action of the button of that name.
        if let button, let target = find(button, in: hosting) {
            _ = target.perform(NSSelectorFromString("accessibilityPerformPress"))
            try await Task.sleep(for: .seconds(0.2))
        }
        return node(hosting)
    }

    private static func find(_ label: String, in element: Any) -> NSObject? {
        guard let object = element as? NSObject else { return nil }
        if (object.value(forKey: "accessibilityRole") as? String) == "AXButton",
           (object.value(forKey: "accessibilityLabel") as? String) == label { return object }
        for child in (object.value(forKey: "accessibilityChildren") as? [Any]) ?? [] {
            if let found = find(label, in: child) { return found }
        }
        return nil
    }

    private static func node(_ element: Any) -> AXNode {
        guard let object = element as? NSObject else { return AXNode(role: "?", label: "", value: "", help: "", selected: false, actions: [], children: []) }
        func string(_ key: String) -> String { (object.value(forKey: key) as? String) ?? "" }
        let role = string("accessibilityRole")
        // A scroll bar's parts are the system's own.
        let children = role == "AXScrollBar" ? [] : ((object.value(forKey: "accessibilityChildren") as? [Any]) ?? []).map(node)
        let value = object.value(forKey: "accessibilityValue").map { "\($0)" } ?? ""
        let actions = (object.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction])?.map(\.name) ?? []
        return AXNode(role: role, label: string("accessibilityLabel"), value: value, help: string("accessibilityHelp"),
                      selected: (object.value(forKey: "accessibilitySelected") as? Bool) ?? false, actions: actions, children: children)
    }
}

@MainActor
@Suite struct AccessibilityTreeTests {
    /// Every control of the hub in `state` has a name, wherever it is.
    private func unnamed(_ state: String, edge: DockEdge = .right, configure: @escaping (Store, HubState) -> Void) async throws -> [String] {
        let tree = try await AccessibilityTree.render(edge: edge, configure: configure)
        return tree.all.filter { AXNode.controls.contains($0.role) && $0.label.isEmpty }.map { "\(state) (\(edge)): \($0.role) has no label" }
    }

    @Test func noButtonIsLeftWithoutAName() async throws {
        var missing: [String] = []
        for edge in [DockEdge.right, .top] {
            missing += try await unnamed("at rest", edge: edge) { _, _ in }
            missing += try await unnamed("kept open", edge: edge) { _, hub in hub.pinned = true }
            missing += try await unnamed("searching", edge: edge) { _, hub in hub.pinned = true; hub.query = "zig" }
            missing += try await unnamed("controls", edge: edge) { _, hub in hub.showControls() }
        }
        for section in [HubSection.inbox, .ci, .agents] {
            missing += try await unnamed("peek \(section.name)") { _, hub in hub.section = section }
        }
        for focus in [HubSection.inbox, .ci, .agents] {
            missing += try await unnamed("\(focus.name) focused") { _, hub in hub.pinned = true; hub.focus = focus }
        }
        for tab in [InboxFilter.bots, .done] {
            missing += try await unnamed("\(tab.label) tab") { _, hub in hub.pinned = true; hub.filter = tab }
        }
        missing += try await unnamed("Passing open") { _, hub in hub.pinned = true; hub.ciPassingOpen = true }
        for pane in SettingsPane.allCases {
            missing += try await unnamed("Settings \(pane.title)") { _, hub in hub.go(.settings); hub.settingsPane = pane }
        }
        missing += try await unnamed("Repositories") { _, hub in hub.go(.repos) }
        missing += try await unnamed("signed out") { store, hub in store.authError = "Bad credentials"; hub.pinned = true }
        missing += try await unnamed("update ready") { store, hub in store.updater.preview(.ready, version: "0.5.0"); hub.pinned = true }
        #expect(missing.isEmpty, "\(missing)")
    }
}

/// What VoiceOver finds, and in what shape (DESIGN.md 7): the root container, the sections in it, every bar cell a button
/// with its value, hint and Show, rows as one element each with their actions.
@MainActor
@Suite struct AccessibilityStructure {
    private func root(_ tree: AXNode) throws -> AXNode {
        try #require(tree.children.first { $0.label == "Lookout" }, "No Lookout container under \(tree.children.map(\.label))")
    }

    @Test func theBarAtRestIsOneContainerOfFourSectionsAndEachCellAButtonWithShow() async throws {
        for edge in [DockEdge.right, .top] {
            let lookout = try root(try await AccessibilityTree.render(edge: edge))
            #expect(lookout.children.map(\.label) == ["Inbox", "CI", "Sessions", "Controls"], "\(edge)")
            let cells = lookout.all.filter { $0.role == "AXButton" || $0.role == "AXMenuButton" }
            #expect(!cells.isEmpty && cells.allSatisfy { $0.actions.contains("Show") || $0.label == "Settings" }, "\(edge)")
            let inbox = try #require(lookout.first("AXButton", "Inbox"))
            #expect(inbox.value == "5 need you, 2 bot items" && inbox.help == "Shows the inbox" && inbox.actions == ["Show"])
            let ci = try #require(lookout.first("AXButton", "CI"))
            #expect(ci.value == "1 failing, 1 running, 2 passing" && ci.actions.contains("Show"))
            // A session's tile says its state, project and age, and its hint is what it last said.
            let waiting = try #require(lookout.first("AXButton", "LCU update notifications"))
            #expect(waiting.value.hasPrefix("waiting for you, lcu, ") && !waiting.help.isEmpty && waiting.actions == ["Show"])
            // The gear: Settings by press, the controls by its actions.
            let gear = try #require(lookout.first("AXButton", "Settings"))
            #expect(Set(gear.actions) == ["Show controls", "Check now", "Repositories", "Keep open"])
            #expect(lookout.first("AXMenuButton", "New session")?.actions == ["Show"])
        }
    }

    @Test func noSessionsIsSaidKeptOpenOnEveryEdgeAndLeftOutOfAPeek() async throws {
        func nobody(_ store: Store, _ hub: HubState) { store.claudeSessions = [:]; store.agents.entries = [] }
        func says(_ tree: AXNode) -> Bool { tree.all.contains { $0.label == "No Claude sessions" || $0.value == "No Claude sessions" } }
        for edge in [DockEdge.right, .top] {
            let open = try await AccessibilityTree.render(edge: edge) { store, hub in nobody(store, hub); hub.pinned = true }
            #expect(says(open), "\(edge) kept open")
        }
        let peek = try await AccessibilityTree.render { store, hub in nobody(store, hub); hub.section = .agents }
        #expect(!says(peek) && peek.all.contains { $0.label == "New session" })
    }

    @Test func theKeptOpenHubIsReadInTheSameOrderOnEveryEdge() async throws {
        // Only the strip moves to the bottom edge (DESIGN.md 10.8): its controls come before the content they filter, and the
        // footer's Controls after it, whichever way they are drawn.
        func order(_ edge: DockEdge) async throws -> [String] {
            try root(try await AccessibilityTree.render(edge: edge) { _, hub in hub.pinned = true }).children.map { "\($0.role) \($0.label)" }
        }
        let top = try await order(.top)
        #expect(try await order(.bottom) == top)
        #expect(top.first == "AXButton Inbox" && top.last == "AXGroup Controls", "\(top)")
    }

    @Test func aListCutShortAlwaysSaysSoWhereverTheRoomIs() async throws {
        // What the open-low shots show: the room below a low bar leaves the inbox a row and its line, or only a row. The six
        // items are more than either holds, so the rest is said under the list (a button) or, with no room for that line,
        // in the header (text).
        // No room for a row (160), a row and no line (190), a row and its line (210), more (250); a side each.
        for (edge, room) in [(DockEdge.left, 160), (.left, 190), (.right, 205), (.right, 210), (.left, 250)] as [(DockEdge, CGFloat)] {
            let tree = try root(try await AccessibilityTree.render(edge: edge, scenario: .noCI, openLength: room) { store, hub in
                store.agents.enabled = false
                hub.pinned = true
            })
            let says = tree.all.contains { $0.label.hasSuffix("more items") || "\($0.value)".hasSuffix("more items") }
            #expect(says, "\(edge) with \(room) pt: the list is cut and nothing says there are more")
        }
    }

    @Test func theKeptOpenHubHasASectionAndAHeadingForEach() async throws {
        let lookout = try root(try await AccessibilityTree.render { _, hub in hub.pinned = true })
        #expect(lookout.children.map(\.label) == ["Inbox", "CI", "Sessions", "Controls"])
        #expect(lookout.first("AXHeading", "CI") != nil && lookout.first("AXHeading", "Sessions") != nil)
        // The project groups are headings too.
        #expect(lookout.first("AXHeading", "Waiting for you") != nil && lookout.first("AXHeading", "microsandbox") != nil)
        // The tabs are one tab group, with the open one selected.
        let tabs = try #require(lookout.all.first { $0.role == "AXTabGroup" })
        #expect(tabs.label == "Inbox filter" && tabs.children.count == 3)
        #expect(tabs.children.filter(\.selected).map(\.label) == ["Needs you, 5"], "\(tabs.children.map { ($0.label, $0.selected) })")
    }

    @Test func aRowIsOneElementWithItsLabelValueHintAndActions() async throws {
        let lookout = try root(try await AccessibilityTree.render { _, hub in hub.pinned = true })
        let item = try #require(lookout.all.first { $0.label.hasPrefix("Review comment from andrewrk on zig #21877: std.Io: add vectored reads to File") })
        #expect(item.role == "AXButton" && item.label.hasSuffix("minutes ago") && item.value == "Unread")
        #expect(item.help == "Opens on GitHub. More actions available.")
        #expect(Set(item.actions) == ["Open on GitHub", "Mark as read", "Done", "Copy link"])
        let read = try #require(lookout.all.first { $0.label.hasPrefix("Issue comment from kyle") })
        #expect(read.value.isEmpty && read.actions.contains("Mark as unread"))
        let failing = try #require(lookout.first("AXButton", "swift-format"))
        #expect(failing.value.hasPrefix("failing, Linux build and Windows test, ") && failing.value.hasSuffix("minutes ago"))
        #expect(failing.actions.contains("Mute until it changes") && failing.actions.contains("Open checks"))
        // A project's rows can trade places with the neighbour they have: the first only down, the middle both, the last only up.
        let project = ["CI failure diagnosis", "Repository ownership transfer setup", "LCU JavaScript sandbox on Linux"]
        let moves = try project.map { name in Set(try #require(lookout.first("AXButton", name)).actions).filter { $0.hasPrefix("Move") } }
        #expect(moves == [["Move down"], ["Move up", "Move down"], ["Move up"]], "\(moves)")
        let session = try #require(lookout.first("AXButton", "Calculator display reading"))
        #expect(session.value.hasPrefix("finished, unread, lcu-research") && Set(session.actions) == ["Mark as read", "Keep", "Hide"])
    }

    @Test func theSearchFieldIsNamedAndSaysWhatItFound() async throws {
        let lookout = try root(try await AccessibilityTree.render { _, hub in hub.pinned = true; hub.query = "zig" })
        let field = try #require(lookout.all.first { $0.role == "AXTextField" })
        #expect(field.label == "Search inbox and sessions" && field.value == "zig")
        #expect(lookout.all.contains { $0.role == "AXStaticText" && $0.value == "3 items · 0 sessions" })
        #expect(lookout.first("AXHeading", "Inbox, 3 results") != nil)
        // CI leaves the layout while searching, its cell stays.
        #expect(lookout.first("AXButton", "CI") != nil)
    }

    @Test func theSearchFieldStaysWhenSessionsAreFocusedOnItsResults() async throws {
        // ⌘3 while searching: the inbox folds to its header, but the field the sessions are filtered by is still there.
        for edge in [DockEdge.right, .top] {
            let lookout = try root(try await AccessibilityTree.render(edge: edge) { _, hub in
                hub.pinned = true; hub.query = "zig"; hub.focus = .agents
            })
            let field = try #require(lookout.all.first { $0.role == "AXTextField" })
            #expect(field.label == "Search inbox and sessions" && field.value == "zig")
        }
    }

    @Test func aFocusedSessionsListScrolledToItsLastRowEndsWithBackToTheTop() async throws {
        // What the focus-agents-sessions-end shots show: the request for the last session is made before the list mounts.
        for edge in [DockEdge.right, .top] {
            let lookout = try root(try await AccessibilityTree.render(edge: edge, scenario: .sessionsManyNew) { store, hub in
                hub.pinned = true
                hub.focus = .agents
                if let last = store.listedGroups(expanded: true).groups.flatMap(\.rows).last { hub.requestScroll("a:" + last.id) }
            })
            // At the end the cue is the way back up; had the list stayed at its first page, it would say how many are below.
            #expect(lookout.first("AXButton", "Back to the top") != nil, "\(edge)")
        }
    }

    @Test func settingsAndRepositoriesAreNamedPagesWithTheirTabsAndHeadings() async throws {
        let settings = try root(try await AccessibilityTree.render { _, hub in hub.go(.settings) })
        let page = try #require(settings.children.first { $0.label == "Settings" })
        let tabs = try #require(page.all.first { $0.role == "AXTabGroup" })
        #expect(tabs.label == "Settings pane" && tabs.children.map(\.label) == ["General", "Notifications", "Shortcuts", "Claude"])
        #expect(tabs.children.filter(\.selected).map(\.label) == ["General"])
        #expect(page.first("AXButton", "Done")?.help == "Closes Settings")
        #expect(page.all.contains { $0.role == "AXHeading" && $0.label == "GitHub" })
        // The open pane is a heading too, whichever pane it is.
        for pane in SettingsPane.allCases {
            let tree = try root(try await AccessibilityTree.render { _, hub in hub.go(.settings); hub.settingsPane = pane })
            #expect(tree.all.contains { $0.role == "AXHeading" && $0.label == pane.title }, "\(pane.title)")
        }
        // The bar beside it is the same bar, its gear saying what it now does.
        #expect(settings.first("AXButton", "Close Settings") != nil)
        let repos = try root(try await AccessibilityTree.render { _, hub in hub.go(.repos) })
        let list = try #require(repos.children.first { $0.label == "Repositories" })
        #expect(list.first("AXHeading", "Repositories") != nil)
        let repo = try #require(list.all.first { $0.label == "ziglang/zig" })
        #expect(Set(repo.actions) == ["Stop watching", "Move up", "Move down", "Toggle issues", "Toggle pull requests", "Toggle CI"])
        // The first repository can only go down, the last only up, as in the context menu.
        let moves = try ["0xpolarzero/lookout", "e2b-dev/runtime"].map { name in
            Set(try #require(list.all.first { $0.label == name }).actions).filter { $0.hasPrefix("Move") }
        }
        #expect(moves == [["Move down"], ["Move up"]], "\(moves)")
    }

    @Test func voiceOversPressOnTheInboxCIAndASessionKeepsTheHubOpen() async throws {
        for button in ["Inbox", "CI", "LCU update notifications"] {
            for edge in [DockEdge.right, .top] {
                nonisolated(unsafe) var pinned: HubState?
                _ = try await AccessibilityTree.render(edge: edge, pressing: button) { _, hub in pinned = hub }
                let hub = try #require(pinned)
                // Not a click's own (the checks, or the session in Claude): the hub is kept open on the cell's section.
                #expect(hub.pinned && hub.focus == nil, "\(button) on \(edge)")
            }
        }
    }

    @Test func theUpdateCellOffersItsMenuAsActions() async throws {
        let lookout = try root(try await AccessibilityTree.render { store, _ in store.updater.preview(.ready, version: "0.5.0") })
        let update = try #require(lookout.first("AXButton", "Restart to update"))
        #expect(update.actions.contains("Show") && update.actions.contains("Skip 0.5.0"), "\(update.actions)")
    }

    @Test func theControlsPeekIsAContainerOfNamedRows() async throws {
        let lookout = try root(try await AccessibilityTree.render { _, hub in hub.showControls() })
        let controls = try #require(lookout.children.last { $0.label == "Controls" })
        #expect(controls.descendants("AXButton").map(\.label) == ["Keep open", "Repositories…", "Settings…", "Sync now"])
    }
}

/// Where VoiceOver's cursor is sent, and what is said when the hub opens or CI changes under it.
@MainActor
@Suite struct VoiceOverMoves {
    private let store = Store()
    private let hub = HubState()
    private let ui = UIState(persists: false, edge: .right)
    private var view: LookoutHub { LookoutHub(store: store, ui: ui, hub: hub, maxLength: 700) }

    init() {
        Demo.populate(store, .agents)
        store.agents.expanded = true
    }

    @Test func showControlsOnAPageGoesBackToTheMainViewsControls() {
        // Opened from the bare bar: back to it, and the peek of the controls has the keys.
        hub.go(.settings)
        hub.showControls()
        #expect(hub.page == .main && !hub.pinned && hub.section == .controls && hub.menuKeys)
        // Kept open before the page: still kept open, and the cursor goes to the footer.
        hub.closePeek()
        hub.menuKeys = false
        hub.pinned = true
        hub.go(.repos)
        hub.showControls()
        #expect(hub.page == .main && hub.pinned && hub.voiceOverRequest?.target == "h:controls")
    }

    @Test func clickingTheInboxWithAnotherSectionFocusedPicksARowThatIsThere() {
        for focus in [HubSection.ci, .agents] {
            hub.focus = focus
            view.openInbox()
            #expect(hub.focus == nil && hub.selection == "i:" + store.list(.needsYou)[0].id, "\(focus)")
        }
        // The inbox focused already keeps the room it has.
        hub.focus = .inbox
        view.openInbox()
        #expect(hub.focus == .inbox)
    }

    @Test func showOnTheInboxKeepsTheHubOpenAndSendsVoiceOverToItsFirstRow() {
        view.show(.inbox)
        let first = "i:" + store.list(.needsYou)[0].id
        #expect(hub.pinned && hub.selection == first && hub.voiceOverRequest?.target == first)
    }

    @Test func showOnTheInboxWithASignInProblemGoesToTheHeaderNotAnAbsentRow() {
        // The cached items are not drawn: the banner replaces them, and the cursor goes to what is.
        hub.selection = "a:x"
        store.authError = "Bad credentials"
        view.show(.inbox)
        #expect(hub.selection == nil && hub.voiceOverRequest?.target == "h:inbox")
    }

    @Test func showControlsOnTheGearOpensTheMenuAtRestWithoutPinningAndSendsVoiceOverToItsFirstRow() {
        view.show(.controls)
        #expect(hub.section == .controls && hub.menuKeys && !hub.pinned && hub.voiceOverRequest?.target == "h:controls")
    }

    @Test func showControlsKeptOpenSendsVoiceOverToTheFootersFirstControl() {
        hub.pinned = true
        view.show(.controls)
        // The footer is the controls there: no menu to take the keys, nothing to unpin.
        #expect(hub.pinned && !hub.menuKeys && hub.section == nil && hub.voiceOverRequest?.target == "h:controls")
    }

    @Test func reopeningOnAFocusedSectionSendsVoiceOverToTheHeaderThatIsShowing() {
        hub.focus = .ci
        hub.moveVoiceOverIntoHub()
        #expect(hub.voiceOverRequest?.target == "h:ci")
        hub.voiceOverRequest = nil
        hub.focus = .agents
        hub.moveVoiceOverIntoHub()
        #expect(hub.voiceOverRequest?.target == "h:agents")
        hub.voiceOverRequest = nil
        hub.focus = nil
        hub.moveVoiceOverIntoHub()
        #expect(hub.voiceOverRequest?.target == "h:inbox")
    }

    @Test func showOnASessionSendsVoiceOverToThatSession() {
        let id = store.hubSessions(hub)[2].id
        view.show(.agents, session: id)
        #expect(hub.pinned && hub.selection == "a:" + id && hub.voiceOverRequest?.target == "a:" + id)
    }

    @Test func theInboxCellEndsASearchSoItsTabsAndActionsComeBack() {
        hub.pinned = true
        hub.beginSearch()
        #expect(hub.inbox.searchOpen)
        view.openInbox()
        #expect(hub.query.isEmpty && !hub.inbox.searchOpen && hub.filter == .needsYou)
    }

    @Test func showOnCIGoesToItsHeader() {
        view.show(.ci)
        #expect(hub.pinned && hub.voiceOverRequest?.target == "h:ci" && hub.selection?.hasPrefix("c:") == true)
    }

    @Test func showOnCIFromAnOpenSearchFieldClosesTheFieldSoReturnActsOnTheRow() {
        hub.pinned = true
        hub.beginSearch()
        hub.query = "zig"
        view.show(.ci)
        #expect(hub.query.isEmpty && !hub.inbox.searchOpen && !hub.inbox.searchFocused && hub.selection?.hasPrefix("c:") == true)
    }

    @Test func showStepsBackFromASectionFocusSoWhatIsShownIsThere() {
        hub.pinned = true
        hub.focus = .agents
        view.show(.inbox)
        #expect(hub.focus == nil)
    }

    @Test func openingFromTheKeyboardSendsVoiceOverToThePickedRowElseTheInbox() {
        hub.moveVoiceOverIntoHub()
        #expect(hub.voiceOverRequest?.target == "h:inbox")
        hub.voiceOverRequest = nil
        hub.selection = "a:x"
        hub.moveVoiceOverIntoHub()
        #expect(hub.voiceOverRequest?.target == "a:x")
    }

    @Test func openingDoesNotTakeVoiceOverFromWhereShowJustSentIt() {
        hub.moveVoiceOver(to: "h:ci")
        hub.moveVoiceOverIntoHub()
        #expect(hub.voiceOverRequest?.target == "h:ci")
        // A request nobody answered goes stale.
        hub.voiceOverRequest = VoiceOverRequest(target: "h:ci", at: Date().addingTimeInterval(-HubState.voiceOverPatience - 1))
        hub.moveVoiceOverIntoHub()
        #expect(hub.voiceOverRequest?.target == "h:inbox")
    }

    @Test func theHubSaysWhatNeedsYouWhenItOpens() {
        #expect(store.openingAnnouncement == "Lookout, 5 need you, 1 CI failing, 1 session waiting")
        store.items = store.items.filter { !$0.state.isOpen }
        #expect(store.openingAnnouncement == "Lookout, nothing needs you, 1 CI failing, 1 session waiting")
        store.agents.enabled = false
        for key in store.ci.keys { store.ci[key]?.state = .success }
        #expect(store.openingAnnouncement == "Lookout, nothing needs you")
    }

    @Test func aFaultFoundWhileTheHubWasClosedIsSaidWhenItOpens() {
        store.repoErrors = ["ziglang/zig": "Not found (or no access)"]
        store.claudeLink = .missing
        #expect(store.openingAnnouncement.hasSuffix(". 1 repository didn't sync. Claude's sessions not found. Open the Claude desktop app once"),
                "\(store.openingAnnouncement)")
        store.agents.enabled = false
        #expect(!store.openingAnnouncement.contains("Claude's sessions"))
    }

    @Test func ciChangingUnderTheOpenHubIsSaidByNameAndEachRepositoryCounts() {
        let before = store.ciStates
        // Nothing moved.
        #expect(store.ciChangeAnnouncement(from: before, to: store.ciStates) == nil)
        // One repository stays failing while another goes from running to passing: that is a change too.
        store.ci["ziglang/zig"]?.state = .success
        #expect(store.ciChangeAnnouncement(from: before, to: store.ciStates) == "CI passing: zig")
        // Several at once are one announcement, the failing first.
        var states = before
        store.ci["ziglang/zig"]?.state = .failure
        store.ci["ziglang/zig"]?.failing = ["Linux / test"]
        store.ci["apple/swift-format"]?.state = .success
        states["ziglang/zig"] = .pending
        #expect(store.ciChangeAnnouncement(from: states, to: store.ciStates) == "CI failing: zig. CI passing: swift-format")
        // A repository with no earlier answer is not a change.
        #expect(store.ciChangeAnnouncement(from: [:], to: store.ciStates) == nil)
    }

    @Test func aChangeThatEndsAMuteIsSaidEvenToTheStateItWasMutedAt() {
        store.ci["ziglang/zig"]?.state = .pending
        store.mutedCI["ziglang/zig"] = store.ci["ziglang/zig"]?.sha ?? ""
        let muted = store.ciStates
        // Muting is no change to tell.
        #expect(store.ciChangeAnnouncement(from: muted, to: store.ciStates) == nil)
        // The running CI fails, which ends the mute.
        store.mutedCI["ziglang/zig"] = nil
        store.ci["ziglang/zig"]?.state = .failure
        #expect(store.ciChangeAnnouncement(from: muted, to: store.ciStates) == "CI failing: zig")
    }
}
