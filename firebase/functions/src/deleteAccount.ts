import { FieldValue, type DocumentReference, type Firestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { HttpsError } from "firebase-functions/v2/https";
import { CREATE_LIMITS } from "./createLimit.js";
import { GUESS_LIMITS } from "./guessLimit.js";
import { handOverTransaction } from "./handOverTrip.js";
import type { Car, Member, Trip } from "./model.js";
import { TRIP_KEYED_LIMITS } from "./fullPurge.js";
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
 *  1. Organiser of an active trip: hand it to another member (`handOverTransaction`, the hand-over's own checks but
 *     no per-trip limit counted) when others remain, trying the next member if one is refused; if nobody can take it,
 *     end it and write its summary now (`summariseTrip`), so the recap counts the people who were in it.
 *  2. Delete events they authored (with their stop votes), their stop votes and skip answers, and clear `closedBy`,
 *     `skippedBy`, `leftBy`, `stoppedBy` and `removedBy` where they name the person.
 *  3. Cars: a car with no other rider is deleted (the lead car of a still-active trip only loses its tracker); a car they
 *     tracked that others ride in loses its tracker; a car that is kept and is named after them is renamed
 *     (`Lead car` / `Car <n>`). The live position goes after that, so a tracker never outlives its position's removal.
 *  4. Last, in one batch: their `removed` record, their member doc (name, push token) and, on a trip that still has
 *     `organizerId` of theirs (an ended trip), the organiser id on the trip and its code claim becomes `DELETED_ORGANIZER`.
 *     A trip left with no member at all is deleted whole instead, with its code claim and counters.
 * The member doc goes last in each trip and the Auth user after everything, so a retry after any failure finds the same
 * trips again and finishes; every step is safe to repeat. Positions are only ever deleted here, never copied or kept.
 */
export const MAX_TRIP_HINTS = 200;
/** Never "": an older app reads organizerId as a non-empty id. Not a possible uid. */
export const DELETED_ORGANIZER = "deleted";

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
  // Someone in the organiser's own car first (the lead label then stays), then the rest; a person who cannot take it
  // (invalid-argument) is skipped. Anything else means the trip changed under us: look again below.
  const mine = (await ref.collection("members").doc(uid).get()).data() as Member | undefined;
  const sameCar = (d: { data(): unknown }) => !!mine && (d.data() as Member).carId === mine.carId;
  const order = [...others.filter(sameCar), ...others.filter((d) => !sameCar(d))];
  for (const target of order) {
    try {
      await handOverTransaction(db, uid, tripId, target.id);
      return;
    } catch (err) {
      if (!(err instanceof HttpsError)) throw err;
      logger.info("deleteAccount: hand-over refused", { tripId, code: err.code });
      if (err.code !== "invalid-argument") break;
    }
  }
  const now = (await ref.get()).data() as Trip | undefined;
  if (!now || now.status !== "active" || now.organizerId !== uid) return;
  await endTrip(db, tripId);
}

async function deleteAll(refs: DocumentReference[]): Promise<void> {
  for (const r of refs) await r.delete();
}

/** Steps 2 to 4 for one trip. */
export async function cleanTrip(db: Firestore, uid: string, tripId: string): Promise<boolean> {
  const tripRef = db.collection("trips").doc(tripId);
  if (!(await tripRef.get()).exists) {
    // A whole-trip delete that failed part-way left its subtree (and maybe our member doc): finish it.
    await deleteTripWhole(db, tripRef);
    return false;
  }
  const memberRef = tripRef.collection("members").doc(uid);
  const mine = await memberRef.get();
  if (!mine.exists && (await tripRef.get()).get("organizerId") !== uid) return false;

  await releaseOrganiser(db, uid, tripId);
  const trip = (await tripRef.get()).data() as Trip;

  // Events they wrote (recursiveDelete takes the stop votes under them), stop votes and skip answers they gave.
  await sweepAuthored(db, tripRef, uid);
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
  const myName = mine.exists ? (mine.data() as Member).displayName : "";
  for (const carId of carIds) {
    const carRef = tripRef.collection("cars").doc(carId);
    const car = (await carRef.get()).data() as Car | undefined;
    if (car) {
      const soleRider = !members.some((m) => (m.data() as Member).carId === carId);
      const tracked = car.trackerUserId === uid;
      if (soleRider && !(car.isLead && trip.status === "active")) {
        await carRef.delete();
      } else {
        const update: Record<string, unknown> = {};
        if (tracked) update.trackerUserId = FieldValue.delete();
        if (namesPerson(car.name, myName)) update.name = car.isLead ? "Lead car" : `Car ${car.number ?? ""}`.trim();
        if (Object.keys(update).length > 0) await carRef.update(update);
      }
      if (soleRider || tracked) await tripRef.collection("positions").doc(carId).delete();
    } else {
      await tripRef.collection("positions").doc(carId).delete();
    }
  }

  // Who they removed from a trip, and the record of anyone naming them.
  const removed = tripRef.collection("removed");
  for (const r of (await removed.where("removedBy", "==", uid).get()).docs) await r.ref.update({ removedBy: FieldValue.delete() });

  // Last: anything they posted since the sweep above, then the member doc (or the whole trip when nobody is left).
  await sweepAuthored(db, tripRef, uid);
  if (members.length === 0) {
    await deleteTripWhole(db, tripRef);
    return true;
  }
  const batch = db.batch();
  batch.delete(removed.doc(uid));
  batch.delete(memberRef);
  if (trip.organizerId === uid) {
    batch.update(tripRef, { organizerId: DELETED_ORGANIZER });
    const claim = db.collection("codes").doc(trip.code);
    const claimSnap = await claim.get();
    if (claimSnap.exists && claimSnap.get("tripId") === tripId) batch.update(claim, { organizerId: DELETED_ORGANIZER });
  }
  await batch.commit();
  return true;
}

async function sweepAuthored(db: Firestore, tripRef: DocumentReference, uid: string): Promise<void> {
  for (const e of (await tripRef.collection("events").where("authorId", "==", uid).get()).docs) await db.recursiveDelete(e.ref);
}

/** True when a car's name carries the person's name or its first word ("Zelda's car"). */
export function namesPerson(carName: string, displayName: string): boolean {
  const name = displayName.trim().toLowerCase();
  if (!name) return false;
  const first = name.split(/\s+/)[0]!;
  const car = carName.toLowerCase();
  return car.includes(name) || (first.length >= 2 && car.includes(first));
}

/** A trip nobody is in any more: the trip, everything under it, its code claim and its counters. */
async function deleteTripWhole(db: Firestore, tripRef: DocumentReference): Promise<void> {
  for (const c of (await db.collection("codes").where("tripId", "==", tripRef.id).get()).docs) await c.ref.delete();
  for (const col of TRIP_KEYED_LIMITS) await db.collection(col).doc(tripRef.id).delete();
  await db.recursiveDelete(tripRef);
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
