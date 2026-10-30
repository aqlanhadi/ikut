import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { releaseCreate, reserveCreate } from "./createLimit.js";
import { createTripWithFreeCode, parseCreateInput, type CreateTripResult } from "./createTrip.js";
import { appCheckOptions } from "./joinTrip.js";

// The only way to make a trip (D108): the rules refuse a client create, so nobody can probe codes by creating.
export const createTrip = onCall(appCheckOptions, async (request): Promise<CreateTripResult> => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to start a trip.");
  const input = parseCreateInput(request.data);
  const db = getFirestore();
  const slot = await reserveCreate(db, uid);
  try {
    return await createTripWithFreeCode(db, uid, input);
  } catch (err) {
    await releaseCreate(db, uid, slot);
    throw err;
  }
});
