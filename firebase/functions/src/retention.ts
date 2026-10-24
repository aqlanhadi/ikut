import {
  Timestamp,
  FieldValue,
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
  /** Planned stops of ended trips that had arrivedAt, leftAt or leftBy cleared. */
  stopsCleared: number;
  /** Skip answers (stops/{s}/answers/{carId}: user id and time) deleted from ended trips. */
  answers: number;
  /** Stop votes (events/{e}/votes/{carId}: user id and time) deleted with their events. */
  votes: number;
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

/** How many events have their votes deleted at once. */
const VOTE_PARALLEL = 20;

/**
 * Deletes the given events, each one's votes first (Firestore leaves a subcollection behind when its parent goes).
 * Votes go before the event, so a run that stops half way leaves the event to retry. Refs may name events that are
 * already gone (their votes are still found and deleted); `events` counts only those that existed.
 */
async function deleteEventsWithVotes(db: Firestore, refs: FirebaseFirestore.DocumentReference[]): Promise<{ events: number; votes: number }> {
  let events = 0;
  let votes = 0;
  for (let i = 0; i < refs.length; i += BATCH_SIZE) {
    const slice = refs.slice(i, i + BATCH_SIZE);
    for (let j = 0; j < slice.length; j += VOTE_PARALLEL) {
      const counts = await Promise.all(slice.slice(j, j + VOTE_PARALLEL).map((r) => deleteInBatches(db, r.collection("votes"))));
      votes += counts.reduce((a, n) => a + n, 0);
    }
    const snaps = await db.getAll(...slice, { fieldMask: [] });
    events += snaps.filter((d) => d.exists).length;
    const batch = db.batch();
    for (const r of slice) batch.delete(r);
    await batch.commit();
  }
  return { events, votes };
}

/** Same, for every document of an events query (the expiry sweep); pages until none match. */
async function deleteEventsWithVotesOf(db: Firestore, base: Query): Promise<{ events: number; votes: number }> {
  const total = { events: 0, votes: 0 };
  for (;;) {
    const page = await base.limit(BATCH_SIZE).get();
    if (page.empty) return total;
    const r = await deleteEventsWithVotes(db, page.docs.map((d) => d.ref));
    total.events += r.events;
    total.votes += r.votes;
    if (page.size < BATCH_SIZE) return total;
  }
}

/** The stop fields that say when the lead car got there and who left; cleared with the positions. */
export const STOP_PRIVATE_FIELDS = ["arrivedAt", "leftAt", "leftBy"] as const;

/**
 * Clears arrivedAt, leftAt and leftBy on every stop of a trip (the stop docs, names and kinds stay for the
 * past-trip view) and deletes the skip answers under each stop. Stops with none of the fields are not written.
 */
async function purgeStopTraces(db: Firestore, tripRef: FirebaseFirestore.DocumentReference): Promise<{ stops: number; answers: number }> {
  const stops = await tripRef.collection("stops").get();
  let cleared = 0;
  let batch = db.batch();
  let pending = 0;
  for (const d of stops.docs) {
    const data = d.data();
    if (!STOP_PRIVATE_FIELDS.some((f) => f in data)) continue;
    batch.update(d.ref, Object.fromEntries(STOP_PRIVATE_FIELDS.map((f) => [f, FieldValue.delete()])));
    cleared++;
    if (++pending === BATCH_SIZE) { await batch.commit(); batch = db.batch(); pending = 0; }
  }
  if (pending > 0) await batch.commit();
  let answers = 0;
  for (const d of stops.docs) answers += await deleteInBatches(db, d.ref.collection("answers"));
  return { stops: cleared, answers };
}

/**
 * Retention sweep. Deletes positions and events (with their stop votes) of ended trips older than POSITION_RETENTION_MS,
 * clears arrivedAt/leftAt/leftBy on their stops and deletes the skip answers (the trip and stop docs stay), then every event past its expiresAt grace period, in any trip.
 */
export async function purgeTripData(db: Firestore, now: Date = new Date()): Promise<PurgeResult> {
  const result: PurgeResult = { trips: 0, failed: 0, stopsCleared: 0, answers: 0, votes: 0, positions: 0, endedTripEvents: 0, expiredEvents: 0 };
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
        const events = await deleteEventsWithVotes(db, await doc.ref.collection("events").listDocuments());
        const traces = await purgeStopTraces(db, doc.ref);
        result.positions += positions;
        result.endedTripEvents += events.events;
        result.votes += events.votes;
        result.stopsCleared += traces.stops;
        result.answers += traces.answers;
        // Purged trips stay in the query, so only count those that had something to delete.
        if (positions + events.events + events.votes + traces.stops + traces.answers > 0) result.trips++;
      } catch (err) {
        result.failed++;
        logger.error("purgeTripData: trip purge failed", { tripId: doc.id, err: String(err) });
      }
    }
    if (page.size < BATCH_SIZE) break;
  }

  // Collection-group sweep: covers active trips too.
  const expired = await deleteEventsWithVotesOf(
    db,
    db.collectionGroup("events").where("expiresAt", "<", eventExpiryCutoff(now)),
  );
  result.expiredEvents = expired.events;
  result.votes += expired.votes;

  logger.info("purgeTripData: done", { ...result });
  return result;
}
