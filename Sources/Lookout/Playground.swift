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
    @State private var behindClicks = 0
    @State private var leaveTask: Task<Void, Never>?

    private let menuBar: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.20, green: 0.27, blue: 0.42), Color(red: 0.47, green: 0.38, blue: 0.52),
                                        Color(red: 0.70, green: 0.52, blue: 0.50)], startPoint: .topLeading, endPoint: .bottomTrailing)
                behindApp.position(x: geo.size.width - 330, y: 260)
                controls.position(x: geo.size.width / 2 - (ui.edge == .right ? 140 : ui.edge == .left ? -140 : 0),
                                  y: geo.size.height / 2 + (ui.edge == .top ? 120 : ui.edge == .bottom ? -120 : 0))
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
        .frame(minWidth: 1280, minHeight: 820)
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

/// `--playground-shots <dir>`: the playground pinned open on each edge, and at rest, as PNGs.
@MainActor
enum PlaygroundShots {
    static func run(to dir: String) {
        var windows: [(String, NSWindow)] = []
        for edge in [DockEdge.right, .top, .left, .bottom] {
            for (state, pinned, page) in [("rest", false, HubPage.main), ("open", true, .main), ("settings", true, .settings),
                                          ("repos", true, .repos), ("search", true, .main), ("tip", true, .main),
                                          ("peek-inbox", false, .main), ("peek-ci", false, .main), ("peek-agents", false, .main),
                                          ("peek-controls", false, .main), ("picked", true, .main),
                                          ("focus-inbox", true, .main), ("focus-agents", true, .main)] {
                if (state == "picked" || state.hasPrefix("focus")) && edge != .right && edge != .top { continue }
                if (state == "repos" || state == "tip") && edge != .right && edge != .top { continue }
                let store = Store()
                Demo.populate(store, .agents)
                store.agents.expanded = true
                let ui = UIState(persists: false, edge: edge)
                let hub = HubState()
                hub.pinned = pinned
                hub.page = page
                if state == "search" { hub.query = "sand" }
                // "peek-…": just that section open beside the bar, as when it's hovered.
                hub.focus = ["focus-inbox": HubSection.inbox, "focus-agents": .agents][state]
                // "picked": an inbox item and a session picked, their actions showing, to compare them.
                if state == "picked" {
                    hub.selection = store.list(.needsYou).first.map { "i:" + $0.id }
                    ui.drawerSelection = "local_demo-ci"
                }
                hub.section = ["peek-inbox": HubSection.inbox, "peek-ci": .ci, "peek-agents": .agents, "peek-controls": .controls][state]
                // "tip": the settings button's tooltip, shown at once, to check it isn't clipped against the edge.
                let hosting = NSHostingView(rootView: PlaygroundView(store: store, ui: ui, hub: hub)
                    .environment(\.previewTip, state == "tip" ? "Settings" : nil)
                    .frame(width: 1280, height: 820))
                hosting.frame.size = NSSize(width: 1280, height: 820)
                let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = hosting
                window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                window.orderFrontRegardless()
                windows.append(("\(edge.rawValue)-\(state)", window))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            for (name, window) in windows {
                guard let view = window.contentView else { continue }
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
            exit(0)
        }
    }
}

