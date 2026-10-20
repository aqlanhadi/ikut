import {
  Timestamp,
  type Firestore,
  type Query,
  type QueryDocumentSnapshot,
} from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import type { TimestampLike, Trip } from "./model.js";

/** Firestore allows 500 writes per batch. */
export const BATCH_SIZE = 500;

/** Location data of an ended trip is deleted this long after the trip ended. */
export const POSITION_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

/** An event is removed only once it has been past its expiresAt for this long. */
export const EVENT_GRACE_MS = 60 * 60 * 1000;

/** True when an ended trip's positions and events are older than the retention window. */
export function shouldPurgeTripData(
  trip: Pick<Trip, "status"> & { endedAt?: TimestampLike | null },
  now: Date,
): boolean {
  if (trip.status !== "ended" || !trip.endedAt) return false;
  return now.getTime() - trip.endedAt.toMillis() > POSITION_RETENTION_MS;
}

/** True when an event's expiresAt is more than EVENT_GRACE_MS in the past. Events without expiresAt never expire. */
export function isEventPastGrace(event: { expiresAt?: TimestampLike | null }, now: Date): boolean {
  if (!event.expiresAt) return false;
  return event.expiresAt.toMillis() < now.getTime() - EVENT_GRACE_MS;
}

/** Events with expiresAt before this instant are past the grace period. */
export function eventExpiryCutoff(now: Date): Timestamp {
  return Timestamp.fromMillis(now.getTime() - EVENT_GRACE_MS);
}

export interface PurgeResult {
  /** Ended trips that had positions or events deleted this run. */
  trips: number;
  /** Ended trips that failed part-way; the next run retries them. */
  failed: number;
  positions: number;
  /** Events deleted from ended trips. */
  endedTripEvents: number;
  /** Expired events deleted from any trip (active trips included). */
  expiredEvents: number;
}

/** Deletes every document of `base` in batches of up to BATCH_SIZE. Deleted docs leave the result, so each page is a fresh query. */
async function deleteInBatches(db: Firestore, base: Query): Promise<number> {
  let deleted = 0;
  for (;;) {
    const page = await base.limit(BATCH_SIZE).get();
    if (page.empty) return deleted;
    const batch = db.batch();
    for (const d of page.docs) batch.delete(d.ref);
    await batch.commit();
    deleted += page.size;
    if (page.size < BATCH_SIZE) return deleted;
  }
}

/**
 * Retention sweep. Deletes positions and events of ended trips older than POSITION_RETENTION_MS
 * (the trip docs stay), then every event past its expiresAt grace period, in any trip.
 */
export async function purgeTripData(db: Firestore, now: Date = new Date()): Promise<PurgeResult> {
  const result: PurgeResult = { trips: 0, failed: 0, positions: 0, endedTripEvents: 0, expiredEvents: 0 };
  const endedBefore = Timestamp.fromMillis(now.getTime() - POSITION_RETENTION_MS);
  let cursor: QueryDocumentSnapshot | undefined;

  // Trip docs are not deleted, so the query keeps matching them; page with a cursor.
  for (;;) {
    let q = db
      .collection("trips")
      .where("status", "==", "ended")
      .where("endedAt", "<", endedBefore)
      .orderBy("endedAt")
      .limit(BATCH_SIZE);
    if (cursor) q = q.startAfter(cursor);
    const page = await q.get();
    if (page.empty) break;
    cursor = page.docs[page.docs.length - 1];

    for (const doc of page.docs) {
      if (!shouldPurgeTripData(doc.data() as Trip, now)) continue;
      try {
        const positions = await deleteInBatches(db, doc.ref.collection("positions"));
        const events = await deleteInBatches(db, doc.ref.collection("events"));
        result.positions += positions;
        result.endedTripEvents += events;
        // Purged trips stay in the query, so only count those that had something to delete.
        if (positions + events > 0) result.trips++;
      } catch (err) {
        result.failed++;
        logger.error("purgeTripData: trip purge failed", { tripId: doc.id, err: String(err) });
      }
    }
    if (page.size < BATCH_SIZE) break;
  }

  // Collection-group sweep: covers active trips too.
  result.expiredEvents = await deleteInBatches(
    db,
    db.collectionGroup("events").where("expiresAt", "<", eventExpiryCutoff(now)),
  );

  logger.info("purgeTripData: done", { ...result });
  return result;
}
