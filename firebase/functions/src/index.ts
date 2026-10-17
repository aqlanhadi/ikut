import { initializeApp } from "firebase-admin/app";
import { setGlobalOptions } from "firebase-functions/v2";
import { onCall } from "firebase-functions/v2/https";

initializeApp();
setGlobalOptions({ region: "asia-southeast1", maxInstances: 10 });

// Placeholder. Real functions (joinTrip, event fan-out, idle-trip cleanup) arrive in T2, T7 and A2.
export const ping = onCall(() => {
  return { ok: true, region: "asia-southeast1", time: new Date().toISOString() };
});
