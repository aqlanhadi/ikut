import Testing
@testable import ikut

@Suite struct CarSelectionTests {
    @Test func tappingACarSelectsIt() {
        #expect(CarSelection.afterTap(on: "c2", current: nil) == "c2")
        #expect(CarSelection.afterTap(on: "c3", current: "c2") == "c3")
    }

    @Test func tappingTheSameCarAgainClearsIt() {
        #expect(CarSelection.afterTap(on: "c2", current: "c2") == nil)
    }

    @Test func tappingTheMapClears() {
        #expect(CarSelection.afterTap(on: nil, current: "c2") == nil)
    }

    @Test func aCarThatLeavesClearsTheSelection() {
        #expect(CarSelection.kept("c2", among: ["c1", "c2"]) == "c2")
        #expect(CarSelection.kept("c2", among: ["c1", "c3"]) == nil)
        #expect(CarSelection.kept(nil, among: ["c1"]) == nil)
    }

    @Test func aSelectionOpensOnlyAFoldedPanel() {
        #expect(CarSelection.opensPanel(selected: "c1", shown: .folded))
        #expect(!CarSelection.opensPanel(selected: "c1", shown: .unfolded))
        #expect(!CarSelection.opensPanel(selected: "c1", shown: .card))
        #expect(!CarSelection.opensPanel(selected: nil, shown: .folded))
    }

    @Test func rowIdsAreStablePerCar() {
        #expect(CarSelection.rowId("c4") == "car.c4")
    }
}
