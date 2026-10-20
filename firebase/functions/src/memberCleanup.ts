import { FieldValue, getFirestore, type Firestore, type Transaction } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { onDocumentDeleted } from "firebase-functions/v2/firestore";
import type { Car, Member, Trip } from "./model.js";
import { hasOtherRider } from "./joinTrip.js";

export type CleanupOutcome =
  | { kind: "skipped"; reason: "trip-not-active" | "car-missing" | "lead-car" }
  | { kind: "kept"; trackerReleased: boolean }
  | { kind: "deleted" };

/**
 * Runs after a member doc is removed (they left, or the organizer removed them). Mirrors the
 * "previous car" rule in joinTrip: an empty non-lead car is deleted with its position; otherwise,
 * if the leaver was its tracker, the tracker duty is released. Ended trips are left alone; the
 * retention sweep handles them.
 */
export async function cleanupAfterMemberLeft(
  db: Firestore,
  tripId: string,
  userId: string,
  removedMember: Pick<Member, "carId">,
): Promise<CleanupOutcome> {
  const tripRef = db.collection("trips").doc(tripId);
  const carRef = tripRef.collection("cars").doc(removedMember.carId);
  const membersCol = tripRef.collection("members");

  return db.runTransaction(async (tx: Transaction): Promise<CleanupOutcome> => {
    // All reads first.
    const tripSnap = await tx.get(tripRef);
    const trip = tripSnap.data() as Trip | undefined;
    if (!tripSnap.exists || !trip || trip.status !== "active") {
      return { kind: "skipped", reason: "trip-not-active" };
    }
    const carSnap = await tx.get(carRef);
    if (!carSnap.exists) return { kind: "skipped", reason: "car-missing" };
    const car = carSnap.data() as Car;

    // The leaver's own doc is already gone, but hasOtherRider skips it anyway.
    if (!(await hasOtherRider(tx, membersCol, carRef.id, userId)) && !car.isLead) {
      tx.delete(carRef);
      tx.delete(tripRef.collection("positions").doc(carRef.id));
      return { kind: "deleted" };
    }

    // Writes. The lead car is never deleted, but a departed tracker must still be released.
    const trackerReleased = car.trackerUserId === userId;
    if (trackerReleased) tx.update(carRef, { trackerUserId: FieldValue.delete() });
    return { kind: "kept", trackerReleased };
  });
}

/** Fires when a member doc is deleted: a member leaving a trip, or an organizer removing them. */
export const onMemberDeleted = onDocumentDeleted("trips/{tripId}/members/{userId}", async (event) => {
  const { tripId, userId } = event.params;
  const removed = event.data?.data() as Member | undefined;
  if (!removed?.carId) return;
  const outcome = await cleanupAfterMemberLeft(getFirestore(), tripId, userId, removed);
  logger.info("onMemberDeleted: cleanup", { tripId, userId, outcome });
});
