import { Timestamp, type Firestore, type Transaction } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { HttpsError } from "firebase-functions/v2/https";

/**
 * A per-user limit on wrong trip codes, shared by `previewTrip` and `joinTrip`.
 *
 * Each signed-in user has one server-only document, `guessLimits/<uid>`, holding the times (epoch ms) of the codes
 * that matched no trip recently. A call reserves a slot (adds "now") in a transaction BEFORE any trip lookup, so
 * parallel guesses cannot all pass the check on the same count; a call whose code turns out right gives its slot
 * back, so only misses stay. Nothing is cleared on success: a miss counts until its window passes, so alternating
 * with a known good code does not help.
 *
 * Limits: MAX_MISSES_PER_WINDOW misses in any WINDOW_MS (sliding), and MAX_MISSES_PER_DAY in any DAY_MS. A
 * 6-character code has about 887 million values (31 characters in the app's alphabet; the server accepts any of 36, about 2 billion), so 50 guesses a day per account is hopeless for guessing; 10 in
 * 10 minutes leaves room for a person mistyping a code and retrying. This does not stop someone who makes a new
 * anonymous account per few guesses: App Check (APPCHECK_ENFORCE) is what covers that.
 *
 * The documents carry `expiresAt` (last miss + a day); `sweepGuessLimits` deletes the expired ones from the
 * hourly retention job (Firestore TTL is not on in production).
 */
export const GUESS_LIMITS = "guessLimits";
export const WINDOW_MS = 10 * 60_000;
export const MAX_MISSES_PER_WINDOW = 10;
export const DAY_MS = 24 * 60 * 60_000;
export const MAX_MISSES_PER_DAY = 50;
export const TOO_MANY_TRIES = "Too many wrong codes";

interface LimitDoc {
  misses?: unknown;
  expiresAt?: Timestamp;
}

/** The recorded miss times still inside the day, oldest first; anything malformed is dropped. */
export function recentMisses(data: LimitDoc | undefined, now: number): number[] {
  const raw = Array.isArray(data?.misses) ? (data!.misses as unknown[]) : [];
  return raw
    .filter((t): t is number => typeof t === "number" && Number.isFinite(t) && t > now - DAY_MS && t <= now + 60_000)
    .sort((a, b) => a - b);
}

/** Milliseconds until one more try is allowed, or 0 when it is allowed now. `misses` is sorted, inside the day. */
export function waitMs(misses: number[], now: number): number {
  let wait = 0;
  const inWindow = misses.filter((t) => t > now - WINDOW_MS);
  if (inWindow.length >= MAX_MISSES_PER_WINDOW) {
    // The (n - limit + 1)th oldest must age out for the count to drop below the limit.
    wait = Math.max(wait, inWindow[inWindow.length - MAX_MISSES_PER_WINDOW]! + WINDOW_MS - now);
  }
  if (misses.length >= MAX_MISSES_PER_DAY) {
    wait = Math.max(wait, misses[misses.length - MAX_MISSES_PER_DAY]! + DAY_MS - now);
  }
  return Math.max(0, wait);
}

export function tooManyTries(waitMilliseconds: number): HttpsError {
  const seconds = Math.max(1, Math.ceil(waitMilliseconds / 1000));
  const minutes = Math.ceil(seconds / 60);
  const when = seconds <= 60 ? "a minute" : minutes < 90 ? `${minutes} minutes` : `${Math.ceil(minutes / 60)} hours`;
  return new HttpsError(
    "resource-exhausted",
    `${TOO_MANY_TRIES}. Wait ${when} and try again.`,
    { reason: "too-many-guesses", retryAfterSeconds: seconds },
  );
}

/**
 * Counts this call as a miss (the slot is returned) or throws resource-exhausted without counting. The returned
 * slot is the time that was recorded; pass it to `releaseGuess` when the code was right.
 */
export async function reserveGuess(db: Firestore, uid: string, now: number = Date.now()): Promise<number> {
  const ref = db.collection(GUESS_LIMITS).doc(uid);
  return db.runTransaction(async (tx: Transaction) => {
    const misses = recentMisses((await tx.get(ref)).data() as LimitDoc | undefined, now);
    const wait = waitMs(misses, now);
    if (wait > 0) throw tooManyTries(wait);
    tx.set(ref, { misses: [...misses, now], expiresAt: Timestamp.fromMillis(now + DAY_MS) });
    return now;
  });
}

/** Gives back the slot of a call whose code matched a trip. Never throws: at worst the call stays counted. */
export async function releaseGuess(db: Firestore, uid: string, slot: number, now: number = Date.now()): Promise<void> {
  const ref = db.collection(GUESS_LIMITS).doc(uid);
  try {
    await db.runTransaction(async (tx: Transaction) => {
      const misses = recentMisses((await tx.get(ref)).data() as LimitDoc | undefined, now);
      const i = misses.indexOf(slot);
      if (i < 0) return;
      misses.splice(i, 1);
      if (misses.length === 0) tx.delete(ref);
      else tx.set(ref, { misses, expiresAt: Timestamp.fromMillis(misses[misses.length - 1]! + DAY_MS) });
    });
  } catch (err) {
    logger.warn("guessLimit: could not give a slot back", { err: String(err) });
  }
}

/**
 * Runs `lookup` (the trip lookup) under the limit: reserve first, give the slot back when `lookup` finds the trip.
 * A not-found or ambiguous answer, or any other failure of `lookup`, stays counted.
 */
export async function countingMisses<T>(db: Firestore, uid: string, lookup: () => Promise<T>): Promise<T> {
  const slot = await reserveGuess(db, uid);
  const found = await lookup();
  await releaseGuess(db, uid, slot);
  return found;
}

/** Deletes counter documents whose `expiresAt` has passed, up to `max`. Returns how many. */
export async function sweepGuessLimits(db: Firestore, now: Date = new Date(), max = 1000): Promise<number> {
  let deleted = 0;
  while (deleted < max) {
    const snap = await db.collection(GUESS_LIMITS).where("expiresAt", "<", Timestamp.fromDate(now)).limit(Math.min(200, max - deleted)).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    deleted += snap.size;
    if (snap.size < 200) break;
  }
  return deleted;
}
