import { FieldValue, type DocumentReference, type Firestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { HttpsError } from "firebase-functions/v2/https";
import { CREATE_LIMITS } from "./createLimit.js";
import { GUESS_LIMITS } from "./guessLimit.js";
import { handOverTripForUser } from "./handOverTrip.js";
import type { Car, Member, Trip } from "./model.js";
import { isValidTripId } from "./rotateTrip.js";
import { summariseTrip } from "./summary.js";

/**
 * Account deletion (A4, decision #737): afterwards nothing personal about the person is left, then the Auth user goes.
 * The body of the `deleteAccount` callable apart from sign-in and the Auth call (`deleteAccountCall.ts`), so tests can
 * run it against the emulator with a fake Auth step and a failure in the middle.
 *
 * Per trip the person is in (found by `members.userId` across all trips, by `trips.organizerId`, and by the trip ids the
 * app sends as a hint, which also covers members from before `userId` existed; a hint only counts when the caller has a
 * member doc there):
 *  1. Organiser of an active trip: hand it to another member (`handOverTripForUser`, same rules and limits) when others
 *     remain; if there is nobody, or the hand-over is refused, end it and write its summary now (`summariseTrip`), so the
 *     recap counts the people who were in it before their docs go.
 *  2. Delete events they authored (with their stop votes), their stop votes and skip answers, and clear `closedBy`,
 *     `skippedBy`, `leftBy`, `stoppedBy` and `removedBy` where they name the person.
 *  3. Cars: delete their live position; a car with no other rider is deleted (the lead car of a still-active trip only
 *     loses its tracker); a car they tracked that others ride in loses its tracker.
 *  4. Last, in one batch: their `removed` record, their member doc (name, push token) and, on a trip that is left with
 *     `organizerId` of theirs (an ended trip), the organiser id on the trip and its code claim becomes "".
 * The member doc goes last in each trip and the Auth user after everything, so a retry after any failure finds the same
 * trips again and finishes; every step is safe to repeat. Positions are only ever deleted here, never copied or kept.
 */
export const MAX_TRIP_HINTS = 200;

export interface DeleteAccountDeps {
  /** Deletes the Firebase Auth user; called once, after every other step succeeded. */
  deleteAuthUser: (uid: string) => Promise<void>;
  /** Test hook, called before each trip is cleaned (a throw simulates a failure part-way). */
  beforeTrip?: (tripId: string) => void | Promise<void>;
}

export function parseDeleteInput(data: unknown): string[] {
  if (data === null || data === undefined) return [];
  const hints = (data as { tripIds?: unknown }).tripIds;
  if (hints === undefined || hints === null) return [];
  if (!Array.isArray(hints) || hints.length > MAX_TRIP_HINTS || !hints.every(isValidTripId)) {
    throw new HttpsError("invalid-argument", "Something was wrong with that request.");
  }
  return [...new Set(hints as string[])];
}

/** Every trip id that has this person in it: member docs, organiser, and the hints they have a member doc for. */
export async function tripsOf(db: Firestore, uid: string, hints: string[]): Promise<string[]> {
  const ids = new Set<string>();
  const byMember = await db.collectionGroup("members").where("userId", "==", uid).get();
  for (const d of byMember.docs) {
    const id = d.ref.parent.parent?.id;
    if (id) ids.add(id);
  }
  for (const d of (await db.collection("trips").where("organizerId", "==", uid).get()).docs) ids.add(d.id);
  for (const id of hints) {
    if ((await db.collection("trips").doc(id).collection("members").doc(uid).get()).exists) ids.add(id);
  }
  return [...ids].sort();
}

async function endTrip(db: Firestore, tripId: string): Promise<void> {
  const ref = db.collection("trips").doc(tripId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (snap.exists && snap.get("status") === "active") {
      tx.update(ref, { status: "ended", endedAt: FieldValue.serverTimestamp() });
    }
  });
  await summariseTrip(db, tripId);
}

/** Step 1. Afterwards the trip is not active with this person as organiser. */
async function releaseOrganiser(db: Firestore, uid: string, tripId: string): Promise<void> {
  const ref = db.collection("trips").doc(tripId);
  const trip = (await ref.get()).data() as Trip | undefined;
  if (!trip || trip.status !== "active" || trip.organizerId !== uid) return;
  const others = (await ref.collection("members").get()).docs.filter((d) => d.id !== uid);
  if (others.length > 0) {
    // Prefer someone in the organiser's own car (the lead label then stays), else the first other member.
    const mine = (await ref.collection("members").doc(uid).get()).data() as Member | undefined;
    const target = others.find((d) => mine && (d.data() as Member).carId === mine.carId) ?? others[0]!;
    try {
      await handOverTripForUser(db, uid, tripId, target.id);
      return;
    } catch (err) {
      // A refusal (limit, trip changed) falls through to ending; anything else is a failure to retry.
      if (!(err instanceof HttpsError)) throw err;
      logger.info("deleteAccount: hand-over refused, ending trip", { tripId, code: err.code });
    }
  }
  await endTrip(db, tripId);
}

async function deleteAll(refs: DocumentReference[]): Promise<void> {
  for (const r of refs) await r.delete();
}

/** Steps 2 to 4 for one trip. */
export async function cleanTrip(db: Firestore, uid: string, tripId: string): Promise<boolean> {
  const tripRef = db.collection("trips").doc(tripId);
  if (!(await tripRef.get()).exists) return false;
  const memberRef = tripRef.collection("members").doc(uid);
  const mine = await memberRef.get();
  if (!mine.exists && (await tripRef.get()).get("organizerId") !== uid) return false;

  await releaseOrganiser(db, uid, tripId);
  const trip = (await tripRef.get()).data() as Trip;

  // Events they wrote (recursiveDelete takes the stop votes under them), stop votes and skip answers they gave.
  const authored = await tripRef.collection("events").where("authorId", "==", uid).get();
  for (const e of authored.docs) await db.recursiveDelete(e.ref);
  const events = await tripRef.collection("events").get();
  for (const e of events.docs) {
    if (e.get("closedBy") === uid) await e.ref.update({ closedBy: FieldValue.delete() });
    await deleteAll((await e.ref.collection("votes").where("userId", "==", uid).get()).docs.map((d) => d.ref));
  }
  for (const s of (await tripRef.collection("stops").get()).docs) {
    await deleteAll((await s.ref.collection("answers").where("userId", "==", uid).get()).docs.map((d) => d.ref));
    const clear: Record<string, FieldValue> = {};
    if (s.get("skippedBy") === uid) clear.skippedBy = FieldValue.delete();
    if (s.get("leftBy") === uid) clear.leftBy = FieldValue.delete();
    if (Object.keys(clear).length > 0) await s.ref.update(clear);
  }
  if (trip.stoppedBy === uid) await tripRef.update({ stoppedBy: FieldValue.delete() });

  // Cars: their live position, and the car itself when nobody else rides in it.
  const members = (await tripRef.collection("members").get()).docs.filter((d) => d.id !== uid);
  const carIds = new Set<string>();
  if (mine.exists) carIds.add((mine.data() as Member).carId);
  for (const c of (await tripRef.collection("cars").where("trackerUserId", "==", uid).get()).docs) carIds.add(c.id);
  for (const carId of carIds) {
    const carRef = tripRef.collection("cars").doc(carId);
    const car = (await carRef.get()).data() as Car | undefined;
    if (!car) {
      await tripRef.collection("positions").doc(carId).delete();
      continue;
    }
    const soleRider = !members.some((m) => (m.data() as Member).carId === carId);
    const tracked = car.trackerUserId === uid;
    if (soleRider || tracked) await tripRef.collection("positions").doc(carId).delete();
    if (soleRider && !(car.isLead && trip.status === "active")) await carRef.delete();
    else if (tracked) await carRef.update({ trackerUserId: FieldValue.delete() });
  }

  // Who they removed from a trip, and the record of anyone naming them.
  const removed = tripRef.collection("removed");
  for (const r of (await removed.where("removedBy", "==", uid).get()).docs) await r.ref.update({ removedBy: FieldValue.delete() });

  // Last: the member doc, with the organiser id on a trip that still carries theirs.
  const batch = db.batch();
  batch.delete(removed.doc(uid));
  batch.delete(memberRef);
  if (trip.organizerId === uid) {
    batch.update(tripRef, { organizerId: "" });
    const claim = db.collection("codes").doc(trip.code);
    const claimSnap = await claim.get();
    if (claimSnap.exists && claimSnap.get("tripId") === tripId) batch.update(claim, { organizerId: "" });
  }
  await batch.commit();
  return true;
}

export async function deleteAccountForUser(
  db: Firestore, uid: string, data: unknown, deps: DeleteAccountDeps,
): Promise<{ ok: true }> {
  const hints = parseDeleteInput(data);
  const trips = await tripsOf(db, uid, hints);
  for (const tripId of trips) {
    await deps.beforeTrip?.(tripId);
    await cleanTrip(db, uid, tripId);
  }
  // Code claims still naming them (their trip was deleted or never reached): the claim of a gone trip goes, any other is blanked.
  for (const c of (await db.collection("codes").where("organizerId", "==", uid).get()).docs) {
    if ((await db.collection("trips").doc(c.get("tripId") as string).get()).exists) await c.ref.update({ organizerId: "" });
    else await c.ref.delete();
  }
  await db.collection(CREATE_LIMITS).doc(uid).delete();
  await db.collection(GUESS_LIMITS).doc(uid).delete();
  await deps.deleteAuthUser(uid);
  logger.info("deleteAccount: done", { trips: trips.length });
  return { ok: true };
}
