import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { NO_ACTIVE_TRIP, findActiveTripId, isRecord, normalizeCode } from "./joinTrip.js";
import type { Car, PlannedStop, PreviewCar, PreviewStop, PreviewTripResult, Trip } from "./model.js";

/** Read-only view of an active trip for someone who is not a member yet. No member ids or tracker uids. */
export async function previewTripData(db: Firestore, tripId: string): Promise<PreviewTripResult> {
  const tripRef = db.collection("trips").doc(tripId);
  const [tripSnap, carsSnap, stopsSnap] = await Promise.all([
    tripRef.get(),
    tripRef.collection("cars").get(),
    tripRef.collection("stops").get(),
  ]);
  const trip = tripSnap.data() as Trip | undefined;
  if (!tripSnap.exists || !trip || trip.status !== "active") {
    throw new HttpsError("not-found", NO_ACTIVE_TRIP);
  }
  const cars: PreviewCar[] = carsSnap.docs
    .map((d) => ({ id: d.id, data: d.data() as Car }))
    .map(({ id, data }) => ({
      id,
      name: data.name,
      color: data.color,
      hasTracker: typeof data.trackerUserId === "string" && data.trackerUserId.length > 0,
      ...(typeof data.number === "number" ? { number: data.number } : {}),
      isLead: data.isLead === true,
    }))
    // Lead car first, then by name, so the list is stable.
    .sort((a, b) => Number(b.isLead) - Number(a.isLead) || a.name.localeCompare(b.name) || a.id.localeCompare(b.id))
    .map(({ isLead: _isLead, ...car }) => car);
  const stops: PreviewStop[] = stopsSnap.docs
    .map((d) => d.data() as PlannedStop)
    .filter((s) => s.skipped !== true)
    .sort((a, b) => a.order - b.order)
    // Copy field by field: the stop document also holds its place on the map, notes and who skipped it.
    .map((s) => ({ name: s.name, kind: s.kind, ...(typeof s.minutes === "number" ? { minutes: s.minutes } : {}) }));
  return { tripId, name: trip.name, destinationName: trip.destination.name, cars, ...(stops.length > 0 ? { stops } : {}) };
}

export const previewTrip = onCall(async (request): Promise<PreviewTripResult> => {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Sign in to join a trip.");
  if (!isRecord(request.data)) throw new HttpsError("invalid-argument", "Invalid request.");
  const code = normalizeCode(request.data.code);
  const db = getFirestore();
  const tripId = await findActiveTripId(db, code);
  return previewTripData(db, tripId);
});
