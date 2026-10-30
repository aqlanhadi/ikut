import Observation
import SwiftUI

/// One reason chip on the request sheet.
struct StopReason: Identifiable, Equatable, Sendable {
    let type: EventType
    let label: String
    let symbol: String
    var id: String { type.rawValue }

    /// Fuel, Toilet, Food, Rest, in the design's order. (The design's "Detour" has no event type.)
    static let all: [StopReason] = [
        StopReason(type: .stopFuel, label: "Fuel", symbol: Symbol.fuel),
        StopReason(type: .stopToilet, label: "Toilet", symbol: Symbol.toilet),
        StopReason(type: .stopFood, label: "Food", symbol: Symbol.food),
        StopReason(type: .stopRest, label: "Rest", symbol: Symbol.rest),
    ]
}

/// State behind the card's ask steps: the chosen reason, an optional message, and the send.
@MainActor @Observable
final class RequestStopModel {
    enum Sending: Equatable {
        case idle
        case sending
        case failed(String)
    }

    let context: StopContext
    private let service: any StopServing

    private(set) var reason: StopReason?
    private(set) var sending: Sending = .idle
    /// What a passenger typed; empty means no message. Never more than 280 characters.
    var message = "" {
        didSet {
            if message.count > StopLogic.maxMessageLength { message = String(message.prefix(StopLogic.maxMessageLength)) }
        }
    }

    init(context: StopContext, service: any StopServing = StopService()) {
        self.context = context
        self.service = service
    }

    var canSend: Bool { reason != nil && sending != .sending }

    func choose(_ reason: StopReason) {
        self.reason = reason
        sending = .idle
    }

    /// Back to the reason tiles (the message stays out of the next ask).
    func clearReason() {
        reason = nil
        message = ""
        sending = .idle
    }

    /// Sends the request. Returns true on success.
    func send() async -> Bool {
        guard let reason, canSend else { return false }
        guard let snapshot = context.snapshot() else {
            sending = .failed("Your phone hasn’t found where you are yet. Try again in a moment.")
            return false
        }
        sending = .sending
        do {
            _ = try await service.request(
                type: reason.type, message: StopLogic.cleanedMessage(message), context: context, snapshot: snapshot)
            sending = .idle
            return true
        } catch {
            sending = .failed("Couldn’t reach the convoy. Try again in a moment.")
            return false
        }
    }
}
