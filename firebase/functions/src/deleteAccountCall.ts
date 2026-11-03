import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { deleteAccountForUser } from "./deleteAccount.js";
import { appCheckOptions } from "./joinTrip.js";

/**
 * Deletes the signed-in person's account and everything personal in it (A4; `deleteAccount.ts`). Input: optionally
 * `{tripIds: string[]}`, the trips this phone knows (a hint for members from before `userId` was written); answer
 * `{ok: true}`. Refuses an unauthenticated call. A retry after a failure finishes the job; the Auth user goes last.
 * The 540 s timeout is for a person in many trips.
 */
export const deleteAccount = onCall({ ...appCheckOptions, timeoutSeconds: 540 }, async (request): Promise<{ ok: true }> => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return deleteAccountForUser(getFirestore(), uid, request.data, {
    deleteAuthUser: async (id) => {
      try {
        await getAuth().deleteUser(id);
      } catch (err) {
        if ((err as { code?: string }).code !== "auth/user-not-found") throw err;
      }
    },
  });
});
