import AppKit
import SwiftUI
import Testing
@testable import Lookout

/// One element of the accessibility tree VoiceOver would read, as SwiftUI builds it for a hosted view.
struct AXNode: Equatable {
    let role: String
    let label: String
    let children: [AXNode]
    /// What a static text says (its value, not its label).
    var value = ""

    /// This element and everything under it.
    var all: [AXNode] { [self] + children.flatMap(\.all) }

    /// The controls: what a screen reader user presses, ticks or types in, so each must say what it is.
    static let controls: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField",
                                        "AXTextArea", "AXSlider", "AXLink", "AXComboBox"]
}

/// The hub in a window of its own, offscreen, and its accessibility tree.
@MainActor
enum AccessibilityTree {
    /// SwiftUI builds the tree only when it believes an assistive technology is attached.
    private static let enabled: Void = {
        _ = NSApplication.shared
        NSApp.perform(NSSelectorFromString("setAccessibilityEnhancedUserInterface:"), with: true as NSNumber)
    }()

    /// The tree of a hub on `edge`, in the state `configure` asks for once it is on screen.
    static func render(edge: DockEdge = .right, scenario: Demo.Scenario = .agents, size: CGSize = CGSize(width: 1000, height: 800),
                       ready: (AXNode) -> Bool = hasControls,
                       configure: (Store, HubState) -> Void = { _, _ in }) async throws -> AXNode {
        _ = enabled
        let store = Store()
        Demo.populate(store, scenario)
        // The Repositories page asks GitHub for suggestions: a GitHub of its own, with nothing to suggest.
        store.gh.session = StubbedGitHub.session { _ in .init(200, "[]") }
        store.agents.expanded = true
        let hub = HubState()
        let view = LookoutHub(store: store, ui: UIState(persists: false, edge: edge), hub: hub, maxLength: 700, maxWidth: size.width)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        configure(store, hub)
        return await settled(hosting, ready: ready)
    }

    /// The tree of any view, in a window of its own (the Router's window, say).
    static func render<V: View>(_ view: V, size: CGSize = CGSize(width: 920, height: 640),
                                ready: (AXNode) -> Bool = hasControls) async throws -> AXNode {
        _ = enabled
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        return await settled(hosting, ready: ready)
    }

    /// What a tree must have before it is read at all: some controls (an empty tree, before SwiftUI has built it, has no
    /// unnamed control either).
    nonisolated static func hasControls(_ tree: AXNode) -> Bool {
        tree.all.contains { AXNode.controls.contains($0.role) }
    }

    /// The tree once it is `ready` and the same over several turns of the main actor in a row (SwiftUI has drawn what it had
    /// pending), however slow the machine; a watchdog of a minute, past which the test fails.
    private static func settled(_ hosting: NSView, ready: (AXNode) -> Bool) async -> AXNode {
        let deadline = Date().addingTimeInterval(60)
        var last: AXNode?, same = 0
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
            let tree = node(hosting)
            same = ready(tree) && tree == last ? same + 1 : 0
            last = tree
            if same >= 5 { return tree }
        }
        // Never ready, or never still: the tree read now would prove nothing (an empty one has no unnamed control).
        hosting.layoutSubtreeIfNeeded()
        let tree = node(hosting)
        Issue.record("The accessibility tree wasn't ready and steady within a minute (\(ready(tree) ? "still changing" : "no controls"))")
        return tree
    }

    private static func node(_ element: Any) -> AXNode {
        guard let object = element as? NSObject else { return AXNode(role: "?", label: "", children: []) }
        func value() -> String { (object.value(forKey: "accessibilityValue") as? String) ?? "" }
        func string(_ key: String) -> String { (object.value(forKey: key) as? String) ?? "" }
        let role = string("accessibilityRole")
        // A scroll bar's parts are the system's own.
        let children = role == "AXScrollBar" ? [] : ((object.value(forKey: "accessibilityChildren") as? [Any]) ?? []).map(node)
        return AXNode(role: role, label: string("accessibilityLabel"), children: children,
                      value: role == "AXStaticText" ? value() : "")
    }
}

@MainActor
@Suite(.hostsWindows) struct AccessibilityTreeTests {
    /// What the hub in `state` has for a control without a name, wherever it is.
    private func unnamed(_ state: String, edge: DockEdge = .right, scenario: Demo.Scenario = .agents,
                         configure: @escaping (Store, HubState) -> Void) async throws -> [String] {
        let tree = try await AccessibilityTree.render(edge: edge, scenario: scenario, configure: configure)
        return tree.all.filter { AXNode.controls.contains($0.role) && $0.label.isEmpty }.map { "\(state) (\(edge)): \($0.role) has no label" }
    }

    @Test func theTreeHasTheControlsItIsMeasuredOn() async throws {
        // A render that came out empty would pass the test below for nothing.
        let tree = try await AccessibilityTree.render { _, hub in hub.pinned = true }
        let buttons = tree.all.filter { $0.role == "AXButton" }
        #expect(buttons.count > 5, "\(buttons.count) buttons in \(tree.all.map(\.role))")
        #expect(buttons.contains { !$0.label.isEmpty })
    }

    @Test func noControlIsLeftWithoutAName() async throws {
        var missing: [String] = []
        for edge in [DockEdge.right, .top] {
            missing += try await unnamed("at rest", edge: edge) { _, _ in }
            missing += try await unnamed("kept open", edge: edge) { _, hub in hub.pinned = true }
            missing += try await unnamed("searching", edge: edge) { _, hub in hub.pinned = true; hub.query = "zig" }
        }
        for section in [HubSection.inbox, .ci, .agents, .controls] {
            missing += try await unnamed("peek \(section)") { _, hub in hub.section = section }
        }
        for focus in [HubSection.inbox, .ci, .agents] {
            missing += try await unnamed("\(focus) focused") { _, hub in hub.pinned = true; hub.focus = focus }
        }
        for tab in [InboxFilter.bots, .done] {
            missing += try await unnamed("\(tab.label) tab") { _, hub in hub.pinned = true; hub.filter = tab }
        }
        missing += try await unnamed("Settings") { _, hub in hub.go(.settings) }
        missing += try await unnamed("Repositories") { _, hub in hub.go(.repos) }
        missing += try await unnamed("signed out", scenario: .signedOut) { _, hub in hub.pinned = true }
        missing += try await unnamed("update ready", scenario: .updateReady) { _, hub in hub.pinned = true }
        missing += try await unnamed("many sessions", scenario: .sessionsManyNew) { _, hub in hub.pinned = true; hub.focus = .agents }
        missing += try await unnamed("peek router", scenario: .router) { _, hub in hub.section = .router }
        missing += try await unnamed("peek router only", scenario: .routerOnly) { _, hub in hub.section = .router }
        missing += try await unnamed("router only kept open", edge: .top, scenario: .routerOnly) { _, hub in hub.pinned = true }
        for edge in [DockEdge.right, .top] {
            missing += try await unnamed("router kept open", edge: edge, scenario: .router) { _, hub in hub.pinned = true }
        }
        #expect(missing.isEmpty, "\(missing)")
    }

    @Test func theRouterWindowNamesEveryControl() async throws {
        let store = Store()
        Demo.populate(store, .router)
        let model = RouterModel()
        model.selection = store.openRouterCards.first { $0.kind == .question }?.id
        let tree = try await AccessibilityTree.render(RouterView(store: store, model: model))
        let controls = tree.all.filter { AXNode.controls.contains($0.role) }
        #expect(controls.count > 5, "\(tree.all.map(\.role))")
        let unnamed = controls.filter { $0.label.isEmpty }.map(\.role)
        #expect(unnamed.isEmpty, "\(unnamed)")
        #expect(tree.all.contains { $0.label == "Message the Router" })
    }
}
