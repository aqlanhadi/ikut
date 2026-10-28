import Testing
@testable import ikut

/// D72: the Debug design inventory's parsing, grouping and totals.
struct DesignInventoryTests {
    private let rows = """
    font|14||A.swift:1
    font|13||B.swift:2
    font|14||C.swift:3
    font|9||D.swift:4
    color|#FF0000|FF0000|A.swift:5
    color|white 0.1, alpha 0.5|1A1A1A|B.swift:6
    padding|14||A.swift:7
    bad row
    """

    @Test func parsesRowsAndSkipsBadOnes() {
        let all = InventoryParser.literals(rows)
        #expect(all.count == 7)
        #expect(all[4].swatch == "FF0000")
        #expect(all[0].swatch == nil)
        #expect(all[0].place == "A.swift:1")
    }

    @Test func groupsByValueSmallestFirst() {
        let groups = InventoryGroups.groups(InventoryParser.literals(rows), in: .font)
        #expect(groups.map(\.value) == ["9", "13", "14"])
        #expect(groups.last?.places == ["A.swift:1", "C.swift:3"])
        #expect(groups.last?.count == 2)
    }

    @Test func totalsCountEveryUseAndEachDistinctValue() {
        let all = InventoryParser.literals(rows)
        #expect(InventoryGroups.totals(all, in: .font) == "4 literal font sizes, 3 distinct")
        #expect(InventoryGroups.totals(all, in: .padding) == "1 literal paddings, 1 distinct")
        #expect(InventoryGroups.totals(all, in: .radius) == "0 literal corner radii, 0 distinct")
    }

    @Test func viewsParseAndCountOnesUsedInOneFileOrNone() {
        let views = InventoryParser.views("A|View|X/A.swift|0\nB|ViewModifier|X/B.swift|1\nC|View|X/C.swift|5\nnot|enough")
        #expect(views.count == 3)
        #expect(InventoryGroups.totals(views) == "3 custom views, 2 used in one file or none")
        #expect(InventoryGroups.usage(views[0]) == "Only in its own file")
        #expect(InventoryGroups.usage(views[2]) == "Used in 5 other files")
    }

    @Test func theGeneratedInventoryParses() {
        #expect(!DesignInventory.views.isEmpty)
        #expect(!DesignInventory.literals.isEmpty)
        #expect(DesignInventory.viewRows.split(separator: "\n").count == DesignInventory.views.count)
        #expect(DesignInventory.literalRows.split(separator: "\n").count == DesignInventory.literals.count)
    }
}
