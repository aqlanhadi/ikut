import { FieldValue, getFirestore, type Firestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import type { Trip, TripSummary } from "./model.js";

/** Same sphere as ios/ikut/Route/RouteGeometry.swift `RouteLine.earthRadius`. */
const EARTH_RADIUS = 6_371_008.8;

/**
 * Strict polyline decode (precision 5), like ios/ikut/Model/Polyline.swift `decode`: a truncated or malformed string
 * gives `null` (Swift: an empty list), never a partial route, so the two sides agree on what has a distance.
 */
export function decodeStrict(encoded: string): { lat: number; lng: number }[] | null {
  const out: { lat: number; lng: number }[] = [];
  let i = 0;
  let lat = 0;
  let lng = 0;
  const next = (): number | null => {
    let result = 0;
    let shift = 0;
    while (i < encoded.length) {
      const b = encoded.charCodeAt(i++) - 63;
      // 5 bits a character; past 30 bits the 32-bit math below would overflow, and no real coordinate step needs it.
      if (b < 0 || shift >= 30) return null;
      result |= (b & 0x1f) << shift;
      shift += 5;
      if (b < 0x20) return result & 1 ? ~(result >> 1) : result >> 1;
    }
    return null;
  };
  while (i < encoded.length) {
    const dLat = next();
    const dLng = next();
    if (dLat === null || dLng === null) return null;
    lat += dLat;
    lng += dLng;
    out.push({ lat: lat / 1e5, lng: lng / 1e5 });
  }
  return out;
}

function wrapLongitude(d: number): number {
  if (d > 180) return d - 360;
  if (d < -180) return d + 360;
  return d;
}

/** Great-circle meters; mirrors `RouteLine.haversine`. */
function haversine(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const lat1 = (a.lat * Math.PI) / 180;
  const lat2 = (b.lat * Math.PI) / 180;
  const dLat = lat2 - lat1;
  const dLon = (wrapLongitude(b.lng - a.lng) * Math.PI) / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Mirrors `RecapLogic.routeDistance`: meters along the route, `null` for fewer than two points or a malformed string. */
export function routeDistanceMeters(encoded: string): number | null {
  const pts = decodeStrict(encoded);
  if (!pts || pts.length < 2) return null;
  let sum = 0;
  for (let i = 0; i < pts.length - 1; i++) sum += haversine(pts[i]!, pts[i + 1]!);
  return sum;
}

/**
 * Seconds the trip was underway: `startedAt` (the first Start Trip) to `endedAt`, or `createdAt` when it never
 * started. Like `RecapLogic.duration`, `null` unless the end is after the start. (The live recap counts from
 * `createdAt`, which for a trip planned the day before includes the waiting.)
 */
export function summaryDurationSeconds(trip: Pick<Trip, "createdAt" | "startedAt" | "endedAt">): number | null {
  const start = trip.startedAt ?? trip.createdAt;
  if (!start || !trip.endedAt) return null;
  const seconds = (trip.endedAt.toMillis() - start.toMillis()) / 1000;
  return seconds > 0 ? seconds : null;
}

/**
 * The small summary kept after the trip's data is gone (D107): counts and two numbers, no names, no coordinates, no
 * ids. `stopCount` is the planned stops the lead car reached (stops with `arrivedAt`), not stop requests: those
 * expire after 30 minutes and are swept within the hour, so by the end of a trip they are mostly gone.
 * `roadReportCount` is hazard and condition events still stored when the summary is written (as the recap counts
 * them); a report already swept after it expired is not counted.
 */
export async function buildTripSummary(db: Firestore, tripRef: FirebaseFirestore.DocumentReference, trip: Trip): Promise<Omit<TripSummary, "summarisedAt">> {
  const [members, cars, stops, hazards, conditions] = await Promise.all([
    tripRef.collection("members").count().get(),
    tripRef.collection("cars").count().get(),
    tripRef.collection("stops").get(),
    tripRef.collection("events").where("category", "==", "hazard").count().get(),
    tripRef.collection("events").where("category", "==", "condition").count().get(),
  ]);
  return {
    distanceMeters: routeDistanceMeters(trip.route ?? ""),
    durationSeconds: summaryDurationSeconds(trip),
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
