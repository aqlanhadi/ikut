import { FieldValue, getFirestore, type Firestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { IDLE_MS } from "./idle.js";
import type { Trip, TripSummary } from "./model.js";
import { routeDistanceMeters, summaryDurationSeconds } from "./summaryMath.js";

/**
 * The small summary kept after the trip's data is gone (D107): counts and two numbers, no names, no coordinates, no
 * ids. `stopCount` is the planned stops the lead car reached (stops with `arrivedAt`), not stop requests: those
 * expire after 30 minutes and are swept within the hour, so by the end of a trip they are mostly gone.
 * `roadReportCount` is hazard and condition events still stored when the summary is written (as the recap counts
 * them); a report already swept after it expired is not counted.
 */
export async function buildTripSummary(db: Firestore, tripRef: FirebaseFirestore.DocumentReference, trip: Trip): Promise<Omit<TripSummary, "summarisedAt">> {
  const newest = async (col: string, field: string): Promise<number> => {
    const r = await tripRef.collection(col).orderBy(field, "desc").limit(1).get();
    return r.empty ? 0 : (r.docs[0]!.get(field) as { toMillis(): number }).toMillis();
  };
  const [members, cars, stops, hazards, conditions, lastPosition, lastEvent] = await Promise.all([
    tripRef.collection("members").count().get(),
    tripRef.collection("cars").count().get(),
    tripRef.collection("stops").get(),
    tripRef.collection("events").where("category", "==", "hazard").count().get(),
    tripRef.collection("events").where("category", "==", "condition").count().get(),
    newest("positions", "updatedAt"),
    newest("events", "createdAt"),
  ]);
  // The same signals isIdle counts (createdAt, lastActivityAt, newest position and event) plus startedAt.
  const lastActivity = Math.max(trip.createdAt.toMillis(), lastPosition, lastEvent, trip.lastActivityAt?.toMillis() ?? 0, trip.startedAt?.toMillis() ?? 0);
  return {
    distanceMeters: routeDistanceMeters(trip.route ?? ""),
    durationSeconds: summaryDurationSeconds(trip, lastActivity, IDLE_MS),
    peopleCount: members.data().count,
    carCount: cars.data().count,
    stopCount: stops.docs.filter((d) => d.get("arrivedAt") != null).length,
    roadReportCount: hazards.data().count + conditions.data().count,
  };
}

/**
 * Writes `summary` on an ended trip that has none, in a transaction that re-reads the trip, so a second delivery of
 * the trigger, the lazy backfill and a retry never write it twice. Returns true if it wrote one.
 */
export async function summariseTrip(db: Firestore, tripId: string): Promise<boolean> {
  const ref = db.collection("trips").doc(tripId);
  const first = await ref.get();
  const trip = first.data() as Trip | undefined;
  if (!trip || trip.status !== "ended" || first.get("summary") != null) return false;
  const built = await buildTripSummary(db, ref, trip);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.get("status") !== "ended" || snap.get("summary") != null) return false;
    tx.update(ref, { summary: { ...built, summarisedAt: FieldValue.serverTimestamp() } });
    return true;
  });
}

/**
 * Fires on every update of a trip doc but acts only on the change from active to ended (the organizer's End Trip, or
 * endIdleTrips). Its own write happens on an ended trip, so it cannot start itself again. Clients cannot plant a
 * `summary`: the rules' key lists for a trip update do not have it.
 */
export const onTripEnded = onDocumentUpdated("trips/{tripId}", async (event) => {
  const before = event.data?.before.data() as Trip | undefined;
  const after = event.data?.after.data() as (Trip & { summary?: unknown }) | undefined;
  if (before?.status !== "active" || after?.status !== "ended" || after.summary != null) return;
  const wrote = await summariseTrip(getFirestore(), event.params.tripId);
  logger.info("onTripEnded: summary", { tripId: event.params.tripId, wrote });
});
