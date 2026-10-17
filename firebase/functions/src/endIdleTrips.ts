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

const BATCH_SIZE = 500;

async function latestUpdate<T>(snap: FirebaseFirestore.Query, field: string): Promise<T | null> {
  const res = await snap.orderBy(field, "desc").limit(1).get();
  return res.empty ? null : (res.docs[0]!.data() as T);
}

/** Commit one batch. Each update is pinned to the snapshot we read, so a trip touched since is skipped. */
async function endBatch(db: Firestore, docs: DocumentSnapshot[]): Promise<number> {
  const batch = db.batch();
  for (const d of docs) {
    batch.update(d.ref, { status: "ended", endedAt: FieldValue.serverTimestamp() }, { lastUpdateTime: d.updateTime! });
  }
  try {
    await batch.commit();
    return docs.length;
  } catch {
    // A failed precondition aborts the whole batch; retry one by one so only the changed trips are skipped.
    let ended = 0;
    for (const d of docs) {
      try {
        await d.ref.update({ status: "ended", endedAt: FieldValue.serverTimestamp() }, { lastUpdateTime: d.updateTime! });
        ended++;
      } catch (err) {
        logger.info("endIdleTrips: skipped trip that changed", { tripId: d.id, err: String(err) });
      }
    }
    return ended;
  }
}

/**
 * Ends every active trip idle for 12 hours. Candidates are active trips created more than 12 hours
 * ago (createdAt always exists, lastActivityAt may not); only those get their newest position and
 * event checked. Returns the number of trips ended.
 */
export async function endIdleTrips(db: Firestore, now: Date = new Date()): Promise<number> {
  const cutoff = Timestamp.fromMillis(now.getTime() - IDLE_MS);
  let ended = 0;
  let cursor: QueryDocumentSnapshot | undefined;

  for (;;) {
    let q = db
      .collection("trips")
      .where("status", "==", "active")
      .where("createdAt", "<=", cutoff)
      .orderBy("createdAt")
      .limit(BATCH_SIZE);
    if (cursor) q = q.startAfter(cursor);
    const page = await q.get();
    if (page.empty) break;
    cursor = page.docs[page.docs.length - 1];

    const idle: DocumentSnapshot[] = [];
    for (const doc of page.docs) {
      const trip = doc.data() as Trip;
      // Cheap check first: skip the position and event reads when the trip doc itself is recent.
      if (now.getTime() - tripActivityMillis(trip) < IDLE_MS) continue;
      const [position, event] = await Promise.all([
        latestUpdate<Position>(doc.ref.collection("positions"), "updatedAt"),
        latestUpdate<TripEvent>(doc.ref.collection("events"), "createdAt"),
      ]);
      if (isIdle(trip, position, event, now)) idle.push(doc);
    }
    if (idle.length > 0) ended += await endBatch(db, idle);
    if (page.size < BATCH_SIZE) break;
  }

  logger.info("endIdleTrips: done", { ended });
  return ended;
}

/**
 * Every 30 minutes: the idle limit is 12 hours, so a trip is ended at most 30 minutes late (~4%),
 * while the sweep only reads trips older than 12 hours and stays cheap.
 */
export const endIdleTripsJob = onSchedule({ schedule: "every 30 minutes", timeZone: "Asia/Kuala_Lumpur" }, async () => {
  await endIdleTrips(getFirestore());
});
