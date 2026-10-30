import { FieldValue, Timestamp, type Firestore, type Transaction } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { HttpsError } from "firebase-functions/v2/https";
import {
  DAY_MS, HOUR_MS, ROTATE_LIMITS, createWaitMs, recentCreates, type CreateLimits,
} from "./createLimit.js";
import { MAX_PICK_TRIES, generateCode, isCodeFree } from "./createTrip.js";
import type { Trip } from "./model.js";

/**
 * A new code for a trip (D104): the organiser's answer to a code that got out, or to people they removed (a removed
 * person cannot rejoin with the old code; the new one is only handed out by the organiser). One transaction picks a
 * code nobody holds (the picker of createTrip.ts), moves the trip's claim to it, and deletes the trip's `removed/*`
 * docs. People already in the trip are untouched. Returns only the code.
 *
 * Limit: per trip (`rotateLimits/{tripId}`, server-only, swept hourly), 5 in any hour and 10 in any 24 hours. Nobody
 * needs more; it stops a script from burning codes. The emulators get a loose one for the tests and drives.
 */
export const ROTATE_PRODUCTION_LIMITS: CreateLimits = { perHour: 5, perDay: 10 };
export const ROTATE_EMULATOR_LIMITS: CreateLimits = { perHour: 1000, perDay: 5000 };
export function rotateLimitsFor(env: Record<string, string | undefined> = process.env): CreateLimits {
  return env.FUNCTIONS_EMULATOR === "true" ? ROTATE_EMULATOR_LIMITS : ROTATE_PRODUCTION_LIMITS;
}
/** A trip never has more removed docs than this to clear in one go (one transaction takes 500 writes). */
const REMOVED_CLEAR_MAX = 400;

/** One message for a missing trip and someone else's, so a caller cannot tell which trip ids exist. */
export const NOT_YOUR_TRIP = "Only the organiser can make a new code.";
export const TRIP_ENDED = "This trip has ended.";

export interface RotateOpts { random?: () => number; maxTries?: number; limits?: CreateLimits; now?: number }

function tooManyCodes(waitMilliseconds: number): HttpsError {
  const seconds = Math.max(1, Math.ceil(waitMilliseconds / 1000));
  const minutes = Math.ceil(seconds / 60);
  const when = seconds <= 60 ? "a minute" : minutes < 90 ? `${minutes} minutes` : `${Math.ceil(minutes / 60)} hours`;
  return new HttpsError("resource-exhausted", `Too many new codes. Wait ${when} and try again.`,
    { reason: "too-many-codes", retryAfterSeconds: seconds });
}

async function reserve(db: Firestore, tripId: string, now: number, limits: CreateLimits): Promise<void> {
  const ref = db.collection(ROTATE_LIMITS).doc(tripId);
  await db.runTransaction(async (tx: Transaction) => {
    const times = recentCreates((await tx.get(ref)).data(), now);
    const wait = createWaitMs(times, now, limits);
    if (wait > 0) throw tooManyCodes(wait);
    tx.set(ref, { creates: [...times, now], expiresAt: Timestamp.fromMillis(now + DAY_MS) });
  });
}

/** Gives back the slot of a call that changed nothing. Never throws. */
async function release(db: Firestore, tripId: string, slot: number): Promise<void> {
  const ref = db.collection(ROTATE_LIMITS).doc(tripId);
  try {
    await db.runTransaction(async (tx: Transaction) => {
      const times = recentCreates((await tx.get(ref)).data(), Date.now());
      const i = times.indexOf(slot);
      if (i < 0) return;
      times.splice(i, 1);
      if (times.length === 0) tx.delete(ref);
      else tx.set(ref, { creates: times, expiresAt: Timestamp.fromMillis(times[times.length - 1]! + DAY_MS) });
    });
  } catch (err) {
    logger.warn("rotateTrip: could not give a slot back", { err: String(err) });
  }
}

/** Checks who is asking before a slot is spent: a missing trip and someone else's look the same. */
async function checkOrganizer(db: Firestore, uid: string, tripId: string): Promise<void> {
  const trip = (await db.collection("trips").doc(tripId).get()).data() as Trip | undefined;
  if (!trip || trip.organizerId !== uid) throw new HttpsError("permission-denied", NOT_YOUR_TRIP);
  if (trip.status !== "active") throw new HttpsError("failed-precondition", TRIP_ENDED);
}

export async function rotateCodeForUser(db: Firestore, uid: string, tripId: string, opts: RotateOpts = {}): Promise<{ code: string }> {
  await checkOrganizer(db, uid, tripId);
  const now = opts.now ?? Date.now();
  await reserve(db, tripId, now, opts.limits ?? rotateLimitsFor());
  try {
    const tripRef = db.collection("trips").doc(tripId);
    for (let i = 0; i < (opts.maxTries ?? MAX_PICK_TRIES); i++) {
      const code = generateCode(opts.random);
      const done = await db.runTransaction(async (tx: Transaction) => {
        // Reads first. The trip is checked again here: it may have ended, or changed hands, since the first look.
        const trip = (await tx.get(tripRef)).data() as Trip | undefined;
        if (!trip || trip.organizerId !== uid) throw new HttpsError("permission-denied", NOT_YOUR_TRIP);
        if (trip.status !== "active") throw new HttpsError("failed-precondition", TRIP_ENDED);
        const oldClaim = await tx.get(db.collection("codes").doc(trip.code));
        const removed = await tx.get(tripRef.collection("removed").limit(REMOVED_CLEAR_MAX));
        if (!(await isCodeFree(tx, db, code))) return false;
        tx.update(tripRef, { code });
        if (oldClaim.exists && oldClaim.data()?.tripId === tripId) tx.delete(oldClaim.ref);
        tx.create(db.collection("codes").doc(code), { tripId, organizerId: uid, createdAt: FieldValue.serverTimestamp() });
        removed.docs.forEach((d) => tx.delete(d.ref));
        return true;
      });
      if (done) return { code };
    }
    logger.error("rotateTrip: no free code found", { tries: opts.maxTries ?? MAX_PICK_TRIES });
    throw new HttpsError("aborted", "Couldn’t make a new code just now. Please try again.");
  } catch (err) {
    await release(db, tripId, now);
    throw err;
  }
}
