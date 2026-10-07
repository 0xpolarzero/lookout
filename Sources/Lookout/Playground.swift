import AppKit
import Carbon
import SwiftUI

// `--playground`: a window with a fake desktop to try the hub with the demo data.

// MARK: - Playground window

/// A fake desktop: the bar on the edge you pick, an app behind it, and the keys wired up.
struct PlaygroundView: View {
    let store: Store
    @Bindable var ui: UIState
    @Bindable var hub: HubState
    /// The "Lookout playground" card with the edge picker and key hints: for trying it, not for screenshots.
    var showsExplainer = true
    /// The window's least size; screenshots at another size (1280×720) set their own.
    var minSize = CGSize(width: 1280, height: 820)
    @State private var behindClicks = 0
    @State private var layout = HubLayout()

    private let menuBar: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.20, green: 0.27, blue: 0.42), Color(red: 0.47, green: 0.38, blue: 0.52),
                                        Color(red: 0.70, green: 0.52, blue: 0.50)], startPoint: .topLeading, endPoint: .bottomTrailing)
                behindApp.position(x: geo.size.width - 330, y: 260)
                if showsExplainer {
                    controls.position(x: geo.size.width / 2 - (ui.edge == .right ? 140 : ui.edge == .left ? -140 : 0),
                                      y: geo.size.height / 2 + (ui.edge == .top ? 120 : ui.edge == .bottom ? -120 : 0))
                }
                fakeMenuBar.frame(maxHeight: .infinity, alignment: .top)
                docked
                if let toast = hub.toast {
                    Text(toast).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 70)
                        .transition(.opacity)
                }
            }
        }
        .frame(minWidth: minSize.width, minHeight: minSize.height)
        // As in the app: tooltips over the whole window, outside the hub's clipped shape.
        .tipSpace()
        .animation(.easeOut(duration: 0.2), value: hub.toast)
        .onChange(of: hub.toast) { _, toast in
            guard toast != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if hub.toast == toast { hub.toast = nil } }
        }
    }

    /// The hub as the app lays it out (`HubRoot`) in the room under the menu bar, so what the playground and the shots
    /// show of where it sits, rest and open, is the app's own geometry.
    private var docked: some View {
        HubRoot(store: store, ui: ui, hub: hub, layout: layout)
            .padding(.top, menuBar)
    }

    private var fakeMenuBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold)
            ForEach(["Fichier", "Édition", "Présentation", "Aller", "Fenêtre", "Aide"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "wifi")
            Text("lun. 5 oct.  12:04")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: menuBar)
        .background(Color.black.opacity(0.22))
    }

    /// Something under the open view.
    private var behindApp: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 11, height: 11) }
                Spacer()
                Text("Some app behind").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
                Spacer()
            }
            Text("An app under Lookout: clicks around the bar reach it.")
                .font(.system(size: 12.5)).foregroundStyle(.black.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Button("Clicked \(behindClicks) times") { behindClicks += 1 }
                .controlSize(.large)
            Spacer()
        }
        .padding(14)
        .frame(width: 520, height: 330)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.94)))
        .environment(\.colorScheme, .light)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lookout playground").font(.system(size: 15, weight: .semibold))
            Picker("Edge", selection: Binding(get: { ui.edge }, set: { e in hub.page = .main; ui.edge = e })) {
                Text("Left").tag(DockEdge.left)
                Text("Top").tag(DockEdge.top)
                Text("Right").tag(DockEdge.right)
                Text("Bottom").tag(DockEdge.bottom)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                Text("Hover the bar to expand it · right ⌘ keeps it open").foregroundStyle(.secondary)
                Text("Esc: back / close").foregroundStyle(.secondary)
                Text("↑ ↓ ↩ Space ⌫ ⌘K ⌘⌫ ⌥Space ⌘, as in the app").foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            Label(hub.pinned ? "Pinned" : "Not pinned", systemImage: hub.pinned ? "pin.fill" : "pin")
                .font(.system(size: 11.5, weight: .medium))
        }
        .padding(16)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .environment(\.colorScheme, .dark)
    }
}

/// `--playground`: the window, the demo data and the keys.
@MainActor
final class Playground: NSObject, NSWindowDelegate {
    private let store = Store()
    private let ui = UIState(persists: false, edge: .right)
    private let hub = HubState()
    private var window: NSWindow!
    private var monitor: Any?
    private var tap = ModifierTap()
    private lazy var keys = HubKeys(store: store, ui: ui, hub: hub)

    func run() {
        Demo.populate(store, .agents)
        store.agents.expanded = true
        store.interceptOpen = { [hub] text in hub.toast = text }
        let view = PlaygroundView(store: store, ui: ui, hub: hub)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Lookout playground"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Only a Bool crosses the isolation hop: NSEvent is not Sendable.
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    /// True when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            if tap.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) == 54 { keys.toggleTap() }
            return false
        case .leftMouseDown:
            tap.interrupt()
            return false
        default:
            tap.interrupt()
            return keys.key(event)
        }
    }
}


// MARK: - Screenshots

/// Overrides for the accessibility settings a shot renders under, applied through SwiftUI's environment. Only a set
/// flag overrides; the others keep what the system says.
///
/// How the theme reads them: `\.colorSchemeContrast`, `\.accessibilityReduceMotion` and
/// `\.accessibilityDifferentiateWithoutColor` return these values inside a shot, so anything that resolves them
/// from the environment (the `Theme.Resolved` value, `.motion`, `Pulse`'s hosting view) follows the shot. Reads that
/// bypass the environment do not: `NSWorkspace.shared.accessibilityDisplayShould…`, `LookoutHub.reduceNow` and
/// anything in a window of its own. Those always show the system's setting, so a shot for them needs the view to take
/// the value from its environment.
struct ShotEnvironment: Equatable {
    var increaseContrast = false
    var reduceMotion = false
    var differentiateWithoutColor = false

    static let contrast = ShotEnvironment(increaseContrast: true)
    static let motion = ShotEnvironment(reduceMotion: true)
    static let differentiate = ShotEnvironment(differentiateWithoutColor: true)
    static let all = ShotEnvironment(increaseContrast: true, reduceMotion: true, differentiateWithoutColor: true)
}

private extension View {
    /// SwiftUI declares these environment values get-only; the underscored keys are the settable ones behind them.
    func shotEnvironment(_ shot: ShotEnvironment) -> some View {
        transformEnvironment(\._colorSchemeContrast) { if shot.increaseContrast { $0 = .increased } }
            .transformEnvironment(\._accessibilityReduceMotion) { if shot.reduceMotion { $0 = true } }
            .transformEnvironment(\._accessibilityDifferentiateWithoutColor) { if shot.differentiateWithoutColor { $0 = true } }
    }
}

extension [DockEdge] {
    static let all: [DockEdge] = [.right, .top, .left, .bottom]
    /// The side bar and the strip: where a state differs between them.
    static let rightAndTop: [DockEdge] = [.right, .top]
    static let sides: [DockEdge] = [.right, .left]
    static let strips: [DockEdge] = [.top, .bottom]
}

/// What a shot has picked, for the row actions and the keyboard pick to show.
enum ShotSelection {
    /// The newest inbox item that needs you.
    case firstNeedsYou
    case session(String)
}

/// What a shot shows instead of the playground.
enum ShotSheet {
    /// The design system's components, each in its states (`ComponentSheet`).
    case components
    /// The working ring on tiles (`MotionSheet`).
    case rings
}

/// One screenshot: the playground in a given state, rendered offscreen to `<name>.png`. Add one by adding a line to
/// `PlaygroundShots.catalog`; everything but `name` has a default.
struct Shot {
    static let standard = CGSize(width: 1280, height: 820)
    /// A 1280×720 screen: the hub must fit its edge without overflowing.
    static let hd = CGSize(width: 1280, height: 720)
    /// The rings sheet: a few rows of tiles.
    static let rings = CGSize(width: 480, height: 160)

    var name: String
    var edge = DockEdge.right
    /// Where the bar rests along its edge, as a fraction of its length (what the user's drag saves): a third of the way
    /// leaves a side hub its full height and a strip its width, so rest and kept open compare directly.
    var position = 0.3
    /// A sheet instead of the playground (the fields below that describe the hub are then ignored).
    var sheet: ShotSheet?
    /// The data (see `Demo.Scenario`).
    var scenario = Demo.Scenario.agents
    /// Kept open (as when pinned) rather than at rest.
    var pinned = false
    var page = HubPage.main
    /// Just this section open beside the bar, as when it is hovered.
    var section: HubSection?
    /// The section filling the view, as when its header is clicked.
    var focus: HubSection?
    var filter: InboxFilter?
    var query = ""
    var selection: ShotSelection?
    /// A session row under the pointer.
    var hoveredSession: String?
    /// A tooltip shown at once, by title (see `Tip`).
    var tip: String?
    var size = Shot.standard
    var environment = ShotEnvironment()
    /// The pane, field or disclosure the Settings and Repositories pages open in (see `PagePreview`).
    var preview = PagePreview()
    /// The playground's own "Lookout playground" card: hidden, as it is not part of what is being designed.
    var showsExplainer = false
    /// Anything the fields above don't cover, after they are applied.
    var setup: ((Store, UIState, HubState) -> Void)?
    /// What happens once the hub has opened to the shot's state (its pin, page and focus), where `setup` runs before: a
    /// change made by something that comes after the open, such as search from a focused section.
    var afterOpen: ((Store, UIState, HubState) -> Void)?

    /// The same shot on each of these edges, named `<edge>-<state>`.
    static func edges(_ state: String, on edges: [DockEdge] = .all,
                      _ configure: (inout Shot) -> Void = { _ in }) -> [Shot] {
        edges.map { edge in
            var shot = Shot(name: "\(edge.rawValue)-\(state)", edge: edge)
            configure(&shot)
            return shot
        }
    }
}

/// `--playground-shots <dir> [substring…]`: the real views, on the demo data, rendered offscreen as PNGs. Shots
/// whose name contains one of the substrings are rendered (all of them without any), so a change is checked in a few
/// seconds: `.build/debug/Lookout --playground-shots /tmp/shots right-open`.
///
/// Names are `<edge>-<state>`, the edge being right, top, left or bottom. Every shot is one line of `catalog` below,
/// under a comment saying what the group shows: the baseline (rest, open, a page, search, each peek and focus), the
/// inbox, the causes that empty a list or break the sync, CI, sessions, the update cell, the accessibility settings,
/// Settings and Repositories in each of their states, the shared components and the working ring (no hub), where the bar
/// rests along its edge, and a 1280×720 screen. Most states are on the right edge and along the top, which stand for the
/// sides and the strip; the baseline and the bar at rest are on all four.
@MainActor
enum PlaygroundShots {
    /// States of the data, as `(name, scenario)`; each is shown at rest, open and as a peek where it applies.
    private static let causes: [(String, Demo.Scenario)] = [
        ("signed-out", .signedOut), ("repos-failed", .reposFailed), ("rate-limited", .rateLimited), ("snoozed", .snoozed),
        ("error", .error), ("needs-you-empty", .needsYouEmpty), ("first-sync", .firstSync), ("sync-fault", .syncFault),
        ("review-requests-cut", .reviewRequestsCut), ("offline", .offline),
    ]
    /// Why the inbox is empty or has a banner, as `(name, scenario, tab)`.
    private static let inboxCauses: [(String, Demo.Scenario, InboxFilter?)] = [
        ("signed-out", .signedOut, nil), ("no-repos", .empty, nil), ("repos-failed", .reposFailed, nil),
        ("review-requests-failed", .reviewRequestsFailed, nil), ("review-requests-cut", .reviewRequestsCut, nil), ("rate-limited", .rateLimited, nil), ("snoozed", .snoozed, nil), ("caught-up", .needsYouEmpty, nil),
        ("bots-empty", .botsEmpty, .bots), ("done-empty", .doneEmpty, .done), ("first-sync", .firstSync, nil), ("offline", .offline, nil),
    ]
    private static let ci: [(String, Demo.Scenario)] = [
        ("all-passing", .allPassing), ("many-ci", .manyCI), ("ci-running", .ciRunning), ("ci-no-runs", .ciNoRuns),
    ]
    private static let sessions: [(String, Demo.Scenario)] = [
        ("sessions-waiting", .sessionsWaiting), ("sessions-working", .sessionsWorking), ("sessions-unread", .sessionsUnread),
        ("sessions-new-activity", .sessionsNewActivity), ("sessions-scratch", .sessionsScratch),
        ("sessions-none", .sessionsNone), ("sessions-12", .sessions12), ("sessions-waiting-10", .sessionsWaiting10),
    ]
    private static let updates: [(String, Demo.Scenario)] = [
        ("update-available", .updateAvailable), ("update-downloading", .updateDownloading), ("update-ready", .updateReady),
    ]

    /// Sessions on every edge: the peek and the kept-open list on the edges left over, the focused list on all four,
    /// New activity cut to eight, and a session picked and one under the pointer.
    private static let sessionShots: [Shot] = {
        var shots = sessions.flatMap { slug, scenario in
            Shot.edges("peek-agents-\(slug)", on: [.left, .bottom]) { $0.section = .agents; $0.scenario = scenario }
                + Shot.edges("open-\(slug)", on: [.left, .bottom]) { $0.pinned = true; $0.scenario = scenario }
                + Shot.edges("focus-agents-\(slug)") { $0.pinned = true; $0.focus = .agents; $0.scenario = scenario }
        }
        shots += Shot.edges("rest-sessions-many-new") { $0.scenario = .sessionsManyNew }
        shots += Shot.edges("open-sessions-many-new") { $0.pinned = true; $0.scenario = .sessionsManyNew }
        shots += Shot.edges("peek-agents-sessions-many-new") { $0.section = .agents; $0.scenario = .sessionsManyNew }
        shots += Shot.edges("focus-agents-sessions-many-new") { $0.pinned = true; $0.focus = .agents; $0.scenario = .sessionsManyNew }
        shots += Shot.edges("picked-sessions") {
            $0.pinned = true; $0.scenario = .sessionsWorking; $0.selection = .session("k2"); $0.hoveredSession = "k1"
            $0.setup = { _, _, hub in hub.requestScroll("a:k2") }
        }
        // Scrolled to the end: the cue is the way back up. The last session of a focused list (it lists every one) is asked
        // for before the list exists, and the list answers it as it mounts; a test reads the cue off the hosted hub.
        shots += Shot.edges("focus-agents-sessions-end", on: .rightAndTop) {
            $0.pinned = true; $0.scenario = .sessionsManyNew; $0.focus = .agents
            $0.setup = { store, _, hub in
                if let last = store.listedGroups(expanded: true).groups.flatMap(\.rows).last { hub.requestScroll("a:" + last.id) }
            }
        }
        // Hiding a session offers its undo, which the list's room leaves out: on a 720pt screen the focused list and a peek both stay within it.
        let hide: (Store, UIState, HubState) -> Void = { store, _, _ in
            if let row = store.listedGroups(expanded: true).groups.flatMap(\.rows).last(where: { !$0.isWaiting }) { store.dismissAgent(row.id) }
        }
        shots += Shot.edges("focus-agents-sessions-undo-720", on: .rightAndTop) {
            $0.pinned = true; $0.scenario = .sessions12; $0.focus = .agents; $0.size = Shot.hd; $0.setup = hide
        }
        shots += Shot.edges("peek-agents-sessions-undo-720", on: .rightAndTop) {
            $0.section = .agents; $0.scenario = .sessions12; $0.size = Shot.hd; $0.setup = hide
        }
        // A short screen (a 560pt hub on the sides): the inbox keeps a row beside the sessions' share.
        shots += Shot.edges("open-sessions-12-short", on: [.right]) { $0.pinned = true; $0.scenario = .sessions12; $0.size = CGSize(width: 1280, height: 650) }
        // The whole list with its "+3 more" picked: a screen tall enough for it.
        shots += Shot.edges("focus-agents-sessions-more", on: .rightAndTop) {
            $0.pinned = true; $0.scenario = .sessionsManyNew; $0.focus = .agents; $0.size = CGSize(width: 1280, height: 1500)
            $0.setup = { _, _, hub in hub.selection = "s:more" }
        }
        return shots
    }()

    /// Every shot, in the order they are rendered. One line each.
    static let catalog: [Shot] = [
        // The baseline.
        Shot.edges("rest"),
        Shot.edges("open") { $0.pinned = true },
        Shot.edges("settings") { $0.pinned = true; $0.page = .settings },
        Shot.edges("repos", on: .rightAndTop) { $0.pinned = true; $0.page = .repos },
        Shot.edges("search") { $0.pinned = true; $0.query = "sand" },
        // A page over a search: the query stays, and the bar is as bright as ever.
        Shot.edges("settings-search", on: .rightAndTop) { $0.pinned = true; $0.page = .settings; $0.query = "sand" },
        Shot.edges("tip", on: .rightAndTop) { $0.pinned = true; $0.tip = "Settings" },
        Shot.edges("peek-inbox") { $0.section = .inbox },
        Shot.edges("peek-ci") { $0.section = .ci },
        Shot.edges("peek-agents") { $0.section = .agents },
        Shot.edges("peek-controls") { $0.section = .controls },
        // A row under the pointer in the sessions' peek lights its tile in the bar (and the other way round).
        Shot.edges("peek-agents-hover", on: .rightAndTop) { $0.section = .agents; $0.hoveredSession = "local_demo-ci" },
        // Asked for by VoiceOver or a key: the first row is picked and the keys walk the rows.
        Shot.edges("peek-controls-keys", on: .rightAndTop) { $0.section = .controls; $0.setup = { _, _, hub in hub.menuKeys = true } },
        // An inbox item and a session picked, their actions showing, to compare them.
        Shot.edges("picked", on: [.right, .left, .top]) { $0.pinned = true; $0.selection = .firstNeedsYou; $0.hoveredSession = "local_demo-ci" },
        Shot.edges("focus-inbox", on: .rightAndTop) { $0.pinned = true; $0.focus = .inbox },
        Shot.edges("focus-agents", on: [.right, .left, .top]) { $0.pinned = true; $0.focus = .agents },
        // Inbox.
        Shot.edges("open-bots", on: .rightAndTop) { $0.pinned = true; $0.filter = .bots },
        Shot.edges("open-done", on: .rightAndTop) { $0.pinned = true; $0.filter = .done },
        Shot.edges("search-none", on: .rightAndTop) { $0.pinned = true; $0.query = "zzzz" },
        Shot.edges("search-sessions", on: .rightAndTop) { $0.pinned = true; $0.query = "lcu" },
        Shot.edges("focus-ci", on: [.right, .left, .top]) { $0.pinned = true; $0.focus = .ci },
        // Causes: why a list is empty or the sync is not healthy.
        causes.flatMap { slug, scenario in scenarioShots(slug, scenario) },
        Shot.edges("open-no-repos", on: .rightAndTop) { $0.pinned = true; $0.scenario = .empty },
        Shot.edges("open-bots-empty", on: .rightAndTop) { $0.pinned = true; $0.scenario = .botsEmpty; $0.filter = .bots },
        Shot.edges("open-done-empty", on: .rightAndTop) { $0.pinned = true; $0.scenario = .doneEmpty; $0.filter = .done },
        // CI, sessions and the update cell.
        ci.flatMap { slug, scenario in scenarioShots(slug, scenario, peek: .ci) },
        // No CI has no cell on the strip to hover, so its peek is the side bar's only (and it isn't in `ci`, whose peeks
        // are on both).
        scenarioShots("no-ci", .noCI),
        Shot.edges("peek-ci-no-ci", on: [.right]) { $0.section = .ci; $0.scenario = .noCI },
        // The calm CI states, kept open where the block is short beside a taller column (the strip's other edge).
        Shot.edges("open-all-passing", on: [.bottom]) { $0.pinned = true; $0.scenario = .allPassing },
        Shot.edges("open-no-ci", on: [.bottom]) { $0.pinned = true; $0.scenario = .noCI },
        Shot.edges("focus-ci-many-ci", on: .rightAndTop) { $0.pinned = true; $0.scenario = .manyCI; $0.focus = .ci },
        // CI rows: Passing open in place, a row picked, a muted repo, stale data, Increase Contrast.
        Shot.edges("open-ci-passing-open", on: .rightAndTop) { $0.pinned = true; $0.setup = { _, _, hub in hub.ciPassingOpen = true } },
        // The bar's CI cell names the repository a click opens.
        Shot.edges("rest-ci-tip", on: .all) { $0.tip = "CI" },
        Shot.edges("open-ci-picked", on: .rightAndTop) { $0.pinned = true; $0.setup = { _, _, hub in hub.selection = "c:apple/swift-format" } },
        Shot.edges("open-ci-muted", on: .rightAndTop) {
            $0.pinned = true
            $0.scenario = .manyCI
            $0.setup = { store, _, hub in
                if let vapor = store.repos.first(where: { $0.fullName == "vapor/vapor" }) { store.muteCI(vapor) }
                hub.ciPassingOpen = true
            }
        },
        // Stale: the last answers for CI are old, whatever the last (failed) poll says.
        Shot.edges("open-ci-stale", on: .rightAndTop) {
            $0.pinned = true
            $0.setup = { store, _, _ in
                for key in store.ci.keys { store.ci[key]?.checkedAt = Date().addingTimeInterval(-3 * 3600) }
                store.lastSync = Date()
            }
        },
        // Muting offers an undo line in the CI section.
        Shot.edges("open-ci-mute-undo", on: .rightAndTop) {
            $0.pinned = true
            $0.setup = { store, _, _ in
                if let repo = store.repos.first(where: { $0.fullName == "apple/swift-format" }) { store.muteCI(repo) }
            }
        },
        // Stopping CI on the last repository that had it: the undo line is all the section has to say.
        Shot.edges("open-ci-stop-undo", on: .rightAndTop) {
            $0.pinned = true
            $0.setup = { store, _, _ in
                for repo in store.repos.filter({ $0.events.contains(.ciMain) }) { store.stopShowingCI(repo) }
            }
        },
        Shot.edges("open-ci-contrast", on: .rightAndTop) {
            $0.pinned = true
            $0.environment = .contrast
            $0.setup = { _, _, hub in hub.selection = "c:apple/swift-format" }
        },
        Shot.edges("open-ci-many-ci-720", on: .rightAndTop) { $0.pinned = true; $0.scenario = .manyCI; $0.size = Shot.hd },
        // Fifteen failing repositories on a 720 pt screen: the list scrolls, nothing overflows.
        Shot.edges("open-ci-failing-15-720", on: .rightAndTop) {
            $0.pinned = true
            $0.scenario = .manyCI
            $0.size = Shot.hd
            $0.setup = { store, _, _ in
                for key in store.ci.keys { store.ci[key]?.state = .failure; store.ci[key]?.failing = ["Linux / build"] }
            }
        },
        sessions.flatMap { slug, scenario in scenarioShots(slug, scenario, peek: .agents) },
        sessionShots,
        updates.flatMap { slug, scenario in scenarioShots(slug, scenario) },
        // Accessibility variants.
        Shot.edges("rest-contrast") { $0.environment = .contrast },
        Shot.edges("rest-reduce-motion") { $0.environment = .motion },
        Shot.edges("rest-differentiate") { $0.environment = .differentiate },
        Shot.edges("rest-a11y") { $0.environment = .all },
        Shot.edges("open-contrast", on: .rightAndTop) { $0.pinned = true; $0.environment = .contrast },
        Shot.edges("open-reduce-motion", on: .rightAndTop) { $0.pinned = true; $0.environment = .motion },
        Shot.edges("open-differentiate", on: .rightAndTop) { $0.pinned = true; $0.environment = .differentiate },
        Shot.edges("picked-contrast", on: .rightAndTop) {
            $0.pinned = true; $0.selection = .firstNeedsYou; $0.hoveredSession = "local_demo-ci"; $0.environment = .contrast
        },
        Shot.edges("settings-contrast", on: .rightAndTop) { $0.pinned = true; $0.page = .settings; $0.environment = .contrast },
        // The bar beside a page: the same cells, undimmed, the gear lit and still badged.
        Shot.edges("settings-sync-fault", on: .rightAndTop) { $0.pinned = true; $0.page = .settings; $0.scenario = .syncFault },
        Shot.edges("settings-review-requests-cut", on: .rightAndTop) { $0.pinned = true; $0.page = .settings; $0.scenario = .reviewRequestsCut },
        // The shared components, each in its states.
        [Shot(name: "components", sheet: .components), Shot(name: "components-contrast", sheet: .components, environment: .contrast)],
        // The working ring.
        [Shot(name: "rings", sheet: .rings, size: Shot.rings), Shot(name: "rings-contrast", sheet: .rings, size: Shot.rings, environment: .contrast)],
        // Where the bar rests, rest beside kept open: low on the sides it must not move; along the top and bottom a
        // strip too near the end is moved by the least, and a centred one keeps its leading edge.
        Shot.edges("rest-low", on: .sides) { $0.position = 0.7 },
        Shot.edges("open-low", on: .sides) { $0.pinned = true; $0.position = 0.7 },
        Shot.edges("rest-clamped", on: .strips) { $0.position = 0.9 },
        Shot.edges("open-clamped", on: .strips) { $0.pinned = true; $0.position = 0.9 },
        Shot.edges("rest-centred", on: .strips) { $0.position = 0.5 },
        Shot.edges("open-centred", on: .strips) { $0.pinned = true; $0.position = 0.5 },
        // A 1280×720 screen.
        Shot.edges("open-720") { $0.pinned = true; $0.size = Shot.hd },
        Shot.edges("settings-720") { $0.pinned = true; $0.page = .settings; $0.size = Shot.hd },
        Shot.edges("repos-720") { $0.pinned = true; $0.page = .repos; $0.size = Shot.hd },
        Shot.edges("rest-sessions-12-720") { $0.scenario = .sessions12; $0.size = Shot.hd },
        // The inbox: each tab, why it is empty, search, the undo line, a picked row.
        Shot.edges("inbox-needs-you", on: .rightAndTop) { $0.pinned = true },
        Shot.edges("inbox-bots", on: .rightAndTop) { $0.pinned = true; $0.filter = .bots },
        Shot.edges("inbox-done", on: .rightAndTop) { $0.pinned = true; $0.filter = .done },
        inboxCauses.flatMap { slug, scenario, filter in
            Shot.edges("inbox-\(slug)", on: .rightAndTop) { $0.pinned = true; $0.scenario = scenario; $0.filter = filter }
        },
        Shot.edges("inbox-search-open", on: .rightAndTop) { $0.pinned = true; $0.setup = { _, _, hub in hub.inbox.startSearch() } },
        Shot.edges("inbox-search", on: .rightAndTop) { $0.pinned = true; $0.query = "format" },
        Shot.edges("inbox-search-none", on: .rightAndTop) { $0.pinned = true; $0.query = "zzzz" },
        // Both groups with results: Inbox and Sessions each under their count, CI out of the layout.
        Shot.edges("inbox-search-sessions", on: .rightAndTop) { $0.pinned = true; $0.query = "notifications" },
        // Only sessions match: the Inbox group says so, instead of leaving a blank.
        Shot.edges("inbox-search-sessions-only", on: .rightAndTop) { $0.pinned = true; $0.query = "ci" },
        // Search started from a focused CI section: the focus is given up so the field and both result groups show.
        Shot.edges("inbox-search-from-focus", on: .rightAndTop) {
            $0.pinned = true
            $0.focus = .ci
            $0.query = "format"
            $0.afterOpen = { _, _, hub in hub.beginSearch() }
        },
        // Sessions focused while searching: the inbox is only its header, and the search field its sessions are filtered by stays.
        Shot.edges("inbox-search-focus-agents", on: .rightAndTop) { $0.pinned = true; $0.focus = .agents; $0.query = "lcu" },
        // The same with nothing found: no Sessions, and no inbox body to say so, so the field's summary does.
        Shot.edges("inbox-search-focus-agents-none", on: .rightAndTop) { $0.pinned = true; $0.focus = .agents; $0.query = "zzzz" },
        Shot.edges("inbox-undo", on: .rightAndTop) {
            $0.pinned = true
            $0.setup = { store, _, _ in if let first = store.list(.needsYou).first { store.done(first) } }
        },
        Shot.edges("inbox-undo-all", on: .rightAndTop) { $0.pinned = true; $0.setup = { store, _, _ in store.doneAllRead(.needsYou) } },
        Shot.edges("inbox-picked", on: .rightAndTop) { $0.pinned = true; $0.selection = .firstNeedsYou },
        Shot.edges("inbox-picked-done", on: .rightAndTop) {
            $0.pinned = true
            $0.filter = .done
            $0.setup = { store, _, hub in hub.selection = store.list(.done).first.map { "i:" + $0.id } }
        },
        // The longest meta lines on the Done tab, the first picked: the action has its own room, nothing under it is cut.
        Shot.edges("inbox-picked-done-long", on: .rightAndTop) {
            $0.pinned = true
            $0.filter = .done
            $0.setup = { store, _, hub in
                func row(_ id: String, _ author: String, _ state: ItemState, minutes: Double) -> InboxItem {
                    var item = InboxItem(id: id, repo: "apple/swift-format", kind: .reviewComment, number: 1042,
                                         title: "Respect trailing comma config in collection literals", snippet: "", author: author,
                                         avatar: nil, authorIsApp: author.hasSuffix("[bot]"), url: URL(string: "https://github.com/apple/swift-format/pull/1042")!,
                                         createdAt: Date().addingTimeInterval(-3600), state: state)
                    item.clearedAt = Date().addingTimeInterval(-minutes * 60)
                    return item
                }
                store.items += [row("long-1", "coderabbitai[bot]", .resolved, minutes: 1), row("long-2", "coderabbitai[bot]", .discarded, minutes: 2),
                                row("long-3", "jessesquires-the-long-named", .addressed, minutes: 3)]
                hub.selection = "i:long-1"
            }
        },
        // More rows than fit: the last whole row, then "+N more".
        Shot.edges("inbox-many", on: .rightAndTop) { $0.pinned = true; $0.scenario = .inboxMany },
        Shot.edges("inbox-peek-many", on: .rightAndTop) { $0.section = .inbox; $0.scenario = .inboxMany },
        Shot.edges("inbox-peek", on: .rightAndTop) { $0.section = .inbox },
        Shot.edges("inbox-peek-done", on: .rightAndTop) { $0.section = .inbox; $0.filter = .done },
        Shot.edges("inbox-focus", on: .rightAndTop) { $0.pinned = true; $0.focus = .inbox },
        // The one column along the top, on a wide screen and with a banner and an undo line taking height from the list.
        Shot.edges("inbox-focus-wide", on: [.top]) {
            $0.pinned = true; $0.focus = .inbox; $0.scenario = .inboxMany; $0.size = CGSize(width: 2400, height: 820)
        },
        Shot.edges("inbox-focus-banner-undo", on: [.top]) {
            $0.pinned = true; $0.focus = .inbox; $0.scenario = .inboxMany
            $0.setup = { store, _, _ in
                store.repoErrors = ["ziglang/zig": "Not found (or no access)"]
                if let first = store.list(.needsYou).first { store.done(first) }
            }
        },
        Shot.edges("inbox-contrast", on: .rightAndTop) {
            $0.pinned = true; $0.selection = .firstNeedsYou; $0.environment = .contrast
        },
        Shot.edges("inbox-differentiate", on: .rightAndTop) { $0.pinned = true; $0.environment = .differentiate },
        Shot.edges("inbox-done-contrast", on: .rightAndTop) { $0.pinned = true; $0.filter = .done; $0.environment = .contrast },
        Shot.edges("inbox-caught-up-contrast", on: .rightAndTop) {
            $0.pinned = true; $0.scenario = .needsYouEmpty; $0.environment = .contrast
        },
        // More waiting than the screen has room for: the bar keeps Update and the gear, a "+N" holds the rest.
        Shot.edges("rest-sessions-waiting-20-720", on: .rightAndTop) { $0.scenario = .sessionsWaiting20; $0.size = Shot.hd },
        Shot.edges("peek-agents-sessions-waiting-20-720", on: .rightAndTop) {
            $0.scenario = .sessionsWaiting20; $0.section = .agents; $0.size = Shot.hd
        },
        // Twelve new activity with the oldest waiting: the "+4" (and its row) opens the sessions with New activity expanded and
        // the first it stood for picked (focused here, so the list is tall enough to show it).
        Shot.edges("rest-sessions-pending-12", on: .rightAndTop) { $0.scenario = .sessionsPending12 },
        Shot.edges("focus-agents-sessions-pending-12-more", on: .rightAndTop) {
            $0.pinned = true; $0.scenario = .sessionsPending12; $0.focus = .agents
            $0.setup = { store, ui, hub in
                let hidden = BarSessions.arrange(store.barSlots, frozen: nil).hidden
                hub.showSession(hidden.first?.id, store: store, ui: ui, listingAll: true)
                hub.focus = .agents
            }
        },
        // The pointer holds the bar's order while the twelfth session starts to wait: its tile, and its row, take the eighth's
        // place, so the "+4" and the cells after it stay where they were.
        Shot.edges("peek-agents-sessions-late-waiting", on: .rightAndTop) {
            $0.scenario = .sessionsLateWaiting; $0.section = .agents
            $0.setup = { store, _, hub in hub.frozenSessions = Demo.lateWaiting(store) }
        },
        // Settings, one pane each (General is `right-settings`), and Repositories in each of its states.
        page("settings-token", .settings) { $0.preview.revealsToken = true },
        page("settings-notifications", .settings) { $0.preview.pane = .notifications },
        page("settings-notifications-blocked", .settings) { $0.preview.pane = .notifications; $0.preview.notificationsBlocked = true },
        page("settings-notifications-snoozed", .settings) { $0.preview.pane = .notifications; $0.scenario = .snoozed },
        page("settings-shortcuts", .settings) { $0.preview.pane = .shortcuts },
        page("settings-shortcuts-notice", .settings) {
            $0.preview.pane = .shortcuts; $0.preview.accessibilityTrusted = false
            $0.setup = { store, _, _ in
                store.settings.shortcuts = [ShortcutAction.togglePanel.rawValue: Shortcut(keyCode: 54),
                                            ShortcutAction.markAllRead.rawValue: .unassigned]
            }
        },
        page("settings-claude", .settings) { $0.preview.pane = .claude },
        page("settings-claude-off", .settings) { $0.preview.pane = .claude; $0.scenario = .busy },
        // The states of Settings that the dev build and a healthy account never show.
        page("settings-signed-out", .settings) { $0.scenario = .signedOut },
        page("settings-offline", .settings) { $0.scenario = .offline },
        page("settings-launch-error", .settings) { $0.preview.launchError = "The operation couldn't be completed. Operation not permitted" },
        page("settings-update-idle", .settings) { $0.setup = updater(.idle) },
        page("settings-update-available", .settings) { $0.setup = updater(.available) },
        page("settings-update-downloading", .settings) { $0.setup = updater(.downloading, fraction: 0.42) },
        page("settings-update-ready", .settings) { $0.setup = updater(.ready) },
        page("settings-update-failed", .settings) { $0.setup = updater(.failed("Couldn't verify the download: the checksum doesn't match")) },
        page("settings-notifications-off", .settings) {
            $0.preview.pane = .notifications
            $0.setup = { store, _, _ in store.settings.notifications = false }
        },
        page("settings-shortcuts-recording", .settings) {
            $0.preview.pane = .shortcuts; $0.preview.accessibilityTrusted = true; $0.preview.recording = .togglePanel
        },
        page("settings-shortcuts-conflict", .settings) {
            $0.preview.pane = .shortcuts; $0.preview.accessibilityTrusted = true
            $0.preview.recording = .openItem; $0.preview.recorderError = "Already used by Mark read / unread"
        },
        page("settings-shortcuts-held", .settings) {
            $0.preview.pane = .shortcuts; $0.preview.accessibilityTrusted = true
            $0.setup = { store, _, _ in store.refusedShortcuts[.togglePanel] = store.shortcut(.togglePanel) }
        },
        page("settings-shortcuts-restore-refused", .settings) {
            $0.preview.pane = .shortcuts; $0.preview.accessibilityTrusted = true
            $0.preview.restoreError = "⌃⌥L is used by another app. Lookout keeps your shortcuts"
            $0.setup = { store, _, _ in
                store.settings.shortcuts = [ShortcutAction.togglePanel.rawValue: Shortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .command])]
            }
        },
        page("settings-claude-missing", .settings) { $0.preview.pane = .claude; $0.scenario = .busy; $0.preview.claudeInstalled = false },
        page("settings-claude-key-saved", .settings) {
            $0.preview.pane = .claude
            $0.setup = { store, _, _ in
                store.hasTypesafeKey = true
                store.agents.iconsEnabled = true
            }
        },
        page("repos-retry-focus", .repos) { $0.scenario = .reposFailed; $0.preview.retryFocused = "ziglang/zig" },
        page("repos-drop", .repos) { $0.preview.dropTarget = "ziglang/zig" },
        page("repos-custom", .repos) { $0.preview.expandedRepo = "ziglang/zig" },
        // Names too long for the line beside the controls take a line of their own.
        page("repos-long-names", .repos) {
            $0.setup = { store, _, _ in
                store.repos.append(contentsOf: ["pointfreeco/swift-composable-architecture", "superradiantlabs/sandbox-runtime-images"]
                    .map { RepoConfig(fullName: $0) })
            }
        },
        page("repos-failure", .repos) { $0.scenario = .reposFailed },
        page("repos-add", .repos) { $0.preview.addQuery = "swift"; $0.preview.addHighlight = 1 },
        page("repos-add-error", .repos) {
            $0.preview.addQuery = "swift"; $0.preview.addError = "Not Found"
            // The suggestion that was picked, not the text it was found with.
            $0.preview.addSubmitted = "apple/swift-nio"
        },
        page("repos-undo", .repos) {
            // Moved to Only what's for me: the comments that were not for you are gone, and the line says so.
            $0.setup = { store, _, _ in
                store.undoStack.announce = { _ in }
                if let repo = store.repos.first(where: { $0.fullName == "0xpolarzero/lookout" }) {
                    store.items.append(contentsOf: (0..<3).map { n in
                        var item = InboxItem(id: "not-for-me-\(n)", repo: repo.fullName, kind: .issueComment, number: 40 + n, title: "Idea", snippet: "",
                                             author: "someone", avatar: nil, authorIsApp: false, url: repo.url, createdAt: Date(), state: .unread)
                        item.forYou = false
                        return item
                    })
                    store.changePreset(.forMe, on: repo)
                }
            }
        },
        page("repos-add-none", .repos) { $0.preview.addQuery = "zzzz" },
        page("repos-empty", .repos) { $0.scenario = .empty },
        page("repos-contrast", .repos) { $0.preview.expandedRepo = "ziglang/zig"; $0.environment = .contrast },
        // The chrome on a 1280×720 screen: every peek, a focused section and the fullest views, on every edge.
        Shot.edges("peek-inbox-720") { $0.section = .inbox; $0.size = Shot.hd },
        Shot.edges("peek-ci-720") { $0.section = .ci; $0.size = Shot.hd },
        Shot.edges("peek-ci-many-ci-720") { $0.section = .ci; $0.scenario = .manyCI; $0.size = Shot.hd },
        Shot.edges("peek-agents-720") { $0.section = .agents; $0.scenario = .sessions12; $0.size = Shot.hd },
        // A session whose tile is in the bar but whose row the cut left out: hovering it lists it, at the cost of the last row.
        Shot.edges("peek-agents-hover-cut-720", on: .rightAndTop) {
            $0.section = .agents; $0.scenario = .sessions12; $0.size = Shot.hd; $0.hoveredSession = "t4"
        },
        Shot.edges("peek-controls-720") { $0.section = .controls; $0.size = Shot.hd },
        Shot.edges("focus-inbox-720") { $0.pinned = true; $0.focus = .inbox; $0.size = Shot.hd },
        // A bar low on the edge, with little room below its cells: each peek keeps whole rows, "+N more" and the screen.
        Shot.edges("peek-ci-low-720", on: .sides) { $0.section = .ci; $0.scenario = .allPassing; $0.position = 0.9; $0.size = Shot.hd; $0.setup = { store, _, _ in store.agents.enabled = false } },
        Shot.edges("peek-inbox-low-720", on: .sides) { $0.section = .inbox; $0.position = 0.9; $0.size = Shot.hd },
        Shot.edges("peek-agents-low-720", on: .sides) { $0.section = .agents; $0.position = 0.9; $0.scenario = .sessions12; $0.size = Shot.hd },
        // Nearly nothing below the bar: the hub keeps the screen's end as its own, CI folds to its header and the lists scroll.
        Shot.edges("open-low-sessions-off-720", on: .sides) {
            $0.pinned = true; $0.position = 0.8; $0.size = Shot.hd; $0.setup = { store, _, _ in store.agents.enabled = false }
        },
        Shot.edges("open-low-no-ci-720", on: .sides) {
            $0.pinned = true; $0.position = 0.8; $0.scenario = .noCI; $0.size = Shot.hd; $0.setup = { store, _, _ in store.agents.enabled = false }
        },
        Shot.edges("open-sessions-12-720") { $0.pinned = true; $0.scenario = .sessions12; $0.size = Shot.hd },
        Shot.edges("open-many-ci-720") { $0.pinned = true; $0.scenario = .manyCI; $0.size = Shot.hd },
    ].flatMap { $0 }

    /// A page kept open on the right edge, named `name`.
    private static func page(_ name: String, _ page: HubPage, _ configure: (inout Shot) -> Void) -> [Shot] {
        Shot.edges(name, on: [.right]) { $0.pinned = true; $0.page = page; configure(&$0) }
    }

    /// The updater in a phase (a release, as the dev build is never one).
    private static func updater(_ phase: Updater.Phase, fraction: Double = 0) -> (Store, UIState, HubState) -> Void {
        { store, _, _ in store.updater.preview(phase, version: "0.5.0", fraction: fraction) }
    }

    /// A scenario at rest on every edge, open and (when it has a section) as that section's peek on right and top.
    private static func scenarioShots(_ slug: String, _ scenario: Demo.Scenario, peek: HubSection? = nil) -> [Shot] {
        Shot.edges("rest-\(slug)") { $0.scenario = scenario }
            + Shot.edges("open-\(slug)", on: .rightAndTop) { $0.pinned = true; $0.scenario = scenario }
            + (peek.map { section in
                Shot.edges("peek-\(section == .ci ? "ci" : "agents")-\(slug)", on: .rightAndTop) { $0.section = section; $0.scenario = scenario }
            } ?? [])
    }

    /// `--playground-shots <dir> [substring…]`.
    static func run(to dir: String) {
        let arguments = CommandLine.arguments
        let start = (arguments.firstIndex(of: "--playground-shots") ?? 0) + 2
        let filters = arguments.dropFirst(start).filter { !$0.hasPrefix("--") }.map { $0.lowercased() }
        let shots = catalog.filter { shot in filters.isEmpty || filters.contains { shot.name.contains($0) } }
        guard !shots.isEmpty else {
            print("No shot matches \(filters.joined(separator: ", ")). \(catalog.count) shots, e.g. \(catalog[0].name)")
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task {
            // Some at a time: every window is a live SwiftUI hierarchy, and a full set is too much to hold at once.
            for batch in stride(from: 0, to: shots.count, by: 10).map({ Array(shots[$0..<min($0 + 10, shots.count)]) }) {
                let windows = batch.map { (name: $0.name, shown: open($0)) }
                // As in the app, the bar rests (and is measured) before anything opens from it.
                try? await Task.sleep(for: .seconds(0.8))
                windows.forEach { $0.shown.open() }
                try? await Task.sleep(for: .seconds(2))
                for (name, shown) in windows {
                    capture(shown.window, to: "\(dir)/\(name).png")
                    shown.window.close()
                }
            }
            print("\(shots.count) shots in \(dir)")
            exit(0)
        }
    }

    /// The shot's window, offscreen and showing the bar at rest, and what opens it (kept open, a page, a focused section).
    private static func open(_ shot: Shot) -> (window: NSWindow, open: () -> Void) {
        let store = Store()
        Demo.populate(store, shot.scenario)
        store.agents.expanded = true
        let ui = UIState(persists: false, edge: shot.edge)
        ui.position = shot.position
        let hub = HubState()
        hub.query = shot.query
        hub.section = shot.section
        if let filter = shot.filter { hub.filter = filter }
        switch shot.selection {
        case .firstNeedsYou: hub.selection = store.list(.needsYou).first.map { "i:" + $0.id }
        case .session(let id): hub.selection = "a:" + id
        case nil: break
        }
        ui.drawerSelection = shot.hoveredSession
        shot.setup?(store, ui, hub)
        let content: AnyView
        switch shot.sheet {
        case .components: content = AnyView(ComponentSheet())
        case .rings: content = AnyView(MotionSheet())
        case nil:
            content = AnyView(PlaygroundView(store: store, ui: ui, hub: hub, showsExplainer: shot.showsExplainer, minSize: shot.size)
                .environment(\.previewTip, shot.tip)
                .environment(\.pagePreview, shot.preview))
        }
        let root = content
            .shotEnvironment(shot.environment)
            .frame(width: shot.size.width, height: shot.size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame.size = NSSize(width: shot.size.width, height: shot.size.height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        return (window, {
            if let pane = shot.preview.pane { hub.settingsPane = pane }
            hub.pinned = shot.pinned; hub.page = shot.page; hub.focus = shot.focus
            shot.afterOpen?(store, ui, hub)
        })
    }

    /// What the window shows, as pixels (tests read them too).
    static func bitmap(of window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func capture(_ window: NSWindow, to path: String) {
        try? bitmap(of: window)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// One shot as pixels, for the tests that measure what the views draw (its window is closed again).
    static func render(_ shot: Shot) async -> NSBitmapImageRep? {
        let shown = open(shot)
        defer { shown.window.close() }
        // As in the app: the bar rests before anything opens from it.
        try? await Task.sleep(for: .seconds(0.8))
        shown.open()
        try? await Task.sleep(for: .seconds(1.5))
        return bitmap(of: shown.window)
    }
}


// MARK: - Component sheet

/// The shared components laid out in their states, on the hub's surface: what the `components` shots render, so a
/// component can be reviewed (and guarded against clipping) before a surface adopts it. States a pointer or the
/// keyboard would put a control in are drawn through the same fills and rings the controls use.
private struct ComponentSheet: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) { rows; fills; controls; tabs; forms }
            VStack(alignment: .leading, spacing: 12) { headers; pageHeaders; banners; empties; undo }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
        .themeResolved()
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.Typography.label).foregroundStyle(Theme.secondary)
            content()
        }
        .frame(width: 440, alignment: .leading)
    }

    private func line(_ title: String, _ meta: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.Typography.title).foregroundStyle(Theme.text)
            Text(meta).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.Metrics.twoLineRow - 12)
    }

    private var rows: some View {
        group("Row: rest, hover, picked") {
            line("Rest", "owner/repo#1 · Review comment").rowHighlight(hover: false)
            line("Hover", "Fill.hover, pointer only").rowHighlight(hover: true)
            line("Picked", "Fill.selected and the accent bar").rowHighlight(hover: false, picked: true)
        }
    }

    private var fills: some View {
        group("Fills, and a repository badge on each of its tints") {
            HStack(spacing: Theme.Space.md) {
                FillSwatch(name: "hover", fill: Theme.Fill.hover)
                FillSwatch(name: "field", fill: Theme.Fill.field)
                FillSwatch(name: "tile", fill: Theme.Fill.tile)
                FillSwatch(name: "selected", fill: Theme.Fill.selected)
                FillSwatch(name: "pressed", fill: Theme.Fill.pressed)
                FillSwatch(name: "group", fill: Theme.Fill.group)
            }
            HStack(spacing: Theme.Space.md) {
                BadgeSwatch(name: "rest", level: .rest)
                BadgeSwatch(name: "hover", level: .hover)
                BadgeSwatch(name: "pressed", level: .pressed)
            }
        }
    }

    private var controls: some View {
        group("Buttons, keys, menu row, focus ring") {
            HStack(spacing: Theme.Space.lg) {
                BorderedButton("Retry") {}
                IconButton(symbol: "magnifyingglass", help: "Search") {}
                IconButton(symbol: "pin.fill", help: "Keep open", active: true) {}
                KeyCap("esc")
                Image(systemName: "gearshape").font(Theme.Typography.glyph(14, .medium)).foregroundStyle(Theme.secondary)
                    .tile(Theme.Metrics.tile).focusRing(Theme.Radius.tile, isFocused: true)
            }
            .padding(Theme.Space.xs)
            MenuRow(symbol: "pin", title: "Keep open", key: "⌃⌥L") {}
            MenuRow(symbol: "gearshape", title: "Settings…", key: "⌘,") {}
            MenuRow(symbol: "books.vertical", title: "Repositories… (picked)", key: nil, picked: true) {}
        }
    }

    private var tabs: some View {
        group("Tabs") {
            Tabs(label: "Inbox filter", tabs: [
                .init(id: 0, title: "Needs you", count: 5, countTint: AnyShapeStyle(Theme.amber)),
                .init(id: 1, title: "Bots", count: 12),
                .init(id: 2, title: "Done"),
            ], selection: 0) { _ in }
        }
    }

    private var forms: some View {
        group("Switch and checkbox (on, off, disabled) and field (rest, focused)") {
            VStack(spacing: 0) {
                Toggle("Launch at login", isOn: .constant(true))
                Toggle("Desktop notifications", isOn: .constant(false))
                Toggle("Review requests", isOn: .constant(true)).disabled(true)
            }
            .toggleStyle(SwitchStyle())
            .font(Theme.Typography.body).foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Metrics.contentEdge - Theme.Metrics.inset)
            .background(Theme.Radius.shape(Theme.Radius.row).fill(Theme.Fill.group))
            VStack(spacing: 0) {
                Toggle("Pull request comments", isOn: .constant(true))
                Toggle("Issue comments", isOn: .constant(false))
                Toggle("Every comment, not only the ones for me", isOn: .constant(false)).disabled(true)
            }
            .toggleStyle(CheckboxStyle())
            .font(Theme.Typography.body).foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Metrics.contentEdge)
            HStack(spacing: Theme.Space.md) {
                TextField("owner/repo or GitHub URL", text: .constant("")).fieldStyle()
                TextField("Search", text: .constant("zig")).fieldStyle(focused: true)
            }
        }
    }

    private var headers: some View {
        group("Section header: plain, with a status, focused") {
            SectionHeader(title: "Inbox", onFocus: {}) { IconButton(symbol: "magnifyingglass", help: "Search") {} }
            SectionHeader(title: "Sessions", status: ("1 waiting", AnyShapeStyle(Theme.amber)), onFocus: {}) { EmptyView() }
            SectionHeader(title: "CI", status: ("1 failing", AnyShapeStyle(Theme.red)), focused: true, onFocus: {}) { EmptyView() }
        }
    }

    /// The page header's slot: a title, and Settings' four panes as tabs at the page's width, beside Done.
    private var pageHeaders: some View {
        group("Page header: a title, and the Settings panes in its slot") {
            PageHeader(closes: "Repositories", onDone: {}) { PageTitle("Repositories") }
            PageHeader(closes: "Settings", onDone: {}) {
                Tabs(label: "Settings pane", tabs: ["General", "Notifications", "Shortcuts", "Claude"].enumerated().map { Tabs.Tab(id: $0.offset, title: $0.element) },
                     selection: 1) { _ in }
            }
        }
    }

    private var banners: some View {
        group("Status banner: no button, one, two") {
            StatusBanner(symbol: "clock", message: "Snoozed until 14:30")
            StatusBanner(symbol: "exclamationmark.circle.fill", tint: AnyShapeStyle(Theme.amber), message: "2 repositories didn't sync") {
                BorderedButton("Retry") {}
            }
            StatusBanner(symbol: "exclamationmark.triangle.fill", tint: AnyShapeStyle(Theme.red), message: "Can't sign in to GitHub") {
                BorderedButton("Details") {}
                BorderedButton("Settings") {}
            }
        }
    }

    private var empties: some View {
        group("Empty block: two lines, with an action") {
            EmptyBlock("All caught up", detail: "Checked 2m ago").frame(height: Theme.Metrics.emptyBlock)
            EmptyBlock(title: "Nothing watched yet", detail: "Add a repository to start.") { BorderedButton("Add a repository") {} }
                .frame(height: Theme.Metrics.emptyBlock)
        }
    }

    private var undo: some View {
        group("Undo line") {
            UndoLine(message: "Moved to Done") {}
        }
    }
}

/// A fill token on a tile, named, as the views draw it (`resolved.fill`).
private struct FillSwatch: View {
    let name: String
    let fill: Color
    @Environment(\.resolved) private var resolved

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            Theme.Radius.shape(Theme.Radius.tile).fill(resolved.fill(fill)).frame(width: 48, height: Theme.Metrics.tile)
            Text(name).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
        }
    }
}

/// An enabled repository badge's glyph on one tint of its own hue, as `BadgeLabel` draws it.
private struct BadgeSwatch: View {
    let name: String
    let level: Theme.Fill.Tint
    @Environment(\.resolved) private var resolved

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "bubble.left.and.bubble.right.fill").font(Theme.Typography.glyph(10.5)).foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Theme.Radius.shape(Theme.Radius.tile).fill(resolved.fill(Theme.Fill.tint(Theme.accent, level))))
            Text(name).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
        }
        .frame(width: 100, alignment: .leading)
    }
}
