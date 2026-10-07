import AppKit
import SwiftUI
import Testing
@testable import Lookout

/// One element of the accessibility tree VoiceOver would read, as SwiftUI builds it for a hosted view.
struct AXNode {
    let role: String
    let label: String
    let children: [AXNode]

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
                       configure: (Store, HubState) -> Void = { _, _ in }) async throws -> AXNode {
        _ = enabled
        let store = Store()
        Demo.populate(store, scenario)
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
        try await Task.sleep(for: .seconds(0.7))
        hosting.layoutSubtreeIfNeeded()
        return node(hosting)
    }

    private static func node(_ element: Any) -> AXNode {
        guard let object = element as? NSObject else { return AXNode(role: "?", label: "", children: []) }
        func string(_ key: String) -> String { (object.value(forKey: key) as? String) ?? "" }
        let role = string("accessibilityRole")
        // A scroll bar's parts are the system's own.
        let children = role == "AXScrollBar" ? [] : ((object.value(forKey: "accessibilityChildren") as? [Any]) ?? []).map(node)
        return AXNode(role: role, label: string("accessibilityLabel"), children: children)
    }
}

@MainActor
@Suite struct AccessibilityTreeTests {
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
        #expect(missing.isEmpty, "\(missing)")
    }
}
