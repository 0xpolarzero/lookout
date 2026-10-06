import AppKit
import SwiftUI
import Testing
@testable import Lookout

/// The cue under a cut `CappedScroll` (DESIGN.md 5.4): clicked, it pages through the rows, and at the end it takes the list
/// back to the top. Driven with real clicks on the hosted view.
@MainActor
@Suite struct CueUnderACutList {
    private static let height: CGFloat = 400

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

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
        host.frame = NSRect(x: 0, y: 0, width: 300, height: Self.height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.orderOut(nil) }

        func settle(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
            }
        }
        settle(1)
        let scroll = try #require(scrollView(in: host))
        let viewport = scroll.frame.height
        // Whole rows, with the cue's line under them inside the cap.
        #expect(viewport <= 300 - Theme.Metrics.pitch)
        func click() {
            let point = NSPoint(x: 40, y: Self.height - viewport - Theme.Metrics.pitch / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
                settle(0.05)
            }
            settle(0.8)
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
