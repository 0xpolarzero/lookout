import Testing
@testable import Lookout

@Suite struct AddingARepository {
    @Test func theFieldIsEmptiedOnlyIfItStillReadsAsItDidWhenTheAddBegan() {
        #expect(ReposView.field(afterAdding: "owner/one", typed: "owner/one") == "")
        // The next repository, typed while the add ran, is not erased with the first.
        #expect(ReposView.field(afterAdding: "owner/one", typed: "owner/two") == "owner/two")
    }
}
