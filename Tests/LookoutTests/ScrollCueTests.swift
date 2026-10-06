import AppKit
import SwiftUI
import Testing
@testable import Lookout

/// The cue under a cut `CappedScroll` (DESIGN.md 5.4): clicked, it pages through the rows, and at the end it takes the list
/// back to the top. Driven with real clicks on the hosted view.
@MainActor
@Suite struct CueUnderACutList {
    private static let height: CGFloat = 400

    @Test func clickingItPagesThroughTheRowsAndComesBackToTheTop() throws {
        let list = CappedScroll(cap: 300, cue: MoreCue(noun: "item")) {
            VStack(spacing: 1) {
                ForEach(0..<20, id: \.self) { row in
                    Text("Row \(row)").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).capEdge()
                }
            }
        }
        .frame(width: 300, height: Self.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: list)
        host.sizingOptions = []
        let window = NSWindow.offscreen(host, size: CGSize(width: 300, height: Self.height))
        defer { window.dismiss() }
        host.settle(for: 1)
        let scroll = try #require(host.first(NSScrollView.self))
        let viewport = scroll.frame.height
        // Whole rows, with the cue's line under them inside the cap.
        #expect(viewport <= 300 - Theme.Metrics.pitch)
        func click() {
            let point = NSPoint(x: 40, y: Self.height - viewport - Theme.Metrics.pitch / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
                host.settle(for: 0.05)
            }
            host.settle(for: 0.8)
        }
        let end = (scroll.documentView?.frame.height ?? 0) - viewport
        var offsets: [CGFloat] = [scroll.contentView.bounds.origin.y]
        for _ in 0..<5 { click(); offsets.append(scroll.contentView.bounds.origin.y) }
        // Down a page at a time, never past the end ...
        #expect(offsets[1] > offsets[0] && offsets[2] > offsets[1], "\(offsets)")
        #expect(offsets.dropLast().max() == end, "\(offsets) of \(end)")
        // ... and with nothing below, the cue says so and goes back up.
        #expect(offsets.last == 0, "\(offsets)")
    }
}
