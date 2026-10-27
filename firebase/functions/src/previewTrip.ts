import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { NO_ACTIVE_TRIP, findActiveTripId, isRecord, normalizeCode } from "./joinTrip.js";
import { simplifiedRoute } from "./previewRoute.js";
import type { Car, Member, PlannedStop, PreviewCar, PreviewStop, PreviewTripResult, Trip } from "./model.js";

/**
 * Read-only view of an active trip for someone who is not a member yet. No member ids or tracker uids.
 *
 * What a holder of the code can see (and nothing else):
 * - the trip's name and destination (name and coordinate);
 * - the organiser's first name (`organizerName`), the form the lobby shows to members;
 * - the trip's MAIN route only, simplified to about 100 m (`route`, precision-5 polyline, at most 400 points);
 * - the planned stops not skipped or left: name, kind, minutes, coordinate, and `meetAt` (epoch ms) on the meeting point;
 * - each car's id, name, colour, badge number and whether a phone already shares it.
 * Never sent: any member's own start, own route (`cars/*.route`), position, join point, phone/push token, display name
 * or user id (the organiser id, tracker uids and member ids stay on the server), stop notes or skip details.
 */
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
  const plannedStops = stopsSnap.docs
    .map((d) => d.data() as PlannedStop)
    .filter((s) => s.skipped !== true && !s.leftAt && !s.leftBy)
    .sort((a, b) => a.order - b.order)
    // Copy field by field: the stop document also holds its place on the map, notes and who skipped it.
    .map((s) => {
      const c = s.coordinate;
      const meetMs = s.kind === "meet" && typeof s.meetAt?.toMillis === "function" ? s.meetAt.toMillis() : undefined;
      return {
        name: s.name,
        kind: s.kind,
        ...(typeof s.minutes === "number" ? { minutes: s.minutes } : {}),
        ...(c && typeof c.latitude === "number" && typeof c.longitude === "number"
          ? { coordinate: { latitude: c.latitude, longitude: c.longitude } }
          : {}),
        ...(meetMs !== undefined ? { meetAt: meetMs } : {}),
      };
    });
  const stops: PreviewStop[] = plannedStops;
  const organizerName = await firstNameOf(tripRef, trip.organizerId);
  const route = simplifiedRoute(trip.route);
  const { latitude, longitude } = trip.destination.coordinate;
  const destinationCoordinate = typeof latitude === "number" && typeof longitude === "number" ? { latitude, longitude } : undefined;
  return {
    tripId,
    name: trip.name,
    destinationName: trip.destination.name,
    ...(destinationCoordinate ? { destinationCoordinate } : {}),
    ...(organizerName ? { organizerName } : {}),
    ...(route ? { route } : {}),
    cars,
    ...(stops.length > 0 ? { stops } : {}),
  };
}

/** First word of the organiser's display name, as the lobby shows it; undefined when there is none. */
async function firstNameOf(tripRef: FirebaseFirestore.DocumentReference, organizerId: unknown): Promise<string | undefined> {
  if (typeof organizerId !== "string" || organizerId.length === 0) return undefined;
  const snap = await tripRef.collection("members").doc(organizerId).get();
  const name = (snap.data() as Member | undefined)?.displayName;
  const first = typeof name === "string" ? name.trim().split(/\s+/)[0] : "";
  return first ? first : undefined;
}

export const previewTrip = onCall(async (request): Promise<PreviewTripResult> => {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Sign in to join a trip.");
  if (!isRecord(request.data)) throw new HttpsError("invalid-argument", "Invalid request.");
  const code = normalizeCode(request.data.code);
  const db = getFirestore();
  const tripId = await findActiveTripId(db, code);
  return previewTripData(db, tripId);
});
