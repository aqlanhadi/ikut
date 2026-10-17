import Foundation
import Testing
@testable import ikut

struct DeepLinkTests {
    private func parse(_ s: String) -> DeepLink? { URL(string: s).flatMap(DeepLink.parse) }

    @Test(arguments: [
        "ikut://join/K5G4SV",
        "ikut://join/k5g4sv",
        "ikut://join/K5G-4SV",
        "ikut://join/K5G%204SV",
        "ikut://join/K5G4SV/",
        "ikut://join?code=K5G4SV",
        "ikut://join/?code=k5g-4sv",
        "ikut://join?code=K5G%204SV",
        "IKUT://JOIN/K5G4SV",
        "https://ikut.app/join/K5G4SV",
        "https://anything.example.org/join/k5g4sv",
        "https://ikut.app/join/K5G-4SV",
    ])
    func acceptsForms(_ s: String) {
        #expect(parse(s) == .join(code: "K5G4SV"))
    }

    @Test(arguments: [
        "http://ikut.app/join/K5G4SV",
        "ftp://ikut.app/join/K5G4SV",
        "other://join/K5G4SV",
        "ikut://create/K5G4SV",
        "ikut://K5G4SV",
        "ikut://join",
        "ikut://join/",
        "ikut://join/K5G4S",
        "ikut://join/K5G4SVX",
        "ikut://join/K5G4S0",
        "ikut://join/K5G4S!",
        "ikut://join/K5G4SV/extra",
        "ikut://join?code=",
        "ikut://join?code=K5G4S",
        "ikut://join?code=K5G4SVX",
        "ikut://join?other=K5G4SV",
        "https://ikut.app/K5G4SV",
        "https://ikut.app/trip/K5G4SV",
        "https://ikut.app/join/K5G4SV/more",
        "https://ikut.app/join",
        "https:///join/K5G4SV",
    ])
    func rejects(_ s: String) {
        #expect(parse(s) == nil)
    }

    @Test func scannedPayloads() {
        #expect(DeepLink.joinCode(fromScanned: "ikut://join/K5G4SV") == "K5G4SV")
        #expect(DeepLink.joinCode(fromScanned: "https://ikut.app/join/k5g4sv") == "K5G4SV")
        #expect(DeepLink.joinCode(fromScanned: "  K5G4SV\n") == "K5G4SV")
        #expect(DeepLink.joinCode(fromScanned: "k5g-4sv") == "K5G4SV")
        #expect(DeepLink.joinCode(fromScanned: "K5G 4SV") == "K5G4SV")
        #expect(DeepLink.joinCode(fromScanned: "") == nil)
        #expect(DeepLink.joinCode(fromScanned: "K5G4S") == nil)
        #expect(DeepLink.joinCode(fromScanned: "K5G4SVX") == nil)
        #expect(DeepLink.joinCode(fromScanned: "hello world") == nil)
        #expect(DeepLink.joinCode(fromScanned: "https://example.com/menu") == nil)
        #expect(DeepLink.joinCode(fromScanned: "ikut://join/short") == nil)
        #expect(DeepLink.joinCode(fromScanned: "WIFI:T:WPA;S:x;P:y;;") == nil)
    }
}
