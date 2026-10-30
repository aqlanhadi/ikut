import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { appCheckOptions } from "./joinTrip.js";
import { isValidTripId, rotateCodeForUser } from "./rotateTrip.js";

export const rotateTripCode = onCall(appCheckOptions, async (request): Promise<{ code: string }> => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  const tripId: unknown = (request.data as { tripId?: unknown } | null)?.tripId;
  if (!isValidTripId(tripId)) throw new HttpsError("invalid-argument", "Choose a trip.");
  return rotateCodeForUser(getFirestore(), uid, tripId);
});
