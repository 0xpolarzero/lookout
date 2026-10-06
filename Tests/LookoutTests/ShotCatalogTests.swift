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
}
