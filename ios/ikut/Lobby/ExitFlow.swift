import Foundation

/// Where the lobby's Leave trip and End trip are (D110): asked, then working while the server answers, then done. The
/// sheet stays up through all of it; the row shows "Leaving…" or "Ending…" while it works, and only a write that has
/// landed lets the screen exit (leaving stops location sharing, so it is never claimed early).
struct ExitFlow: Equatable {
    enum Kind: Equatable { case leave, end }
    enum Phase: Equatable { case idle, asking(Kind), working(Kind), landed(Kind) }

    private(set) var phase = Phase.idle
    /// What the last write said when it didn't land; cleared by the next try.
    private(set) var error: String?

    var asking: Kind? { if case .asking(let kind) = phase { kind } else { nil } }
    var working: Kind? { if case .working(let kind) = phase { kind } else { nil } }
    /// A write is out: the other rows rest.
    var busy: Bool { working != nil }

    mutating func ask(_ kind: Kind) {
        guard phase == .idle else { return }
        phase = .asking(kind)
    }

    /// The ask closed. Closing after the button was tapped (the dialog goes either way) leaves the work alone.
    mutating func cancel(_ kind: Kind) {
        if phase == .asking(kind) { phase = .idle }
    }

    /// The button in the ask was tapped.
    mutating func confirm(_ kind: Kind) {
        switch phase {
        case .idle, .asking: phase = .working(kind); error = nil
        case .working, .landed: break
        }
    }

    /// The write didn't land: the row is back to normal and the sheet shows what happened.
    mutating func fail(_ message: String) {
        guard working != nil else { return }
        phase = .idle
        error = message
    }

    /// The write landed. True once, for Leave: the screen exits now. End settles back to idle: the trip's end takes the
    /// screen to the recap by itself.
    mutating func land() -> Bool {
        guard let kind = working else { return false }
        switch kind {
        case .leave: phase = .landed(kind); return true
        case .end: phase = .idle; return false
        }
    }
}
