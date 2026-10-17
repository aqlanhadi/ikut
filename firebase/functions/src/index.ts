import { initializeApp } from "firebase-admin/app";
import { setGlobalOptions } from "firebase-functions/v2";

initializeApp();
setGlobalOptions({ region: "asia-southeast1", maxInstances: 10 });

// Real functions arrive in T2 (joinTrip), T3 (previewTrip), T7 (endIdleTripsJob) and A2.
export { joinTrip } from "./joinTrip.js";
export { previewTrip } from "./previewTrip.js";
export { endIdleTripsJob } from "./endIdleTrips.js";
export { purgeTripDataJob } from "./purgeTripDataJob.js";
export { onMemberDeleted } from "./memberCleanup.js";
