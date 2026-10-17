import { initializeApp } from "firebase-admin/app";
import { setGlobalOptions } from "firebase-functions/v2";

initializeApp();
setGlobalOptions({ region: "asia-southeast1", maxInstances: 10 });

// Real functions arrive in T2 (joinTrip), T7 and A2.
export { joinTrip } from "./joinTrip.js";
