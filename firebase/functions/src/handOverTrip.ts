import { type Firestore, type Transaction } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { HANDOVER_LIMITS, type CreateLimits } from "./createLimit.js";
import type { Trip } from "./model.js";
import { TRIP_ENDED, release, reserve } from "./rotateTrip.js";

/**
 * Handing the trip to someone else (D106): the organiser of an active trip cannot just leave (the rules refuse their own
 * member delete), so a trip is never left without one. They hand it to another member, then leave as an ordinary
 * member, or end the trip. One transaction, read from the trip doc rather than the request: the caller is the trip's
 * organiser, the trip is active, the target has a member doc and is not the caller. It then sets `trip.organizerId`, the
 * `codes/{code}` claim's `organizerId` (when the claim names this trip), and the two members' `role`. The lead car keeps
 * its `isLead`; its tracker is released when the old organiser leaves (`onMemberDeleted`), and the new organiser's phone
 * may take it (`joinTrip` lets the trip's organiser track the lead car). Answers only `{ok: true}`.
 *
 * Limit: per trip (`handOverLimits/{tripId}`, server-only, swept hourly), 5 in any hour and 10 in any 24 hours; a call
 * that changes nothing gives its slot back. The emulators get a loose one.
 */
export const HANDOVER_PRODUCTION_LIMITS: CreateLimits = { perHour: 5, perDay: 10 };
export const HANDOVER_EMULATOR_LIMITS: CreateLimits = { perHour: 1000, perDay: 5000 };
export function handOverLimitsFor(env: Record<string, string | undefined> = process.env): CreateLimits {
  return env.FUNCTIONS_EMULATOR === "true" ? HANDOVER_EMULATOR_LIMITS : HANDOVER_PRODUCTION_LIMITS;
}

/** One message for a missing trip and someone else's, so a caller cannot tell which trip ids exist. */
export const NOT_YOUR_TRIP_TO_GIVE = "Only the organiser can hand the trip over.";
export const NOT_A_MEMBER = "Pick someone who is in the trip.";

function tooManyHandOvers(waitMilliseconds: number): HttpsError {
  const seconds = Math.max(1, Math.ceil(waitMilliseconds / 1000));
  const minutes = Math.ceil(seconds / 60);
  const when = seconds <= 60 ? "a minute" : minutes < 90 ? `${minutes} minutes` : `${Math.ceil(minutes / 60)} hours`;
  return new HttpsError("resource-exhausted", `Too many hand-overs. Wait ${when} and try again.`,
    { reason: "too-many-handovers", retryAfterSeconds: seconds });
}

export async function handOverTripForUser(
  db: Firestore, uid: string, tripId: string, targetId: unknown, opts: { limits?: CreateLimits; now?: number } = {},
): Promise<{ ok: true }> {
  if (typeof targetId !== "string" || targetId.length < 1 || targetId.length > 128 || targetId.includes("/")) {
    throw new HttpsError("invalid-argument", NOT_A_MEMBER);
  }
  const tripRef = db.collection("trips").doc(tripId);
  // Who is asking is checked before a slot is spent: a missing trip and someone else's look the same.
  const first = (await tripRef.get()).data() as Trip | undefined;
  if (!first || first.organizerId !== uid) throw new HttpsError("permission-denied", NOT_YOUR_TRIP_TO_GIVE);
  if (first.status !== "active") throw new HttpsError("failed-precondition", TRIP_ENDED);
  const now = opts.now ?? Date.now();
  await reserve(db, tripId, now, opts.limits ?? handOverLimitsFor(), HANDOVER_LIMITS, tooManyHandOvers);
  try {
    await db.runTransaction(async (tx: Transaction) => {
      // Reads first; the trip is checked again, it may have ended or changed hands since the first look.
      const trip = (await tx.get(tripRef)).data() as Trip | undefined;
      if (!trip || trip.organizerId !== uid) throw new HttpsError("permission-denied", NOT_YOUR_TRIP_TO_GIVE);
      if (trip.status !== "active") throw new HttpsError("failed-precondition", TRIP_ENDED);
      const target = await tx.get(tripRef.collection("members").doc(targetId));
      if (targetId === uid || !target.exists) throw new HttpsError("invalid-argument", NOT_A_MEMBER);
      const claim = await tx.get(db.collection("codes").doc(trip.code));
      const mine = await tx.get(tripRef.collection("members").doc(uid));
      tx.update(tripRef, { organizerId: targetId });
      if (claim.exists && claim.data()?.tripId === tripId) tx.update(claim.ref, { organizerId: targetId });
      tx.update(target.ref, { role: "organizer" });
      if (mine.exists) tx.update(mine.ref, { role: "member" });
    });
    return { ok: true };
  } catch (err) {
    await release(db, tripId, now, HANDOVER_LIMITS);
    throw err;
  }
}
