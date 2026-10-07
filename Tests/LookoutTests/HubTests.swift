import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lookout

@Suite struct HubCI {
    private func status(_ state: CIState) -> CIStatus {
        CIStatus(state: state, branch: "main", sha: nil, url: nil, failing: [], checkedAt: Date(), title: nil, updatedAt: nil)
    }

    private let repos = ["a/missing", "b/stored-none", "c/ok", "d/broken"].map { RepoConfig(fullName: $0) }

    private func names(_ state: CIState) -> [String] {
        let ci = ["b/stored-none": status(CIState.none), "c/ok": status(.success), "d/broken": status(.failure)]
        return LookoutHub.ciRepos(listedIn: state, in: repos, status: ci).map(\.fullName)
    }

    @Test func noRunsIncludesMissingAndStoredNone() {
        #expect(names(CIState.none) == ["a/missing", "b/stored-none"])
    }

    @Test func otherStatesAreExact() {
        #expect(names(.success) == ["c/ok"])
        #expect(names(.failure) == ["d/broken"])
        #expect(names(.pending).isEmpty)
    }
}

@Suite struct CappedScrollFit {
    @Test func stopsOnTheLastRowThatFits() {
        #expect(CappedScrollSpace.fit(cap: 100, edges: [36, 72, 108, 144]) == 72)
        #expect(CappedScrollSpace.fit(cap: 108, edges: [36, 72, 108, 144]) == 108)
        // Rows measured only up to the cap: the cut is unmeasured, so the cap stands.
        #expect(CappedScrollSpace.fit(cap: 300, edges: [43, 87]) == 300)
    }

    @Test func fallsBackToTheCap() {
        #expect(CappedScrollSpace.fit(cap: 20, edges: [36, 72]) == 20)
        #expect(CappedScrollSpace.fit(cap: 100, edges: []) == 100)
    }

    @Test func lazyFitSnapsToWholeRows() {
        // Realized rows all end within the cap: the rest repeat the pitch (here 41 with spacing).
        #expect(CappedScrollSpace.fitLazy(cap: 300, edges: [48, 89, 130, 171, 212]) == 294)
        #expect(CappedScrollSpace.fitLazy(cap: 294, edges: [48, 89, 130, 171, 212]) == 294)
        #expect(CappedScrollSpace.fitLazy(cap: 100, edges: [48, 89, 130]) == 89)
        // Rows of different heights can't be extrapolated: the cap stands.
        #expect(CappedScrollSpace.fitLazy(cap: 300, edges: [30, 70, 110, 140, 180]) == 300)
        // Never below the first row; no pitch with one edge.
        #expect(CappedScrollSpace.fitLazy(cap: 30, edges: [48, 89]) == 30)
        #expect(CappedScrollSpace.fitLazy(cap: 300, edges: [48]) == 300)
    }
}

@MainActor
@Suite struct CappedScrollHosted {
    @Observable final class Count { var n: Int; init(_ n: Int) { self.n = n } }

    private struct Changing: View {
        let count: Count
        var body: some View {
            CappedScroll(cap: 300, lazy: AdaptiveStack<EmptyView>.isLazy(count.n)) {
                AdaptiveStack(count: count.n, spacing: 0) {
                    ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 40).frame(maxWidth: .infinity).capEdge() }
                }
            }
        }
    }

    @Test func rowCountChangesResizeTheList() {
        let count = Count(3)
        let hosting = NSHostingView(rootView: Changing(count: count).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        func settle() -> CGFloat {
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); hosting.layoutSubtreeIfNeeded() }
            return hosting.fittingSize.height
        }
        #expect(abs(settle() - 120) < 1)
        count.n = 100
        let grown = settle()
        #expect(grown >= 280 && grown <= 300, "grown: \(grown)")
        count.n = 2
        #expect(abs(settle() - 80) < 1)
        window.contentView = nil
        window.orderOut(nil)
    }

    private func height<V: View>(of view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
        let h = hosting.fittingSize.height
        window.contentView = nil
        window.orderOut(nil)
        return h
    }

    private func rows(_ n: Int) -> some View {
        ForEach(0..<n, id: \.self) { i in Text("row \(i)").frame(height: 40).frame(maxWidth: .infinity).capEdge() }
    }

    @Test func shortListIsAsTallAsItsContent() {
        #expect(abs(height(of: CappedScroll(cap: 300) { VStack(spacing: 0) { rows(3) } }) - 120) < 1)
    }

    @Test func overflowingListsFillTheCapWhateverTheStack() {
        for n in [8, 61, 200] {
            let eager = height(of: CappedScroll(cap: 300, lazy: AdaptiveStack<EmptyView>.isLazy(n)) { AdaptiveStack(count: n) { rows(n) } })
            #expect(eager >= 280 && eager <= 300, "adaptive \(n): \(eager)")
            let lazy = height(of: CappedScroll(cap: 300, lazy: true) { LazyVStack(spacing: 0) { rows(n) } })
            #expect(lazy >= 280 && lazy <= 300, "lazy \(n): \(lazy)")
            let grid = height(of: CappedScroll(cap: 300, lazy: true) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) { rows(n * 2) }
            })
            #expect(grid >= 280 && grid <= 300, "grid \(n): \(grid)")
        }
    }

    private struct LazyRows: View {
        let count: Count
        let grid: Bool
        var body: some View {
            CappedScroll(cap: 300, lazy: true) {
                if grid {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 1) {
                        ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 41).frame(maxWidth: .infinity).capEdge() }
                    }.padding(.vertical, 8)
                } else {
                    AdaptiveStack(count: count.n, spacing: 1) {
                        ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 41).frame(maxWidth: .infinity).capEdge() }
                    }.padding(.vertical, 8)
                }
            }
        }
    }

    /// Hosts the list, settles it, and returns its height after each row-count change.
    private func heights(grid: Bool, counts: [Int]) -> [CGFloat] {
        let count = Count(counts[0])
        let hosting = NSHostingView(rootView: LazyRows(count: count, grid: grid).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        var out: [CGFloat] = []
        for n in counts {
            count.n = n
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); hosting.layoutSubtreeIfNeeded() }
            out.append(hosting.fittingSize.height)
        }
        window.contentView = nil
        window.orderOut(nil)
        return out
    }

    /// Whole rows: 8 of padding at the top, then rows of 41 with 1 of spacing between them.
    private func onRowBoundary(_ h: CGFloat) -> Bool {
        let rowsHigh = (h - 8 + 1) / 42
        return abs(rowsHigh - rowsHigh.rounded()) < 0.03 && rowsHigh.rounded() >= 1
    }

    @Test func lazyListEndsOnAWholeRow() {
        let h = heights(grid: false, counts: [200])[0]
        #expect(h <= 300.5 && h >= 250 && onRowBoundary(h), "lazy: \(h)")
    }

    @Test func lazyGridEndsOnAWholeGridRow() {
        let h = heights(grid: true, counts: [400])[0]
        #expect(h <= 300.5 && h >= 250 && onRowBoundary(h), "grid: \(h)")
    }

    @Test func lazyListsResizeAcrossRowCountChanges() {
        for grid in [false, true] {
            let r = heights(grid: grid, counts: [3, 400, 2])
            let per = grid ? 2 : 1
            let short = { (n: Int) in 16 + CGFloat((n + per - 1) / per) * 42 - 1 }
            #expect(abs(r[0] - short(3)) < 1.5, "grid \(grid) 3: \(r)")
            #expect(r[1] <= 300.5 && r[1] >= 250 && onRowBoundary(r[1]), "grid \(grid) 400: \(r)")
            #expect(abs(r[2] - short(2)) < 1.5, "grid \(grid) 2: \(r)")
        }
    }

    @Test func lazyListsShrinkFromOverflowToShort() {
        for grid in [false, true] {
            let r = heights(grid: grid, counts: [400, 4])
            let rows = grid ? 2 : 4
            #expect(abs(r[1] - (16 + CGFloat(rows) * 42 - 1)) < 1.5, "grid \(grid): \(r)")
        }
    }

    private struct VariableRows: View {
        let count: Count
        var body: some View {
            CappedScroll(cap: 300, lazy: true) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 30 + CGFloat(i % 3) * 10).frame(maxWidth: .infinity).capEdge() }
                }
            }
        }
    }

    @Test func variableRowHeightsStillRegrow() {
        let count = Count(200)
        let hosting = NSHostingView(rootView: VariableRows(count: count).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        var out: [CGFloat] = []
        for n in [200, 3, 200] {
            count.n = n
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); hosting.layoutSubtreeIfNeeded() }
            out.append(hosting.fittingSize.height)
        }
        window.contentView = nil
        window.orderOut(nil)
        #expect(abs(out[1] - 120) < 1.5, "\(out)")
        // Cut at a measured row edge (not through a row), and regrown to the same height.
        #expect(out[0] >= 260 && out[0] <= 300.5 && abs(out[2] - out[0]) < 1.5, "\(out)")
    }
}

@Suite struct SettingsScrolling {
    @MainActor @Test func checkForUpdatesAsksForTheUpdatesSectionEveryTime() {
        let hub = HubState()
        hub.showUpdates()
        #expect(hub.page == .settings)
        let first = hub.settingsScroll
        #expect(first?.id == SettingsView.updatesID)
        // Settings open already, and scrolled elsewhere (the request was taken): asking again is a new request.
        hub.settingsScroll = nil
        hub.showUpdates()
        #expect(hub.page == .settings)
        #expect(hub.settingsScroll?.id == SettingsView.updatesID)
        // Not taken yet: still a different request, so what watches it sees a change.
        let pending = hub.settingsScroll
        hub.showUpdates()
        #expect(hub.settingsScroll != pending)
    }
}
