import Foundation
import Testing
@testable import ikut

/// D89: the accessibility identifiers are a contract with the UI tests and qa runners, so they live in one
/// namespace (`AXID`), and every identifier the UI tests look up is a value there.
struct AXIDTests {
    @Test func noTwoIdentifiersShareAValue() {
        let seen = Set(AXID.all)
        #expect(seen.count == AXID.all.count, "duplicate values: \(AXID.all.filter { id in AXID.all.filter { $0 == id }.count > 1 })")
    }

    /// `all` is written by hand: every `static let` in AXID.swift must be in it.
    @Test func allListsEveryConstant() throws {
        let source = try String(contentsOf: Self.sourceFolder.appendingPathComponent("ikut/UI/AXID.swift"), encoding: .utf8)
        let declared = source.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("static let ") && $0.contains(" = \"")
        }
        #expect(declared.count == AXID.all.count)
    }

    @Test func everyIdentifierTheUITestsUseIsInTheNamespace() throws {
        let used = try Self.identifiersUsedByUITests()
        #expect(used.count > 30, "the scan found only \(used.count) identifiers; the pattern is probably stale")
        let known = Set(AXID.all + AXID.suffixless)
        let missing = used.filter { id in !known.contains(id) && !AXID.dynamicPrefixes.contains { id.hasPrefix($0) } }
        #expect(missing.isEmpty, "the UI tests look up identifiers AXID does not have: \(missing.sorted())")
    }

    // MARK: Scanning the UI tests

    private static var sourceFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Identifier-shaped string literals on the lines of `ikutUITests` that look a control up: a subscript on a
    /// query (`buttons["x"]`), `identifier` predicates and matchers, and the `element(...)` / `exists(...)` helpers.
    static func identifiersUsedByUITests() throws -> Set<String> {
        let folder = sourceFolder.appendingPathComponent("ikutUITests")
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        let literal = try NSRegularExpression(pattern: #""([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*)""#)
        let lookup = try NSRegularExpression(pattern: #"\w\[\s*"|identifier|\belement\(|\bexists\(|\bwaitFor\w*\("#)
        var found = Set<String>()
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let code = line.components(separatedBy: "//").first ?? line
                let range = NSRange(code.startIndex..., in: code)
                guard lookup.firstMatch(in: code, range: range) != nil else { continue }
                for m in literal.matches(in: code, range: range) {
                    if let r = Range(m.range(at: 1), in: code) { found.insert(String(code[r])) }
                }
            }
        }
        // Not identifiers: the launch-environment keys read from `app.launchEnvironment["…"]` are upper case and
        // never match; these lower-case literals sit on the same kind of line (log marks, reasons).
        return found.filter { $0.contains(".") || $0.first!.isLowercase && $0.contains(where: \.isUppercase) }
    }
}
