import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing

@testable import ikut

/// The real `deleteAccount` function against the emulators (needs main's functions built: `npm run build` in firebase/functions).
@Suite(.emulator, .serialized)
@MainActor
struct DeleteAccountEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func theCallableRemovesTheMemberAndTheSignIn() async throws {
        let trip = try await EmulatorTrip.make(name: "Delete me")
        let memberPath = FirestorePaths.member(tripId: trip.tripId, userId: trip.uid)
        let db = Firestore.firestore()
        #expect(try await db.document(memberPath).getDocument().exists)

        let steps = DeleteAccount.liveSteps(stopWork: {})
        try await steps.callServer([trip.tripId])

        // The member doc is gone (read as the person's own Admin view is not available; the trip's organiser is
        // gone too, so the rules refuse a read: either way the doc is not served as existing).
        let snapshot = try? await db.document(memberPath).getDocument(source: .server)
        #expect(snapshot?.exists != true)
        nonisolated(unsafe) let user = try #require(Auth.auth().currentUser)
        do {
            try await user.reload()
            Issue.record("the sign-in should be gone")
        } catch {
            #expect(AuthModel.isMissingUser(error as NSError))
        }
    }
}
