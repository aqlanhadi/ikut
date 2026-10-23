import CoreLocation
import Observation
import SwiftUI

/// State for the join flow: code, trip preview, name, car choice and tracker toggle.
@Observable @MainActor
final class JoinModel {
    enum CarSelection: Equatable {
        case existing(String)
        case newCar
    }

    private(set) var code = ""
    private(set) var preview: TripPreview?
    private(set) var isLoadingPreview = false
    private(set) var isJoining = false
    /// Set after a join where someone else already tracks the chosen car.
    private(set) var trackerTakenResult: JoinResult?
    var displayName: String
    var newCarName = ""
    private(set) var selection: CarSelection?
    var tracker = true
    var errorMessage: String?
    /// How far and how long from here to the destination, once the phone's location and MapKit have answered.
    private(set) var ticketDrive: TicketDrive?

    @ObservationIgnored private let api: any JoinAPI
    @ObservationIgnored private let driveFromHere: @MainActor (CLLocationCoordinate2D) async -> TicketDrive?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var driveTask: Task<Void, Never>?
    @ObservationIgnored private var newCarNameEdited = false

    /// `initialCode` (e.g. from a link or QR) is normalised and shown straight away;
    /// call `start()` once the screen appears to load its preview.
    init(
        displayName: String, initialCode: String? = nil, api: any JoinAPI = LiveJoinAPI(),
        driveFromHere: @escaping @MainActor (CLLocationCoordinate2D) async -> TicketDrive? = { await TicketDrive.fromHere(to: $0) }
    ) {
        self.displayName = displayName
        self.api = api
        self.driveFromHere = driveFromHere
        if let initialCode { code = JoinService.normalizeCode(initialCode) }
    }

    /// Loads the preview for a prefilled code; no-op without a complete code or if already loading/loaded.
    func start() {
        guard JoinService.isCompleteCode(code), preview == nil, !isLoadingPreview else { return }
        loadPreview()
    }

    var cars: [PreviewCar] { preview?.cars ?? [] }
    var newCarColor: String { JoinService.chooseColor(existing: cars) }

    var selectedCar: PreviewCar? {
        if case .existing(let id) = selection { return cars.first { $0.id == id } }
        return nil
    }

    /// Existing car chosen and someone else is already its tracker.
    var selectedCarHasTracker: Bool { selectedCar?.hasTracker ?? false }

    var nameIsValid: Bool {
        if case .success = DisplayName.validate(displayName) { true } else { false }
    }

    var newCarNameIsValid: Bool {
        let n = newCarName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && n.count <= DisplayName.maxLength
    }

    var canJoin: Bool {
        guard preview != nil, !isJoining, nameIsValid, let selection else { return false }
        if selection == .newCar { return newCarNameIsValid }
        return true
    }

    /// Call whenever the code field changes; fetches the preview once the code is complete.
    func codeChanged(_ raw: String) {
        let normalized = JoinService.normalizeCode(raw)
        if normalized != code {
            code = normalized
            reset()
        }
        guard JoinService.isCompleteCode(normalized), preview == nil, !isLoadingPreview else { return }
        loadPreview()
    }

    func newCarNameDidEdit() { newCarNameEdited = true }

    func retryPreview() {
        guard JoinService.isCompleteCode(code) else { return }
        loadPreview()
    }

    func select(_ car: PreviewCar) {
        selection = .existing(car.id)
        tracker = !car.hasTracker
        errorMessage = nil
    }

    func selectNewCar() {
        selection = .newCar
        tracker = true
        errorMessage = nil
        if !newCarNameEdited || newCarName.isEmpty {
            newCarName = TripService.carName(for: firstName)
            newCarNameEdited = false
        }
    }

    private var firstName: String {
        (try? DisplayName.validate(displayName).get()) ?? displayName.trimmingCharacters(in: .whitespaces)
    }

    private func reset() {
        previewTask?.cancel()
        preview = nil
        isLoadingPreview = false
        selection = nil
        errorMessage = nil
        trackerTakenResult = nil
        ticketDrive = nil
        driveTask?.cancel()
    }

    private func loadPreview() {
        previewTask?.cancel()
        let requested = code
        errorMessage = nil
        isLoadingPreview = true
        previewTask = Task {
            do {
                let result = try await api.preview(code: requested)
                guard !Task.isCancelled, requested == code else { return }
                preview = result
                loadDrive(for: result)
            } catch {
                guard !Task.isCancelled, requested == code else { return }
                errorMessage = JoinService.map(error).message
            }
            isLoadingPreview = false
        }
    }

    /// The quiet "About 2 h 10 from you · 185 km" line: one drive request from the phone's location to the destination.
    /// Nothing is shown when there's no destination coordinate, no location or no road.
    private func loadDrive(for preview: TripPreview) {
        driveTask?.cancel()
        guard let destination = preview.destinationCoordinate?.coordinate else { return }
        let requested = code
        driveTask = Task {
            let drive = await driveFromHere(destination)
            guard !Task.isCancelled, requested == code else { return }
            ticketDrive = drive
        }
    }

    /// Joins; returns the result unless a "tracker taken" note should be shown first.
    func join() async -> JoinResult? {
        guard canJoin, let selection else { return nil }
        let car: JoinCarChoice
        switch selection {
        case .existing(let id): car = .existing(id: id)
        case .newCar:
            car = .new(
                name: newCarName.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                color: newCarColor)
        }
        isJoining = true
        errorMessage = nil
        defer { isJoining = false }
        do {
            let result = try await api.join(
                code: code, displayName: firstName, car: car, tracker: tracker)
            if result.trackerTaken {
                trackerTakenResult = result
                return nil
            }
            return result
        } catch {
            errorMessage = JoinService.map(error).message
            return nil
        }
    }
}
