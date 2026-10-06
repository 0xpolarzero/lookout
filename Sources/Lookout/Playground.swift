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
            HStack(spacing: 10) {
                Label(hub.pinned ? "Pinned" : "Not pinned", systemImage: hub.pinned ? "pin.fill" : "pin")
            }
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
    /// The side bar and the strip: where a state differs between them, and the two the old shots covered.
    static let rightAndTop: [DockEdge] = [.right, .top]
    static let sides: [DockEdge] = [.right, .left]
    static let strips: [DockEdge] = [.top, .bottom]
}

/// What a shot has picked, for the row actions and the keyboard pick to show.
enum ShotSelection {
    /// The newest inbox item that needs you.
    case firstNeedsYou
    case item(String)
    case session(String)
}

/// What a shot shows instead of the playground.
enum ShotSheet {
    /// The design system's components, each in its states (`ComponentSheet`).
    case components
}

/// One screenshot: the playground in a given state, rendered offscreen to `<name>.png`. Add one by adding a line to
/// `PlaygroundShots.catalog`; everything but `name` has a default.
struct Shot {
    static let standard = CGSize(width: 1280, height: 820)
    /// A 1280×720 screen: the hub must fit its edge without overflowing.
    static let hd = CGSize(width: 1280, height: 720)

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
    /// The playground's own "Lookout playground" card: hidden, as it is not part of what is being designed.
    var showsExplainer = false
    /// Anything the fields above don't cover, after they are applied.
    var setup: ((Store, UIState, HubState) -> Void)?

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
/// Names are `<edge>-<state>`, the edge being right, top, left or bottom. "Every edge" is all four; "right and
/// top" the two that stand for the sides and the strip.
///
/// Baseline, every edge
///   rest, open, settings, search, peek-inbox, peek-ci, peek-agents, peek-controls
/// Baseline, right and top
///   repos, tip, picked, focus-inbox, focus-agents
/// Inbox, right and top
///   open-bots, open-done, search-none, search-sessions, focus-ci
/// Causes, open on right and top; at rest on every edge (the bar's own state)
///   signed-out, repos-failed, rate-limited, snoozed, error, no-repos, needs-you-empty, bots-empty, done-empty,
///   first-sync, sync-fault (`rest-` for the others than bots-empty, done-empty and no-repos)
/// CI: `rest-`, `open-`, `peek-ci-`, `focus-ci-` plus
///   no-ci, all-passing, many-ci (15 repositories)
/// Sessions: `rest-`, `open-`, `peek-agents-` plus
///   sessions-waiting, sessions-working, sessions-unread, sessions-new-activity, sessions-scratch, sessions-none,
///   sessions-12 (also `focus-agents-sessions-12`)
/// Update: `rest-`, `open-` plus
///   update-available, update-downloading, update-ready
/// Accessibility (Increase Contrast, Reduce Motion, Differentiate Without Colour, all three as a11y; Differentiate
/// shows the waiting tile's outline, the one cue drawn so far)
///   rest-contrast, rest-reduce-motion, rest-differentiate, rest-a11y on every edge;
///   open-/picked-/settings-contrast, open-reduce-motion, open-differentiate on right and top
/// Components
///   components, components-contrast (each shared component in its states, no hub)
/// Position: `rest-`, `open-` plus
///   low (a third of the way down is not low: 0.7, on the sides), clamped (0.9) and centred (0.5), on the top and bottom
/// 1280×720, every edge
///   open-720, settings-720, repos-720, rest-sessions-12-720, peek-inbox-720, peek-ci-720, peek-agents-720,
///   peek-controls-720, focus-inbox-720, open-sessions-12-720, open-many-ci-720
@MainActor
enum PlaygroundShots {
    /// States of the data, as `(name, scenario)`; each is shown at rest, open and as a peek where it applies.
    private static let causes: [(String, Demo.Scenario)] = [
        ("signed-out", .signedOut), ("repos-failed", .reposFailed), ("rate-limited", .rateLimited), ("snoozed", .snoozed),
        ("error", .error), ("needs-you-empty", .needsYouEmpty), ("first-sync", .firstSync), ("sync-fault", .syncFault),
    ]
    private static let ci: [(String, Demo.Scenario)] = [("no-ci", .noCI), ("all-passing", .allPassing), ("many-ci", .manyCI)]
    private static let sessions: [(String, Demo.Scenario)] = [
        ("sessions-waiting", .sessionsWaiting), ("sessions-working", .sessionsWorking), ("sessions-unread", .sessionsUnread),
        ("sessions-new-activity", .sessionsNewActivity), ("sessions-scratch", .sessionsScratch),
        ("sessions-none", .sessionsNone), ("sessions-12", .sessions12),
    ]
    private static let updates: [(String, Demo.Scenario)] = [
        ("update-available", .updateAvailable), ("update-downloading", .updateDownloading), ("update-ready", .updateReady),
    ]

    /// Every shot, in the order they are rendered. One line each.
    static let catalog: [Shot] = [
        // The baseline.
        Shot.edges("rest"),
        Shot.edges("open") { $0.pinned = true },
        Shot.edges("settings") { $0.pinned = true; $0.page = .settings },
        Shot.edges("repos", on: .rightAndTop) { $0.pinned = true; $0.page = .repos },
        Shot.edges("search") { $0.pinned = true; $0.query = "sand" },
        Shot.edges("tip", on: .rightAndTop) { $0.pinned = true; $0.tip = "Settings" },
        Shot.edges("peek-inbox") { $0.section = .inbox },
        Shot.edges("peek-ci") { $0.section = .ci },
        Shot.edges("peek-agents") { $0.section = .agents },
        Shot.edges("peek-controls") { $0.section = .controls },
        // Asked for by VoiceOver or a key: the first row is picked and the keys walk the rows.
        Shot.edges("peek-controls-keys", on: .rightAndTop) { $0.section = .controls; $0.setup = { _, _, hub in hub.menuKeys = true } },
        // An inbox item and a session picked, their actions showing, to compare them.
        Shot.edges("picked", on: .rightAndTop) { $0.pinned = true; $0.selection = .firstNeedsYou; $0.hoveredSession = "local_demo-ci" },
        Shot.edges("focus-inbox", on: .rightAndTop) { $0.pinned = true; $0.focus = .inbox },
        Shot.edges("focus-agents", on: .rightAndTop) { $0.pinned = true; $0.focus = .agents },
        // Inbox.
        Shot.edges("open-bots", on: .rightAndTop) { $0.pinned = true; $0.filter = .bots },
        Shot.edges("open-done", on: .rightAndTop) { $0.pinned = true; $0.filter = .done },
        Shot.edges("search-none", on: .rightAndTop) { $0.pinned = true; $0.query = "zzzz" },
        Shot.edges("search-sessions", on: .rightAndTop) { $0.pinned = true; $0.query = "lcu" },
        Shot.edges("focus-ci", on: .rightAndTop) { $0.pinned = true; $0.focus = .ci },
        // Causes: why a list is empty or the sync is not healthy.
        causes.flatMap { slug, scenario in scenarioShots(slug, scenario) },
        Shot.edges("open-no-repos", on: .rightAndTop) { $0.pinned = true; $0.scenario = .empty },
        Shot.edges("open-bots-empty", on: .rightAndTop) { $0.pinned = true; $0.scenario = .botsEmpty; $0.filter = .bots },
        Shot.edges("open-done-empty", on: .rightAndTop) { $0.pinned = true; $0.scenario = .doneEmpty; $0.filter = .done },
        // CI, sessions and the update cell.
        ci.flatMap { slug, scenario in scenarioShots(slug, scenario, peek: .ci) },
        Shot.edges("focus-ci-many-ci", on: .rightAndTop) { $0.pinned = true; $0.scenario = .manyCI; $0.focus = .ci },
        sessions.flatMap { slug, scenario in scenarioShots(slug, scenario, peek: .agents) },
        Shot.edges("focus-agents-sessions-12", on: .rightAndTop) { $0.pinned = true; $0.scenario = .sessions12; $0.focus = .agents },
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
        // The shared components, each in its states.
        [Shot(name: "components", sheet: .components), Shot(name: "components-contrast", sheet: .components, environment: .contrast)],
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
        // The chrome on a 1280×720 screen: every peek, a focused section and the fullest views, on every edge.
        Shot.edges("peek-inbox-720") { $0.section = .inbox; $0.size = Shot.hd },
        Shot.edges("peek-ci-720") { $0.section = .ci; $0.size = Shot.hd },
        Shot.edges("peek-agents-720") { $0.section = .agents; $0.scenario = .sessions12; $0.size = Shot.hd },
        Shot.edges("peek-controls-720") { $0.section = .controls; $0.size = Shot.hd },
        Shot.edges("focus-inbox-720") { $0.pinned = true; $0.focus = .inbox; $0.size = Shot.hd },
        Shot.edges("open-sessions-12-720") { $0.pinned = true; $0.scenario = .sessions12; $0.size = Shot.hd },
        Shot.edges("open-many-ci-720") { $0.pinned = true; $0.scenario = .manyCI; $0.size = Shot.hd },
    ].flatMap { $0 }

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
        case .item(let id): hub.selection = "i:" + id
        case .session(let id): hub.selection = "a:" + id
        case nil: break
        }
        ui.drawerSelection = shot.hoveredSession
        shot.setup?(store, ui, hub)
        let content: AnyView
        switch shot.sheet {
        case .components: content = AnyView(ComponentSheet())
        case nil:
            content = AnyView(PlaygroundView(store: store, ui: ui, hub: hub, showsExplainer: shot.showsExplainer, minSize: shot.size)
                .environment(\.previewTip, shot.tip))
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
        return (window, { hub.pinned = shot.pinned; hub.page = shot.page; hub.focus = shot.focus })
    }

    private static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
            VStack(alignment: .leading, spacing: 12) { headers; banners; empties; undo }
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
        group("Switch (on, off, disabled) and field (rest, focused)") {
            VStack(spacing: 0) {
                Toggle("Launch at login", isOn: .constant(true))
                Toggle("Desktop notifications", isOn: .constant(false))
                Toggle("Review requests", isOn: .constant(true)).disabled(true)
            }
            .toggleStyle(SwitchStyle())
            .font(Theme.Typography.body).foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Metrics.contentEdge - Theme.Metrics.inset)
            .background(Theme.Radius.shape(Theme.Radius.row).fill(Theme.Fill.group))
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
            EmptyBlock("All caught up", detail: "Checked 2m ago")
            EmptyBlock(title: "Nothing watched yet", detail: "Add a repository to start.") { BorderedButton("Add a repository") {} }
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
