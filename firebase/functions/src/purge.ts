import { Timestamp, type Firestore, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import type { Trip } from "./model.js";
import { sweepGuessLimits } from "./guessLimit.js";
import {
  POSITION_RETENTION_MS,
  deleteEventsWithVotes,
  deleteEventsWithVotesOf,
  deleteInBatches,
  eventExpiryCutoff,
  purgeStopTraces,
  shouldPurgeTripData,
  type PurgeResult,
} from "./retention.js";
import { cursorFromState, cursorToState, loadState, runSweep, saveState, tripsList } from "./sweep.js";

/** Most ended trips one run purges; a bigger backlog is finished over the next runs (6 hours apart, plus the manual path). */
export const MAX_TRIPS_PER_RUN = 500;
/** Trips fetched per query (the cursor is saved after each). */
export const TRIP_PAGE_SIZE = 50;
/** Time a run spends on trips before it stops starting new ones, inside the job's 540 second timeout. */
export const TRIP_BUDGET_MS = 300_000;
/** Time the expired-events sweep may take. Together with the trip budget this stays under the 540 second timeout. */
export const EVENTS_BUDGET_MS = 150_000;
/** Trips whose purge threw are remembered (up to this many) and retried first on the next run. */
export const MAX_RETRY = 100;

export const PURGE_STATE = "purgeTripData";

export interface PurgeOptions {
  maxTrips?: number;
  tripBudgetMs?: number;
  eventsBudgetMs?: number;
  /** Milliseconds clock, for the time budgets (tests). */
  clock?: () => number;
}

type PurgeCounts = { positions: number; events: number; votes: number; stops: number; answers: number };

/** Deletes one ended trip's positions, events (with votes) and stop traces. Throws if any step does. */
async function purgeOneTrip(db: Firestore, ref: FirebaseFirestore.DocumentReference): Promise<PurgeCounts> {
  const positions = await deleteInBatches(db, ref.collection("positions"));
  const events = await deleteEventsWithVotes(db, await ref.collection("events").listDocuments());
  const traces = await purgeStopTraces(db, ref);
  return { positions, events: events.events, votes: events.votes, stops: traces.stops, answers: traces.answers };
}

function addCounts(result: PurgeResult, c: PurgeCounts): void {
  result.positions += c.positions;
  result.endedTripEvents += c.events;
  result.votes += c.votes;
  result.stopsCleared += c.stops;
  result.answers += c.answers;
  // Purged trips are not read again, but a retried one can be empty: count only those that had something to delete.
  if (c.positions + c.events + c.votes + c.stops + c.answers > 0) result.trips++;
}

/**
 * Step 1: positions and events (with their stop votes) of ended trips older than POSITION_RETENTION_MS, stop traces
 * cleared, skip answers deleted (the trip and stop docs stay). Trips are taken oldest first from a cursor kept in
 * `jobState/purgeTripData`, at most `maxTrips` per run, so a finished trip is never read again and a big backlog is
 * worked off over several runs instead of starting over from the oldest every time. A trip whose purge threw is
 * kept in `retry` and tried first next run. A trip's endedAt is server time (rules and functions), so a trip that
 * ends later always sorts after the cursor.
 */
export async function purgeEndedTrips(db: Firestore, now: Date, result: PurgeResult, opts: PurgeOptions = {}): Promise<void> {
  const clock = opts.clock ?? Date.now;
  const deadline = clock() + (opts.tripBudgetMs ?? TRIP_BUDGET_MS);
  const outOfTime = () => clock() >= deadline;
  const endedBefore = Timestamp.fromMillis(now.getTime() - POSITION_RETENTION_MS);
  const state = await loadState<{ cursorSeconds: number | null; cursorNanos: number | null; cursorId: string | null; retry: string[] }>(db, PURGE_STATE);
  const stillFailing: string[] = [];
  let retryFull = false;

  // Trips that failed last time first.
  for (const id of state.retry ?? []) {
    if (outOfTime()) { stillFailing.push(id); continue; }
    const ref = db.collection("trips").doc(id);
    try {
      const snap = await ref.get();
      if (snap.exists && shouldPurgeTripData(snap.data() as Trip, now)) {
        addCounts(result, await purgeOneTrip(db, ref));
      }
    } catch (err) {
      stillFailing.push(id);
      result.failed++;
      logger.error("purgeTripData: retry failed", { tripId: id, err: String(err) });
    }
  }

  const base = db.collection("trips").where("status", "==", "ended").where("endedAt", "<", endedBefore);
  const outcome = await runSweep<QueryDocumentSnapshot>({
    list: tripsList(base, "endedAt"),
    handle: async ({ item }) => {
      if (!shouldPurgeTripData(item.data() as Trip, now)) return;
      addCounts(result, await purgeOneTrip(db, item.ref));
    },
    cursor: cursorFromState(state, PURGE_STATE, endedBefore),
    maxItems: opts.maxTrips ?? MAX_TRIPS_PER_RUN,
    pageSize: TRIP_PAGE_SIZE,
    outOfTime,
    save: (c) => saveState(db, PURGE_STATE, { ...cursorToState(c), retry: stillFailing.slice(0, MAX_RETRY) }),
    onFailure: (id, err) => {
      result.failed++;
      logger.error("purgeTripData: trip purge failed", { tripId: id, err: String(err) });
      // With the retry list full this trip cannot be remembered: hold the cursor before it (below) so the next run
      // meets it again, instead of moving past it for good.
      if (stillFailing.length >= MAX_RETRY) retryFull = true;
      else stillFailing.push(id);
    },
    holdOnFailure: () => retryFull,
  });
  result.examined = outcome.handled;
  result.more = outcome.more;
  await saveState(db, PURGE_STATE, { ...cursorToState(outcome.cursor), retry: stillFailing.slice(0, MAX_RETRY), lastRunAt: Timestamp.fromMillis(now.getTime()) });
}

/** Step 2, independent of step 1: every event past its expiresAt grace period, in any trip (active ones too). */
export async function sweepExpiredEvents(db: Firestore, now: Date, result: PurgeResult, opts: PurgeOptions = {}): Promise<void> {
  const clock = opts.clock ?? Date.now;
  const deadline = clock() + (opts.eventsBudgetMs ?? EVENTS_BUDGET_MS);
  const expired = await deleteEventsWithVotesOf(
    db,
    db.collectionGroup("events").where("expiresAt", "<", eventExpiryCutoff(now)),
    () => clock() >= deadline,
  );
  result.expiredEvents += expired.events;
  result.votes += expired.votes;
  // Wrong-code counters older than a day; their failure must not hold back the event sweep's result.
  try {
    await sweepGuessLimits(db, now);
  } catch (err) {
    logger.error("sweepExpiredEvents: guess limit sweep failed", { err: String(err) });
  }
}

export function emptyPurgeResult(): PurgeResult {
  return { trips: 0, failed: 0, examined: 0, more: false, stopsCleared: 0, answers: 0, votes: 0, positions: 0, endedTripEvents: 0, expiredEvents: 0 };
}

/**
 * Retention sweep: step 1 (ended trips' data) then step 2 (expired events). Step 2 runs even when step 1 hit its cap,
 * its time budget or threw, so expired events are never held back by a trip backlog (it also has its own
 * scheduled job). The error from step 1, if any, is rethrown after step 2.
 */
export async function purgeTripData(db: Firestore, now: Date = new Date(), opts: PurgeOptions = {}): Promise<PurgeResult> {
  const result = emptyPurgeResult();
  let tripError: unknown;
  try {
    await purgeEndedTrips(db, now, result, opts);
  } catch (err) {
    tripError = err;
    logger.error("purgeTripData: trip step failed", { err: String(err) });
  }
  await sweepExpiredEvents(db, now, result, opts);
  logger.info("purgeTripData: done", { ...result });
  if (tripError !== undefined) throw tripError;
  return result;
}
