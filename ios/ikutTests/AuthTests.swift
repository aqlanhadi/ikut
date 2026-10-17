import Testing
@testable import ikut

struct DisplayNameTests {
    private func name(_ raw: String) -> String? {
        if case .success(let value) = DisplayName.validate(raw) { value } else { nil }
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(name("  Aqlan \n") == "Aqlan")
    }

    @Test func collapsesInternalWhitespace() {
        #expect(name("Siti   Nur\t\nAisyah") == "Siti Nur Aisyah")
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func rejectsEmpty(raw: String) {
        #expect(DisplayName.validate(raw) == .failure(.empty))
    }

    @Test func acceptsExactlyThirty() {
        let thirty = String(repeating: "a", count: 30)
        #expect(name(thirty) == thirty)
    }

    @Test func rejectsThirtyOne() {
        let long = String(repeating: "a", count: 31)
        #expect(DisplayName.validate(long) == .failure(.tooLong(max: 30)))
    }

    @Test func lengthIsCountedAfterCollapsing() {
        let padded = "  " + String(repeating: "a", count: 30) + "   "
        #expect(name(padded) != nil)
    }

    @Test func keepsUnicodeAndApostrophes() {
        #expect(name("Siti Nur 'Aisyah") == "Siti Nur 'Aisyah")
        #expect(name("Zoë Müller") == "Zoë Müller")
    }

    @Test func emojiCountAsOneCharacter() {
        let thirtyEmoji = String(repeating: "🚗", count: 30)
        #expect(name(thirtyEmoji) == thirtyEmoji)
        #expect(name("👨‍👩‍👧 family") == "👨‍👩‍👧 family")
        #expect(DisplayName.validate(String(repeating: "🚗", count: 31)) == .failure(.tooLong(max: 30)))
    }

    @Test func errorsHaveUserFacingMessages() {
        #expect(DisplayName.ValidationError.empty.errorDescription?.isEmpty == false)
        #expect(DisplayName.ValidationError.tooLong(max: 30).errorDescription?.contains("30") == true)
    }
}
