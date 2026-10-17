import Testing
@testable import ikut

struct LocationPermissionTests {
    typealias Status = LocationAccess.Status
    typealias Accuracy = LocationAccess.Accuracy

    @Test(arguments: [Accuracy.full, .reduced], [LocationContext.joiningTrip, .goingToBackground])
    func notDeterminedAsksWhenInUse(accuracy: Accuracy, context: LocationContext) {
        #expect(LocationAccess.nextAction(status: .notDetermined, accuracy: accuracy, context: context) == .requestWhenInUse)
    }

    @Test(arguments: [Accuracy.full, .reduced], [LocationContext.joiningTrip, .goingToBackground])
    func deniedShowsSettings(accuracy: Accuracy, context: LocationContext) {
        #expect(LocationAccess.nextAction(status: .denied, accuracy: accuracy, context: context) == .showSettingsPrompt)
    }

    @Test(arguments: [Status.whenInUse, .always], [LocationContext.joiningTrip, .goingToBackground])
    func reducedAccuracyAsksForFull(status: Status, context: LocationContext) {
        #expect(LocationAccess.nextAction(status: status, accuracy: .reduced, context: context) == .requestFullAccuracy)
    }

    @Test
    func whenInUseFullAccuracy() {
        #expect(LocationAccess.nextAction(status: .whenInUse, accuracy: .full, context: .joiningTrip) == .ready)
        #expect(LocationAccess.nextAction(status: .whenInUse, accuracy: .full, context: .goingToBackground) == .showAlwaysExplainer)
    }

    @Test(arguments: [LocationContext.joiningTrip, .goingToBackground])
    func alwaysFullAccuracyIsReady(context: LocationContext) {
        #expect(LocationAccess.nextAction(status: .always, accuracy: .full, context: context) == .ready)
    }
}
