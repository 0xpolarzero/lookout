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
    /// The "Lookout playground" card: hidden in shots, where it is no part of what is looked at.
    var showsExplainer = true
    var minSize = CGSize(width: 1280, height: 820)
    @State private var behindClicks = 0
    @State private var leaveTask: Task<Void, Never>?

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
                docked(geo.size)
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

    @ViewBuilder private func docked(_ size: CGSize) -> some View {
        let hubView = LookoutHub(store: store, ui: ui, hub: hub,
                                 maxLength: ui.edge.isHorizontal ? size.height - menuBar - 80 : size.height - menuBar - 60,
                                 maxWidth: size.width)
            .onHover(perform: hover)
        switch ui.edge {
        case .right: hubView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, menuBar + 40)
        case .left: hubView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, menuBar + 40)
        case .top: hubView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, menuBar)
        case .bottom: hubView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// Opens at once; closes a moment after the mouse leaves, so crossing a gap doesn't flicker it shut.
    private func hover(_ inside: Bool) {
        leaveTask?.cancel()
        if inside {
            hub.hovering = true
        } else {
            leaveTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { hub.hovering = false }
            }
        }
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

// MARK: - Shots

/// What the system's accessibility settings read in a shot: the ones set override the system's, the others keep what it says.
/// Only what reads them from the SwiftUI environment follows (Reduce Motion, in the hub); a read straight from `NSWorkspace`
/// always shows the system's setting.
struct ShotEnvironment: Equatable {
    var increaseContrast = false
    var reduceMotion = false
    var differentiateWithoutColor = false

    static let contrast = ShotEnvironment(increaseContrast: true)
    static let motion = ShotEnvironment(reduceMotion: true)
    static let differentiate = ShotEnvironment(differentiateWithoutColor: true)
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
}

/// What a shot has picked, for the row actions to show.
enum ShotSelection {
    /// The newest inbox item that needs you.
    case firstNeedsYou
}

/// One screenshot: the playground in a given state, rendered offscreen to `<name>.png`. Add one by adding a line to
/// `PlaygroundShots.catalog`; everything but `name` has a default.
struct Shot {
    static let standard = CGSize(width: 1280, height: 820)
    /// A 1280x720 screen: the hub must fit its edge without overflowing.
    static let hd = CGSize(width: 1280, height: 720)

    var name: String
    var edge = DockEdge.right
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

    /// The same shot on each of these edges, named `<edge>-<state>`.
    static func edges(_ state: String, on edges: [DockEdge] = .all, _ configure: (inout Shot) -> Void = { _ in }) -> [Shot] {
        edges.map { edge in
            var shot = Shot(name: "\(edge.rawValue)-\(state)", edge: edge)
            configure(&shot)
            return shot
        }
    }
}

/// `--playground-shots <dir> [substring...]`: the real views, on the demo data, rendered offscreen as PNGs. Shots whose
/// name contains one of the substrings are rendered (all of them without any), so a change is checked in a few seconds:
/// `.build/debug/Lookout --playground-shots /tmp/shots right-open`.
///
/// Names are `<edge>-<state>`, the edge being right, top, left or bottom. Every shot is one line of `catalog`, under a
/// comment saying what the group shows. Most states are on the right edge and along the top, which stand for the sides and
/// the strip; the baseline and the bar at rest are on all four.
@MainActor
enum PlaygroundShots {
    /// States of the data, as `(name, scenario)`; each is shown at rest and open.
    private static let causes: [(String, Demo.Scenario)] = [
        ("signed-out", .signedOut), ("repos-failed", .reposFailed), ("rate-limited", .rateLimited), ("snoozed", .snoozed),
        ("error", .error), ("needs-you-empty", .needsYouEmpty), ("first-sync", .firstSync), ("sync-fault", .syncFault),
        ("no-repos", .empty),
    ]
    private static let ci: [(String, Demo.Scenario)] = [
        ("no-ci", .noCI), ("all-passing", .allPassing), ("many-ci", .manyCI), ("ci-running", .ciRunning),
    ]
    private static let sessions: [(String, Demo.Scenario)] = [
        ("sessions-waiting", .sessionsWaiting), ("sessions-working", .sessionsWorking), ("sessions-unread", .sessionsUnread),
        ("sessions-new-activity", .sessionsNewActivity), ("sessions-scratch", .sessionsScratch), ("sessions-none", .sessionsNone),
        ("sessions-12", .sessions12), ("sessions-many-new", .sessionsManyNew), ("sessions-waiting-10", .sessionsWaiting10),
    ]
    private static let updates: [(String, Demo.Scenario)] = [
        ("update-available", .updateAvailable), ("update-downloading", .updateDownloading), ("update-ready", .updateReady),
    ]

    /// The baseline, the inbox and the accessibility settings: one line each.
    private static let baseline: [Shot] = [
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
        // An inbox item and a session picked, their actions showing, to compare them.
        Shot.edges("picked", on: .rightAndTop) { $0.pinned = true; $0.selection = .firstNeedsYou; $0.hoveredSession = "local_demo-ci" },
        Shot.edges("focus-inbox", on: .rightAndTop) { $0.pinned = true; $0.focus = .inbox },
        Shot.edges("focus-agents", on: .rightAndTop) { $0.pinned = true; $0.focus = .agents },
    ].flatMap { $0 }

    /// Inbox: the tabs, a search with no match, and a list longer than it shows.
    private static let inbox: [Shot] = [
        Shot.edges("open-bots", on: .rightAndTop) { $0.pinned = true; $0.filter = .bots },
        Shot.edges("open-done", on: .rightAndTop) { $0.pinned = true; $0.filter = .done },
        Shot.edges("search-none", on: .rightAndTop) { $0.pinned = true; $0.query = "zzzz" },
        Shot.edges("open-bots-empty", on: .rightAndTop) { $0.pinned = true; $0.scenario = .botsEmpty; $0.filter = .bots },
        Shot.edges("open-done-empty", on: .rightAndTop) { $0.pinned = true; $0.scenario = .doneEmpty; $0.filter = .done },
        Shot.edges("open-inbox-many", on: .rightAndTop) { $0.pinned = true; $0.scenario = .inboxMany },
    ].flatMap { $0 }

    /// A scenario open on the right and top, with its peek and focused section when it has one.
    private static func scenarioShots(_ slug: String, _ scenario: Demo.Scenario, rest: Bool = false, peek: HubSection? = nil,
                                      focus: Bool = false) -> [Shot] {
        var shots: [Shot] = []
        if rest { shots += Shot.edges("rest-\(slug)", on: .rightAndTop) { $0.scenario = scenario } }
        shots += Shot.edges("open-\(slug)", on: .rightAndTop) { $0.pinned = true; $0.scenario = scenario }
        if let peek {
            let name = peek == .ci ? "ci" : "agents"
            shots += Shot.edges("peek-\(name)-\(slug)", on: .rightAndTop) { $0.section = peek; $0.scenario = scenario }
        }
        if focus {
            shots += Shot.edges("focus-agents-\(slug)", on: .rightAndTop) { $0.pinned = true; $0.focus = .agents; $0.scenario = scenario }
        }
        return shots
    }

    /// The accessibility settings, on the bar at rest and kept open.
    private static func environmentShots(_ slug: String, _ environment: ShotEnvironment) -> [Shot] {
        Shot.edges("rest-\(slug)", on: .rightAndTop) { $0.environment = environment }
            + Shot.edges("open-\(slug)", on: .rightAndTop) { $0.pinned = true; $0.environment = environment }
    }

    /// Every shot, in the order they are rendered.
    static let catalog: [Shot] = {
        var shots = baseline + inbox
        // Causes: why a list is empty or the sync is not healthy.
        for (slug, scenario) in causes { shots += scenarioShots(slug, scenario, rest: true) }
        for (slug, scenario) in ci { shots += scenarioShots(slug, scenario, peek: .ci) }
        for (slug, scenario) in sessions { shots += scenarioShots(slug, scenario, peek: .agents, focus: true) }
        for (slug, scenario) in updates { shots += scenarioShots(slug, scenario, rest: true) }
        shots += environmentShots("contrast", .contrast)
        shots += environmentShots("motion", .motion)
        shots += environmentShots("differentiate", .differentiate)
        // A 1280x720 screen: the hub must fit its edge without overflowing.
        shots += Shot.edges("open-720", on: .rightAndTop) { $0.pinned = true; $0.size = Shot.hd }
        shots += Shot.edges("open-sessions-12-720", on: .rightAndTop) { $0.pinned = true; $0.scenario = .sessions12; $0.size = Shot.hd }
        shots += Shot.edges("open-many-ci-720", on: .rightAndTop) { $0.pinned = true; $0.scenario = .manyCI; $0.size = Shot.hd }
        return shots
    }()

    /// The shots whose name contains one of `filters` (all of them without any).
    static func select(_ filters: [String]) -> [Shot] {
        let filters = filters.map { $0.lowercased() }
        return catalog.filter { shot in filters.isEmpty || filters.contains { shot.name.contains($0) } }
    }

    /// `--playground-shots <dir> [substring...]`.
    static func run(to dir: String) {
        let arguments = CommandLine.arguments
        let start = (arguments.firstIndex(of: "--playground-shots") ?? 0) + 2
        let filters = Array(arguments.dropFirst(start).filter { !$0.hasPrefix("--") })
        let shots = select(filters)
        guard !shots.isEmpty else {
            print("No shot matches \(filters.joined(separator: ", ")). \(catalog.count) shots, e.g. \(catalog[0].name)")
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task {
            // Some at a time: every window is a live SwiftUI hierarchy, and a full set is too much to hold at once.
            for batch in stride(from: 0, to: shots.count, by: 10).map({ Array(shots[$0..<min($0 + 10, shots.count)]) }) {
                let windows = batch.map { (name: $0.name, window: open($0)) }
                try? await Task.sleep(for: .seconds(2.5))
                for (name, window) in windows {
                    capture(window, to: "\(dir)/\(name).png")
                    window.close()
                }
            }
            print("\(shots.count) shots in \(dir)")
            exit(0)
        }
    }

    /// The shot's window, offscreen and showing the playground in its state.
    private static func open(_ shot: Shot) -> NSWindow {
        let store = Store()
        Demo.populate(store, shot.scenario)
        store.agents.expanded = true
        let ui = UIState(persists: false, edge: shot.edge)
        let hub = HubState()
        hub.pinned = shot.pinned
        hub.page = shot.page
        hub.query = shot.query
        hub.focus = shot.focus
        hub.section = shot.section
        if let filter = shot.filter { hub.filter = filter }
        if shot.selection == .firstNeedsYou { hub.selection = store.list(.needsYou).first.map { "i:" + $0.id } }
        ui.drawerSelection = shot.hoveredSession
        let root = PlaygroundView(store: store, ui: ui, hub: hub, showsExplainer: false, minSize: shot.size)
            .environment(\.previewTip, shot.tip)
            .shotEnvironment(shot.environment)
            .frame(width: shot.size.width, height: shot.size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame.size = shot.size
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        return window
    }

    private static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
