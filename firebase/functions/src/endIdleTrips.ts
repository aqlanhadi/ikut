import {
  FieldValue,
  Timestamp,
  getFirestore,
  type DocumentSnapshot,
  type Firestore,
  type QueryDocumentSnapshot,
} from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { IDLE_MS, isIdle, tripActivityMillis } from "./idle.js";
import type { Position, Trip, TripEvent } from "./model.js";
import { BATCH_SIZE } from "./retention.js";
import { cursorFromState, cursorToState, loadState, runSweep, saveState, tripsList } from "./sweep.js";

async function latestUpdate<T>(snap: FirebaseFirestore.Query, field: string): Promise<T | null> {
  const res = await snap.orderBy(field, "desc").limit(1).get();
  return res.empty ? null : (res.docs[0]!.data() as T);
}

const endedFields = () => ({ status: "ended", endedAt: FieldValue.serverTimestamp() });

/** Commit one batch. Each update is pinned to the snapshot we read, so a trip touched since is skipped. */
async function endBatch(db: Firestore, docs: DocumentSnapshot[]): Promise<number> {
  const batch = db.batch();
  for (const d of docs) {
    batch.update(d.ref, endedFields(), { lastUpdateTime: d.updateTime! });
  }
  try {
    await batch.commit();
    return docs.length;
  } catch {
    // A failed precondition aborts the whole batch; retry one by one so only the changed trips are skipped.
    let ended = 0;
    for (const d of docs) {
      try {
        await d.ref.update(endedFields(), { lastUpdateTime: d.updateTime! });
        ended++;
      } catch (err) {
        logger.info("endIdleTrips: skipped trip that changed", { tripId: d.id, err: String(err) });
      }
    }
    return ended;
  }
}

/** Most old active trips checked per run (each costs two small reads); the next run carries on after them. */
export const MAX_TRIPS_PER_RUN = 1000;
/** Time a run spends before it stops starting new trips, inside the job's 300 second timeout. */
export const IDLE_BUDGET_MS = 200_000;
const IDLE_STATE = "endIdleTrips";

export interface IdleOptions {
  maxTrips?: number;
  budgetMs?: number;
  clock?: () => number;
}

/**
 * Ends every active trip idle for 12 hours. Candidates are active trips created more than 12 hours
 * ago (createdAt always exists, lastActivityAt may not); only those get their newest position and
 * event checked. Trips that are old but still busy stay in the query, so the walk goes round: each run continues
 * after the last trip the previous run checked (cursor in `jobState/endIdleTrips`), at most `maxTrips`, and
 * goes back to the oldest when it reaches the end. A few busy old trips at the front can no longer use up every
 * run. Returns the number of trips ended.
 */
export async function endIdleTrips(db: Firestore, now: Date = new Date(), opts: IdleOptions = {}): Promise<number> {
  const clock = opts.clock ?? Date.now;
  const deadline = clock() + (opts.budgetMs ?? IDLE_BUDGET_MS);
  const cutoff = Timestamp.fromMillis(now.getTime() - IDLE_MS);
  const state = await loadState<{ cursorSeconds: number | null; cursorNanos: number | null; cursorId: string | null }>(db, IDLE_STATE);
  let ended = 0;
  const idle: DocumentSnapshot[] = [];
  const flush = async () => {
    if (idle.length === 0) return;
    ended += await endBatch(db, idle.splice(0));
  };

  const base = db.collection("trips").where("status", "==", "active").where("createdAt", "<=", cutoff);
  const outcome = await runSweep<QueryDocumentSnapshot>({
    list: tripsList(base, "createdAt"),
    handle: async ({ item: doc }) => {
      const trip = doc.data() as Trip;
      // Cheap check first: skip the position and event reads when the trip doc itself is recent.
      if (now.getTime() - tripActivityMillis(trip) < IDLE_MS) return;
      const [position, event] = await Promise.all([
        latestUpdate<Position>(doc.ref.collection("positions"), "updatedAt"),
        latestUpdate<TripEvent>(doc.ref.collection("events"), "createdAt"),
      ]);
      if (isIdle(trip, position, event, now)) idle.push(doc);
    },
    cursor: cursorFromState(state, IDLE_STATE, cutoff),
    maxItems: opts.maxTrips ?? MAX_TRIPS_PER_RUN,
    pageSize: BATCH_SIZE,
    outOfTime: () => clock() >= deadline,
    wrap: true,
    save: async (c) => {
      await flush();
      await saveState(db, IDLE_STATE, cursorToState(c));
    },
    onFailure: (id, err) => logger.error("endIdleTrips: trip check failed", { tripId: id, err: String(err) }),
  });
  await flush();
  await saveState(db, IDLE_STATE, cursorToState(outcome.cursor));

  logger.info("endIdleTrips: done", { ended, checked: outcome.handled, more: outcome.more, wrapped: outcome.wrapped });
  return ended;
}

/**
 * Every 30 minutes: the idle limit is 12 hours, so a trip is ended at most 30 minutes late (~4%),
 * while the sweep only reads trips older than 12 hours and stays cheap.
 */
export const endIdleTripsJob = onSchedule({ schedule: "every 30 minutes", timeZone: "Asia/Kuala_Lumpur", timeoutSeconds: 300 }, async () => {
  await endIdleTrips(getFirestore());
});
