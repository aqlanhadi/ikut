import { getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { purgeTripData } from "./retention.js";

/**
 * Every 6 hours: positions are deleted at most 6 hours after their 7-day window closes, and expired
 * events at most 6 hours after their 1-hour grace period. Daily would leave expired events and
 * retained positions around for up to 24 hours; hourly adds reads for no practical gain.
 */
export const purgeTripDataJob = onSchedule({ schedule: "every 6 hours", timeZone: "Asia/Kuala_Lumpur" }, async () => {
  await purgeTripData(getFirestore());
});
