import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { handOverTripForUser } from "./handOverTrip.js";
import { appCheckOptions } from "./joinTrip.js";
import { isValidTripId } from "./rotateTrip.js";

/** The organiser hands an active trip to another member (D106); see `handOverTrip.ts`. */
export const handOverTrip = onCall(appCheckOptions, async (request): Promise<{ ok: true }> => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  const data = request.data as { tripId?: unknown; newOrganizerId?: unknown } | null;
  if (!isValidTripId(data?.tripId)) throw new HttpsError("invalid-argument", "Choose a trip.");
  return handOverTripForUser(getFirestore(), uid, data.tripId, data?.newOrganizerId);
});
