import { Timestamp, type Firestore, type Transaction } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { HttpsError } from "firebase-functions/v2/https";

/**
 * A per-user limit on trip creates, for `createTrip`; the same shape as the wrong-code limit (guessLimit.ts).
 *
 * `createLimits/<uid>` is server-only and holds the times (epoch ms) of the user's recent creates. A call reserves a
 * slot in a transaction before it writes anything, so parallel calls cannot all pass on the same count; a call that
 * then fails to create gives its slot back. Limits: MAX_PER_HOUR in any hour (sliding) and MAX_PER_DAY in any 24
 * hours. Nobody makes 20 trips in an hour for real; the limit exists so one account cannot fill the database with
 * trips or burn codes. App Check (APPCHECK_ENFORCE) is what covers someone who makes new anonymous accounts.
 *
 * The documents carry `expiresAt` (last create + a day); `sweepCreateLimits` deletes the expired ones from the
 * hourly retention job.
 */
export const CREATE_LIMITS = "createLimits";
/** Per-trip counters for new codes (rotateTrip.ts), the same shape as `createLimits`. */
export const ROTATE_LIMITS = "rotateLimits";
/** Per-trip counters for hand-overs (handOverTrip.ts), the same shape. */
export const HANDOVER_LIMITS = "handOverLimits";
export const HOUR_MS = 60 * 60_000;
export const DAY_MS = 24 * HOUR_MS;
export const MAX_PER_HOUR = 20;
export const MAX_PER_DAY = 50;

export interface CreateLimits {
  perHour: number;
  perDay: number;
}
export const PRODUCTION_LIMITS: CreateLimits = { perHour: MAX_PER_HOUR, perDay: MAX_PER_DAY };
/** The emulators: the UI suites, drives and the owner's phone create dozens of trips an hour as one long-lived account. */
export const EMULATOR_LIMITS: CreateLimits = { perHour: 1000, perDay: 5000 };

/** Loose limits in the Functions emulator (as App Check is relaxed there), the real ones everywhere else. */
export function limitsFor(env: Record<string, string | undefined> = process.env): CreateLimits {
  return env.FUNCTIONS_EMULATOR === "true" ? EMULATOR_LIMITS : PRODUCTION_LIMITS;
}

interface LimitDoc {
  creates?: unknown;
  expiresAt?: Timestamp;
}

/** The recorded create times still inside the day, oldest first; anything malformed is dropped. */
export function recentCreates(data: LimitDoc | undefined, now: number): number[] {
  const raw = Array.isArray(data?.creates) ? (data!.creates as unknown[]) : [];
  return raw
    .filter((t): t is number => typeof t === "number" && Number.isFinite(t) && t > now - DAY_MS && t <= now + 60_000)
    .sort((a, b) => a - b);
}

/** Milliseconds until one more create is allowed, or 0 when it is allowed now. `creates` is sorted, inside the day. */
export function createWaitMs(creates: number[], now: number, limits: CreateLimits = PRODUCTION_LIMITS): number {
  let wait = 0;
  const inHour = creates.filter((t) => t > now - HOUR_MS);
  if (inHour.length >= limits.perHour) wait = Math.max(wait, inHour[inHour.length - limits.perHour]! + HOUR_MS - now);
  if (creates.length >= limits.perDay) wait = Math.max(wait, creates[creates.length - limits.perDay]! + DAY_MS - now);
  return Math.max(0, wait);
}

export function tooManyTrips(waitMilliseconds: number): HttpsError {
  const seconds = Math.max(1, Math.ceil(waitMilliseconds / 1000));
  const minutes = Math.ceil(seconds / 60);
  const when = seconds <= 60 ? "a minute" : minutes < 90 ? `${minutes} minutes` : `${Math.ceil(minutes / 60)} hours`;
  return new HttpsError(
    "resource-exhausted",
    `Too many new trips. Wait ${when} and try again.`,
    { reason: "too-many-trips", retryAfterSeconds: seconds },
  );
}

/** Counts this call or throws resource-exhausted without counting. Returns the recorded slot. */
export async function reserveCreate(
  db: Firestore, uid: string, now: number = Date.now(), limits: CreateLimits = limitsFor(),
): Promise<number> {
  const ref = db.collection(CREATE_LIMITS).doc(uid);
  return db.runTransaction(async (tx: Transaction) => {
    const creates = recentCreates((await tx.get(ref)).data() as LimitDoc | undefined, now);
    const wait = createWaitMs(creates, now, limits);
    if (wait > 0) throw tooManyTrips(wait);
    tx.set(ref, { creates: [...creates, now], expiresAt: Timestamp.fromMillis(now + DAY_MS) });
    return now;
  });
}

/** Gives back the slot of a call that created nothing. Never throws: at worst the call stays counted. */
export async function releaseCreate(db: Firestore, uid: string, slot: number, now: number = Date.now()): Promise<void> {
  const ref = db.collection(CREATE_LIMITS).doc(uid);
  try {
    await db.runTransaction(async (tx: Transaction) => {
      const creates = recentCreates((await tx.get(ref)).data() as LimitDoc | undefined, now);
      const i = creates.indexOf(slot);
      if (i < 0) return;
      creates.splice(i, 1);
      if (creates.length === 0) tx.delete(ref);
      else tx.set(ref, { creates, expiresAt: Timestamp.fromMillis(creates[creates.length - 1]! + DAY_MS) });
    });
  } catch (err) {
    logger.warn("createLimit: could not give a slot back", { err: String(err) });
  }
}

/** Deletes counter documents (of `collection`, the create limits by default; rotateLimits.ts passes its own) whose `expiresAt` has passed, up to `max`. Returns how many. */
export async function sweepCreateLimits(
  db: Firestore, now: Date = new Date(), max = 1000, collection: string = CREATE_LIMITS,
): Promise<number> {
  let deleted = 0;
  while (deleted < max) {
    const snap = await db.collection(collection).where("expiresAt", "<", Timestamp.fromDate(now)).limit(Math.min(200, max - deleted)).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    deleted += snap.size;
    if (snap.size < 200) break;
  }
  return deleted;
}
