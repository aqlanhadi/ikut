import {
  Timestamp,
  FieldValue,
  type Firestore,
  type Query,
} from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import type { TimestampLike, Trip } from "./model.js";

/** Firestore allows 500 writes per batch. */
export const BATCH_SIZE = 500;

/** Location data of an ended trip is deleted this long after the trip ended. */
export const POSITION_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

/** An ended trip is deleted completely (trip, cars, members, stops and the rest) this long after it ended (D107). Raw positions go at POSITION_RETENTION_MS. */
export const TRIP_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;

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

/** True when an ended trip is past TRIP_RETENTION_MS. An ended trip without endedAt is never deleted (the caller logs it). */
export function shouldDeleteTrip(
  trip: Pick<Trip, "status"> & { endedAt?: TimestampLike | null },
  now: Date,
): boolean {
  if (trip.status !== "ended" || !trip.endedAt) return false;
  return now.getTime() - trip.endedAt.toMillis() > TRIP_RETENTION_MS;
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
  /** Cars of ended trips that had their own route and mergeOffset cleared (the car doc stays for the recap). */
  carsCleared: number;
  /** Member docs of ended trips that had a pushToken cleared (the member doc stays for the recap). */
  tokensCleared: number;
  /** Code claims (codes/{code}) of ended trips deleted, so the code can be used again (D103). */
  codesCleared: number;
  /** Skip answers (stops/{s}/answers/{carId}: user id and time) deleted from ended trips. */
  answers: number;
  /** Stop votes (events/{e}/votes/{carId}: user id and time) deleted with their events. */
  votes: number;
  /** Ended trips that failed part-way; the next run retries them. */
  failed: number;
  /** Trips examined this run (purged or already empty). */
  examined: number;
  /** The run stopped at its trip cap or time budget with old trips still waiting for the next run. */
  more: boolean;
  positions: number;
  /** Events deleted from ended trips. */
  endedTripEvents: number;
  /** Expired events deleted from any trip (active trips included). */
  expiredEvents: number;
}

/** Deletes every document of `base` in batches of up to BATCH_SIZE. Deleted docs leave the result, so each page is a fresh query. */
export async function deleteInBatches(db: Firestore, base: Query): Promise<number> {
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
export async function deleteEventsWithVotes(db: Firestore, refs: FirebaseFirestore.DocumentReference[]): Promise<{ events: number; votes: number }> {
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
export async function deleteEventsWithVotesOf(db: Firestore, base: Query, outOfTime: () => boolean = () => false): Promise<{ events: number; votes: number }> {
  const total = { events: 0, votes: 0 };
  for (;;) {
    if (outOfTime()) return total;
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
export async function purgeStopTraces(db: Firestore, tripRef: FirebaseFirestore.DocumentReference): Promise<{ stops: number; answers: number }> {
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

/** The car fields that hold where a member's own drive began (often their home); cleared with the positions. */
export const CAR_PRIVATE_FIELDS = ["route", "mergeOffset"] as const;
/** The member field that identifies a phone for push; cleared with the positions. */
export const MEMBER_PRIVATE_FIELDS = ["pushToken"] as const;

/** Deletes `fields` from every doc of `col` that has any of them, in batches; returns how many docs were written. */
async function clearFields(db: Firestore, col: FirebaseFirestore.CollectionReference, fields: readonly string[]): Promise<number> {
  const snap = await col.get();
  let cleared = 0;
  let batch = db.batch();
  let pending = 0;
  for (const d of snap.docs) {
    const data = d.data();
    if (!fields.some((f) => f in data)) continue;
    batch.update(d.ref, Object.fromEntries(fields.map((f) => [f, FieldValue.delete()])));
    cleared++;
    if (++pending === BATCH_SIZE) { await batch.commit(); batch = db.batch(); pending = 0; }
  }
  if (pending > 0) await batch.commit();
  return cleared;
}

/**
 * Clears each car's own `route` and `mergeOffset` (a route often starts at the member's home) and each member's
 * `pushToken`. The car and member docs stay: the recap reads the car's name, colour, number and lead flag, and each
 * member's name and car. The trip's main route is kept as it is: it begins where the organizer started, and the recap
 * draws it; only members can read it (owner decision #606).
 */
export async function purgeMemberPrivates(db: Firestore, tripRef: FirebaseFirestore.DocumentReference): Promise<{ cars: number; tokens: number }> {
  const cars = await clearFields(db, tripRef.collection("cars"), CAR_PRIVATE_FIELDS);
  const tokens = await clearFields(db, tripRef.collection("members"), MEMBER_PRIVATE_FIELDS);
  return { cars, tokens };
}

/**
 * Deletes the trip's code claim (codes/{code}, D103) once the trip is past retention. Only a claim that names this
 * trip is removed: a claim is created with the trip, so a doc for the same code under another trip id (an older trip
 * made before claims existed, then a later trip with the same code) is never touched. Returns 1 if it deleted one.
 */
export async function purgeCodeClaim(db: Firestore, tripRef: FirebaseFirestore.DocumentReference, trip: Pick<Trip, "code">): Promise<number> {
  if (typeof trip.code !== "string" || !/^[A-Z0-9]{6}$/.test(trip.code)) return 0;
  const claim = db.collection("codes").doc(trip.code);
  const snap = await claim.get();
  if (!snap.exists || snap.get("tripId") !== tripRef.id) return 0;
  await claim.delete();
  return 1;
}
