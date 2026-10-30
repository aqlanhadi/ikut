import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { limitsFor, releaseCreate, reserveCreate, type CreateLimits } from "./createLimit.js";
import { createTripWithFreeCode, parseCreateInput, type CreateTripResult } from "./createTrip.js";
import { appCheckOptions } from "./joinTrip.js";

/**
 * The body of the callable, apart from sign-in: check the input, reserve a slot, create; a call that creates nothing
 * gives its slot back. `opts` is for tests (a fixed draw, fewer tries, other limits).
 */
export async function createTripForUser(
  db: Firestore,
  uid: string,
  data: unknown,
  opts: { random?: () => number; maxTries?: number; limits?: CreateLimits } = {},
): Promise<CreateTripResult> {
  const input = parseCreateInput(data);
  const slot = await reserveCreate(db, uid, Date.now(), opts.limits ?? limitsFor());
  try {
    return await createTripWithFreeCode(db, uid, input, opts);
  } catch (err) {
    await releaseCreate(db, uid, slot);
    throw err;
  }
}

// The only way to make a trip (D108): the rules refuse a client create, so nobody can probe codes by creating.
export const createTrip = onCall(appCheckOptions, async (request): Promise<CreateTripResult> => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to start a trip.");
  return createTripForUser(getFirestore(), uid, request.data);
});
