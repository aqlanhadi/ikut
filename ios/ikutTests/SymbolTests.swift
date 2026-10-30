import Foundation
import Testing
import UIKit
@testable import ikut

/// D89: SF Symbol names live in one namespace (`Symbol`). A typo would draw an empty image, so every name
/// must resolve to a real system symbol.
struct SymbolTests {
    @Test func noTwoNamesShareAValue() {
        #expect(Set(Symbol.all).count == Symbol.all.count, "duplicate values: \(Symbol.all.filter { s in Symbol.all.filter { $0 == s }.count > 1 })")
    }

    @Test func everyNameIsARealSystemSymbol() {
        let missing = Symbol.all.filter { UIImage(systemName: $0) == nil }
        #expect(missing.isEmpty, "not system symbols: \(missing)")
    }

    /// `all` is written by hand: every `static let` in Symbol.swift must be in it.
    @Test func allListsEveryConstant() throws {
        let source = try String(contentsOf: AXIDTests.sourceFolder.appendingPathComponent("ikut/UI/Symbol.swift"), encoding: .utf8)
        let declared = source.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("static let ") && $0.contains(" = \"")
        }
        #expect(declared.count == Symbol.all.count)
    }
}
