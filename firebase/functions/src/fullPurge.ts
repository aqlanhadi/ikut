import { Timestamp, type Firestore, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import type { Trip } from "./model.js";
import { HANDOVER_LIMITS, ROTATE_LIMITS } from "./createLimit.js";
import { POSITION_RETENTION_MS, TRIP_RETENTION_MS, purgeCodeClaim, shouldDeleteTrip } from "./retention.js";
import { cursorFromState, cursorToState, loadState, runSweep, saveState, tripsList } from "./sweep.js";
import { summariseTrip } from "./summary.js";

/** Most trips one run deletes, and the time it spends before it stops starting new ones (the job's timeout is 540 s). */
export const FULL_MAX_TRIPS_PER_RUN = 100;
export const FULL_BUDGET_MS = 300_000;
/** Trips fetched per query. */
export const FULL_PAGE_SIZE = 20;
/** Failed trips remembered for the next run. */
export const FULL_MAX_RETRY = 100;
/**
 * Trips ended in the last 7 days checked for a missing summary per run. Scale: the backfill re-reads up to this many
 * recently ended trips every day, and past about 500 ended per week a missing summary might never be filled; 100 deletes
 * a day also caps the 90-day rule once more than 100 trips end a day. Fine at today's scale; then raise these
 * (and give the job more than one run a day).
 */
export const BACKFILL_MAX = 500;
/** Own cursor, apart from the 7-day purge's `jobState/purgeTripData`. */
export const FULL_PURGE_STATE = "purgeTripsFull";
/** Per-trip limit counters keyed by trip id (rotateLimits, handOverLimits); deleted with the trip. */
export const TRIP_KEYED_LIMITS = [ROTATE_LIMITS, HANDOVER_LIMITS] as const;

export interface FullPurgeOptions {
  maxTrips?: number;
  budgetMs?: number;
  clock?: () => number;
}

export interface FullPurgeResult {
  /** Trips deleted completely. */
  deleted: number;
  /** Retried trips whose doc was already gone and whose leftovers were cleaned. */
  cleaned: number;
  /** Summaries written for ended trips (still inside the 7 days) that had none. */
  summarised: number;
  failed: number;
  /** Stopped at the cap or the time budget with old trips still waiting. */
  more: boolean;
}

/**
 * Deletes one trip for good: its code claim and per-trip limit counters first (once the trip doc is gone nothing
 * would find them again), then the trip with every subcollection (cars, members, removed, stops and their answers,
 * events and their votes, positions) by `recursiveDelete`. Throws if any step does; the trip is then still there for a retry.
 */
async function deleteTripCompletely(db: Firestore, ref: FirebaseFirestore.DocumentReference, trip: Trip): Promise<void> {
  await purgeCodeClaim(db, ref, trip);
  for (const col of TRIP_KEYED_LIMITS) await db.collection(col).doc(ref.id).delete();
  await db.recursiveDelete(ref);
}

/**
 * A trip doc that is already gone but may have left its subtree (a `recursiveDelete` that failed on a child still
 * deletes the root): delete what is under it, its limit counters and any claim naming it. Throws if a step does.
 */
async function cleanUpGoneTrip(db: Firestore, ref: FirebaseFirestore.DocumentReference): Promise<void> {
  const claims = await db.collection("codes").where("tripId", "==", ref.id).get();
  for (const c of claims.docs) await c.ref.delete();
  for (const col of TRIP_KEYED_LIMITS) await db.collection(col).doc(ref.id).delete();
  await db.recursiveDelete(ref);
}

/**
 * Step A: an ended trip within the 7-day window that has no summary (it ended before the trigger was live, or the
 * trigger failed) gets one now, while its events and stops are still there. Older ones are not summarised: their
 * events are gone, so the counts would be wrong; they are simply deleted at 90 days.
 */
export async function backfillSummaries(db: Firestore, now: Date): Promise<number> {
  const since = Timestamp.fromMillis(now.getTime() - POSITION_RETENTION_MS);
  const snap = await db.collection("trips").where("status", "==", "ended").where("endedAt", ">=", since).limit(BACKFILL_MAX).get();
  let written = 0;
  for (const d of snap.docs) {
    if (d.get("summary") != null) continue;
    try {
      if (await summariseTrip(db, d.id)) written++;
    } catch (err) {
      logger.error("purgeTripsFull: summary failed", { tripId: d.id, err: String(err) });
    }
  }
  return written;
}

/**
 * Step B: deletes trips ended more than TRIP_RETENTION_MS ago, oldest first from a cursor in `jobState/purgeTripsFull`,
 * at most `maxTrips` and `budgetMs` a run. A trip whose delete threw is retried first next run. An active trip is never
 * touched (the query is `status == ended`). An ended trip without `endedAt` is never returned by the `endedAt <` query,
 * so it is never deleted (neither the rules nor endIdleTrips can produce one). A retried id whose trip doc is already
 * gone still gets its subtree, claim and limit docs cleaned, and leaves the retry list only once that succeeded.
 */
export async function purgeOldTrips(db: Firestore, now: Date = new Date(), opts: FullPurgeOptions = {}): Promise<FullPurgeResult> {
  const clock = opts.clock ?? Date.now;
  const deadline = clock() + (opts.budgetMs ?? FULL_BUDGET_MS);
  const outOfTime = () => clock() >= deadline;
  const result: FullPurgeResult = { deleted: 0, cleaned: 0, summarised: 0, failed: 0, more: false };
  try {
    result.summarised = await backfillSummaries(db, now);
  } catch (err) {
    logger.error("purgeTripsFull: summary backfill failed", { err: String(err) });
  }

  const endedBefore = Timestamp.fromMillis(now.getTime() - TRIP_RETENTION_MS);
  const state = await loadState<{ cursorSeconds: number | null; cursorNanos: number | null; cursorId: string | null; retry: string[] }>(db, FULL_PURGE_STATE);
  const stillFailing: string[] = [];
  let retryFull = false;

  const tryDelete = async (ref: FirebaseFirestore.DocumentReference, trip: Trip): Promise<void> => {
    if (!shouldDeleteTrip(trip, now)) return;
    await deleteTripCompletely(db, ref, trip);
    result.deleted++;
  };

  for (const id of state.retry ?? []) {
    if (outOfTime()) { stillFailing.push(id); continue; }
    const ref = db.collection("trips").doc(id);
    try {
      const snap = await ref.get();
      if (snap.exists) await tryDelete(ref, snap.data() as Trip);
      else {
        await cleanUpGoneTrip(db, ref);
        result.cleaned++;
      }
    } catch (err) {
      stillFailing.push(id);
      result.failed++;
      logger.error("purgeTripsFull: retry failed", { tripId: id, err: String(err) });
    }
  }

  const base = db.collection("trips").where("status", "==", "ended").where("endedAt", "<", endedBefore);
  const outcome = await runSweep<QueryDocumentSnapshot>({
    list: tripsList(base, "endedAt"),
    handle: async ({ item }) => tryDelete(item.ref, item.data() as Trip),
    cursor: cursorFromState(state, FULL_PURGE_STATE, endedBefore),
    maxItems: opts.maxTrips ?? FULL_MAX_TRIPS_PER_RUN,
    pageSize: FULL_PAGE_SIZE,
    outOfTime,
    save: (c) => saveState(db, FULL_PURGE_STATE, { ...cursorToState(c), retry: stillFailing.slice(0, FULL_MAX_RETRY) }),
    onFailure: (id, err) => {
      result.failed++;
      logger.error("purgeTripsFull: delete failed", { tripId: id, err: String(err) });
      if (stillFailing.length >= FULL_MAX_RETRY) retryFull = true;
      else stillFailing.push(id);
    },
    holdOnFailure: () => retryFull,
  });
  result.more = outcome.more;
  await saveState(db, FULL_PURGE_STATE, { ...cursorToState(outcome.cursor), retry: stillFailing.slice(0, FULL_MAX_RETRY), lastRunAt: Timestamp.fromMillis(now.getTime()) });
  logger.info("purgeTripsFull: done", { ...result });
  return result;
}
