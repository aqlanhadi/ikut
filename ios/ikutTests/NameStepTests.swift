import MapKit
import SwiftUI
import Testing

@testable import ikut

/// The name as the first step of Where to? in Home's one sheet (D112), and the state the join and create name steps share.
@MainActor
struct NameStepTests {
    private let kl = CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687)
    private func camera(_ span: Double) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: kl, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }
    private struct Down: Error, LocalizedError { var errorDescription: String? { "No signal" } }

    @Test func signedOutStartsWithTheNameAndSignedInGoesStraightOn() {
        #expect(HomeModel.newTripStart(signedIn: false) == .name)
        #expect(HomeModel.newTripStart(signedIn: true) == .location)
    }

    @Test func listThenNameThenWhereToAreOneSheetWithNoSeparateNameSheet() {
        let model = HomeModel()
        #expect(model.mode == .list)
        model.askingName = true
        model.beginNaming(camera: camera(3), goBack: { _ in })
        #expect(model.nameStep != nil)
        #expect(model.flow == nil)
        #expect(model.mode == .join)
        // Signed in: Where to? takes the same sheet over from the name step.
        model.creating = true
        model.beginCreate(camera: camera(3), goBack: { _ in })
        #expect(model.nameStep == nil)
        #expect(model.flow != nil)
        #expect(!model.askingName)
        #expect(model.mode == .whereTo)
    }

    @Test func closeOnTheNameStepReturnsToTheListWithNothingWritten() {
        let model = HomeModel()
        model.askingName = true
        model.beginNaming(camera: camera(3), goBack: { _ in })
        model.closeNaming()
        #expect(model.nameStep == nil)
        #expect(model.flow == nil)
        #expect(!model.askingName)
        #expect(model.mode == .list)
    }

    @Test func aLinkWhileNamingLeavesTheNameStepForJoin() {
        let model = HomeModel()
        model.askingName = true
        model.beginNaming(camera: camera(3), goBack: { _ in })
        model.beginJoin(JoinStart(code: "K7M2QX"), camera: camera(0.1), displayName: nil, signedIn: false, location: .notDetermined,
                        api: JoinDemo.api())
        #expect(model.nameStep == nil)
        #expect(model.joinFlow != nil)
        #expect(!model.askingName)
    }

    @Test func nameStepStateSignsInOnceAndKeepsTheSpinnerUntilTheNextStepTakesOver() async {
        let step = NameStepState(name: "Nurul")
        var signedInAs: String?
        let ok = await step.submit { signedInAs = $0 }
        #expect(ok)
        #expect(signedInAs == "Nurul")
        #expect(step.isWorking)
        #expect(step.error == nil)
    }

    @Test func nameStepStateShowsTheErrorAndPutsContinueBack() async {
        let step = NameStepState(name: "Nurul")
        let ok = await step.submit { _ in throw Down() }
        #expect(!ok)
        #expect(!step.isWorking)
        #expect(step.error == "No signal")
        // Another try works.
        #expect(await step.submit { _ in })
    }

    @Test func nameStepStateWontSubmitAnInvalidNameOrWhileWorking() async {
        let empty = NameStepState(name: "  ")
        var calls = 0
        #expect(!empty.isValid)
        #expect(!(await empty.submit { _ in calls += 1 }))
        let busy = NameStepState(name: "Nurul")
        busy.isWorking = true
        #expect(!(await busy.submit { _ in calls += 1 }))
        #expect(calls == 0)
    }

    @Test func theJoinStepsAttemptReadsTheSameWay() async {
        #expect(await NameStepState.attempt(name: "Nurul", signIn: { _ in }) == nil)
        #expect(await NameStepState.attempt(name: "Nurul", signIn: { _ in throw Down() }) == "No signal")
    }

    @Test func aLinkWhileNamingMeansNoWhereToUnderTheJoinSteps() {
        let model = HomeModel()
        model.askingName = true
        model.beginNaming(camera: camera(3), goBack: { _ in })
        model.beginJoin(JoinStart(code: "K7M2QX"), camera: camera(0.1), displayName: nil, signedIn: false, location: .notDetermined,
                        api: JoinDemo.api())
        // The sign-in task that was in flight comes back and asks for Where to?
        #expect(!model.creatingAfterName())
        #expect(!model.creating)
        model.beginCreate(camera: camera(3), goBack: { _ in })
        #expect(model.flow == nil)
        model.endNameHandOff()
        #expect(model.joinFlow != nil)
    }

    @Test func afterSignInWhereToIsAskedForAndTheHandOffLeavesItBe() {
        let model = HomeModel()
        model.askingName = true
        model.beginNaming(camera: camera(3), goBack: { _ in })
        #expect(model.creatingAfterName())
        #expect(model.creating)
        model.endNameHandOff()
        #expect(model.nameStep != nil)
        model.beginCreate(camera: camera(3), goBack: { _ in })
        #expect(model.flow != nil)
    }

    @Test func aLocationAnswerThatStopsTheTripPutsTheListBack() {
        let model = HomeModel()
        model.askingName = true
        model.beginNaming(camera: camera(3), goBack: { _ in })
        // Signed in, but the location check ended without Where to?.
        model.endNameHandOff()
        #expect(model.nameStep == nil)
        #expect(!model.askingName)
        #expect(model.mode == .list)
    }
}
