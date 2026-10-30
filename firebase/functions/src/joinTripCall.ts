import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { countingMisses } from "./guessLimit.js";
import { appCheckOptions, findActiveTripId, joinTripTransaction, parseJoinInput, type JoinResult } from "./joinTrip.js";

// Separate from joinTrip.ts, which the unit tests load as plain TypeScript and so cannot import this file's neighbours.
export const joinTrip = onCall(appCheckOptions, async (request): Promise<JoinResult> => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to join a trip.");
  const input = parseJoinInput(request.data);
  const db = getFirestore();
  const tripId = await countingMisses(db, uid, () => findActiveTripId(db, input.code));
  return joinTripTransaction(db, uid, tripId, input);
});
