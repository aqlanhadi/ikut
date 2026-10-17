import Foundation
import UIKit

/// Broadcasts this phone's car position while a trip is active. Used on the tracker phone only.
///
/// Fixes from the `LocationSource` go through `PositionBuilder` (offsets, heading, speed) and then
/// `PositionPublisher` (throttle, one write in flight, latest-only).
@MainActor
final class TrackingService {
    private let source: LocationSource
    private let writer: PositionWriting
    private let clock: TrackingClock
    private let batteryLevel: @MainActor () -> Float
    private let timing: PositionPublisher.Timing

    private var builder: PositionBuilder?
    private var publisher: PositionPublisher?
    private var generation = 0

    private(set) var isTracking = false

    init(
        source: LocationSource? = nil,
        writer: PositionWriting = FirestorePositionWriter(),
        clock: TrackingClock? = nil,
        timing: PositionPublisher.Timing = .init(),
        batteryLevel: @escaping @MainActor () -> Float = { UIDevice.current.batteryLevel }
    ) {
        self.source = source ?? CoreLocationSource()
        self.writer = writer
        self.clock = clock ?? SystemTrackingClock()
        self.timing = timing
        self.batteryLevel = batteryLevel
    }

    /// Starts location updates and position writes. Restarts if already tracking.
    func start(tripId: String, carId: String, mainRoute: RouteLine, carRoute: RouteLine?) {
        stop()
        generation += 1
        let current = generation
        isTracking = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        builder = PositionBuilder(mainRoute: mainRoute, carRoute: carRoute)
        publisher = PositionPublisher(
            tripId: tripId, carId: carId, writer: writer, clock: clock, timing: timing)
        source.start { [weak self] fix in
            Task { @MainActor in self?.handle(fix, generation: current) }
        }
    }

    /// Stops location updates immediately and drops anything not yet written.
    func stop() {
        guard isTracking else { return }
        isTracking = false
        generation += 1
        source.stop()
        publisher?.stop()
        publisher = nil
        builder = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func handle(_ fix: LocationFix, generation: Int) {
        guard isTracking, generation == self.generation, var builder, let publisher else { return }
        let position = builder.build(from: fix, battery: PositionBuilder.battery(batteryLevel()))
        self.builder = builder
        publisher.submit(position)
    }
}
