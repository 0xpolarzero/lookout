import AppKit
import SwiftUI
import Testing
@testable import Lookout

/// The hub is a non-activating panel that is never key while you hover it from another app: the click on a session must
/// open it then, not just make the panel key (a tap gesture spends that first click on it unless told otherwise).
@MainActor
@Suite(.hostsWindows) struct FirstClick {
    private let now = Date()

    private func store() -> (Store, () -> [String]) {
        let s = Store()
        s.persists = false
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-3600)
        let session = ClaudeSession(id: "local_a", title: "Session a", folder: "/code/app", completedTurns: 3,
                                    lastActivity: now.addingTimeInterval(-60), lastFocused: now.addingTimeInterval(-3600),
                                    lastUserMessage: now.addingTimeInterval(-120), summary: .init(blocked: false, detail: "Done"))
        s.ingest([session], appUnread: [], claudeFrontmost: false, now: now)
        var opened: [String] = []
        s.interceptOpen = { opened.append($0) }
        return (s, { opened })
    }

    private func click(_ panel: NSWindow, at p: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
    }

    /// Hosts `content` in a panel like the hub's, makes another window key, then clicks the panel's middle once.
    private func firstClick(on content: some View) async {
        let panel = FloatingPanel(size: NSSize(width: 320, height: 80))
        panel.allowsKey = true
        panel.contentView = NSHostingView(rootView: content.frame(width: 320, height: 80))
        panel.setFrameOrigin(NSPoint(x: 300, y: 300))
        panel.orderFrontRegardless()
        let other = NSWindow(contentRect: NSRect(x: 700, y: 300, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!panel.isKeyWindow)
        click(panel, at: NSPoint(x: 100, y: 40))
        try? await Task.sleep(for: .milliseconds(200))
        panel.orderOut(nil)
        other.orderOut(nil)
    }

    @Test func aSessionRowOpensOnTheClickThatMakesThePanelKey() async {
        await EventLoop.hold()
        let (s, opened) = store()
        let row = try! #require(s.agentRows.pending.first)
        await firstClick(on: DrawerRow(row: row, store: s, ui: UIState(persists: false, edge: .right), inHub: true))
        #expect(opened() == ["Open in Claude · Session a"])
    }

    @Test func aSessionBlockOpensOnTheClickThatMakesThePanelKey() async {
        await EventLoop.hold()
        let (s, opened) = store()
        let row = try! #require(s.agentRows.pending.first)
        await firstClick(on: SessionBlock(row: row, twoLines: false, store: s, ui: UIState(persists: false, edge: .right), hub: HubState()))
        #expect(opened() == ["Open in Claude · Session a"])
    }
}
