import Foundation

/// Where the lobby's Leave trip and End trip are (D110): asked, then working while the server answers, then done. The
/// sheet stays up through all of it; the row shows "Leaving…" or "Ending…" while it works, and only a write that has
/// landed lets the screen exit (leaving stops location sharing, so it is never claimed early).
struct ExitFlow: Equatable {
    /// `handOver` (D106): the organiser gives the trip to another member and then leaves it; it is the organiser's
    /// Leave trip. Its steps are idle, `picking` (the list of who takes over), asking (the alert naming them), working
    /// ("Handing over…", the hand-over call then the leave), and landed once both went through.
    enum Kind: Equatable { case leave, end, newCode, handOver }
    enum Phase: Equatable { case idle, picking, asking(Kind), working(Kind), landed(Kind) }

    private(set) var phase = Phase.idle
    /// What the last write said when it didn't land; cleared by the next try.
    private(set) var error: String?
    /// Who the organiser chose in `picking` (their user id and name), kept through the ask and the work.
    private(set) var target: Target?
    struct Target: Equatable { var id: String; var name: String }

    var asking: Kind? { if case .asking(let kind) = phase { kind } else { nil } }
    var working: Kind? { if case .working(let kind) = phase { kind } else { nil } }
    var picking: Bool { phase == .picking }
    /// The kind whose row shows its progress: while the write is out, and once it landed until the screen changes.
    var progress: Kind? {
        switch phase {
        case .working(let kind), .landed(let kind): kind
        case .idle, .picking, .asking: nil
        }
    }
    /// A write is out or has landed: the other rows rest, and so does Back to trips.
    var busy: Bool { progress != nil }
    var canGoBack: Bool { !busy }
    /// A tap on a row's confirm may start a write.
    var canStart: Bool { if case .idle = phase { true } else if case .asking = phase { true } else { false } }

    mutating func ask(_ kind: Kind) {
        guard phase == .idle, kind != .handOver else { return }
        phase = .asking(kind)
    }

    /// "Hand over and leave" was tapped: the list of who could take over shows.
    mutating func startPicking() {
        guard phase == .idle else { return }
        phase = .picking
        target = nil
    }

    /// Cancel in the list: back to the rows.
    mutating func stopPicking() {
        if phase == .picking { phase = .idle }
    }

    /// Someone was picked: the alert asks about them.
    mutating func choose(id: String, name: String) {
        guard phase == .picking else { return }
        target = Target(id: id, name: name)
        phase = .asking(.handOver)
    }

    /// The ask closed. Closing after the button was tapped (the dialog goes either way, and may close before the work's
    /// task starts) leaves the work alone; so a cancelled ask is always back to idle, the hand-over's too, and the
    /// work can still start from idle.
    mutating func cancel(_ kind: Kind) {
        if phase == .asking(kind) { phase = .idle }
    }

    /// The button in the ask was tapped.
    mutating func confirm(_ kind: Kind) {
        switch phase {
        case .idle, .asking:
            guard kind != .handOver || target != nil else { return }
            phase = .working(kind)
            error = nil
        case .picking, .working, .landed: break
        }
    }

    /// The write didn't land: the row is back to normal and the sheet shows what happened.
    mutating func fail(_ message: String) {
        guard working != nil else { return }
        phase = .idle
        error = message
    }

    /// The write landed. True once, for Leave: the screen exits now. End holds its "Ending…" until the trip's end takes
    /// the screen to the recap by itself. A new code (D104) has nowhere to go: the row returns and the trip's own listener
    /// shows the new code wherever the code and QR are.
    mutating func land() -> Bool {
        guard let kind = working else { return false }
        switch kind {
        case .leave, .handOver: phase = .landed(kind); return true
        case .end: phase = .landed(kind); return false
        case .newCode: phase = .idle; return false
        }
    }
}

/// Runs Leave, End, New code and Hand over for the lobby: the write, then land or fail, then exit once. The screen holds it in `@State`.
@Observable @MainActor
final class ExitRunner {
    var flow = ExitFlow()
    /// The screen is still the open trip's: a write landing after it went (Back, the trip closed) exits nothing.
    var live = true

    /// Returns the error's text when the write didn't land.
    @discardableResult
    func run(_ kind: ExitFlow.Kind, write: () async throws -> Void, exit: () -> Void) async -> String? {
        guard flow.canStart else { return nil }
        flow.confirm(kind)
        do {
            try await write()
            if flow.land(), live { exit() }
            return nil
        } catch {
            flow.fail(error.localizedDescription)
            return error.localizedDescription
        }
    }
}
