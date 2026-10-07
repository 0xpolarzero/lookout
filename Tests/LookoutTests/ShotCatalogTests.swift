import Testing
@testable import Lookout

@MainActor
@Suite struct ShotCatalogTests {
    /// A shot is a file named after it: two with one name would overwrite each other, and the set would leave fewer files
    /// than it says.
    @Test func everyShotHasItsOwnName() {
        var seen = Set<String>()
        let repeated = PlaygroundShots.catalog.map(\.name).filter { !seen.insert($0).inserted }
        #expect(repeated.isEmpty, "Shots named more than once: \(repeated)")
    }

    @Test func aShotIsNamedAfterItsEdge() {
        for shot in PlaygroundShots.catalog {
            #expect(shot.name.hasPrefix(shot.edge.rawValue + "-"), "\(shot.name) is on \(shot.edge)")
        }
    }

    @Test func theNamesThatWereAlwaysThereStillAre() {
        let names = Set(PlaygroundShots.catalog.map(\.name))
        for edge in [DockEdge.right, .top, .left, .bottom] {
            for state in ["rest", "open", "settings", "search", "peek-inbox", "peek-ci", "peek-agents", "peek-controls"] {
                #expect(names.contains("\(edge.rawValue)-\(state)"), "\(edge.rawValue)-\(state)")
            }
        }
        for edge in [DockEdge.right, .top] {
            for state in ["repos", "tip", "picked", "focus-inbox", "focus-agents"] {
                #expect(names.contains("\(edge.rawValue)-\(state)"), "\(edge.rawValue)-\(state)")
            }
        }
    }

    @Test func aFilterKeepsTheShotsWhoseNameContainsIt() {
        #expect(PlaygroundShots.select([]).count == PlaygroundShots.catalog.count)
        #expect(PlaygroundShots.select(["right-rest"]).map(\.name).contains("right-rest"))
        #expect(PlaygroundShots.select(["RIGHT-REST"]).allSatisfy { $0.name.contains("right-rest") })
        #expect(PlaygroundShots.select(["zzz-no-such-shot"]).isEmpty)
        let two = PlaygroundShots.select(["left-rest", "bottom-rest"])
        #expect(two.allSatisfy { $0.name.contains("left-rest") || $0.name.contains("bottom-rest") } && !two.isEmpty)
    }

    @Test func everyScenarioButTheDemosOwnIsShown() {
        let shown = Set(PlaygroundShots.catalog.map(\.scenario))
        // The plain sets other than `agents` are for `--demo`; each of the others is a state a shot checks.
        let plain: Set<Demo.Scenario> = [.busy, .botsOnly, .allClear]
        #expect(Set(Demo.Scenario.allCases).subtracting(shown).subtracting(plain).isEmpty)
    }
}
