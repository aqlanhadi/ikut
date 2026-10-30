import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { emptyPurgeResult, purgeTripData, sweepExpiredEvents } from "./purge.js";

/**
 * Every 6 hours: positions are deleted at most 6 hours after their 7-day window closes. Each run handles at most
 * MAX_TRIPS_PER_RUN trips inside its time budget and picks up where the last one stopped. It also sweeps expired events.
 */
export const purgeTripDataJob = onSchedule(
  { schedule: "every 6 hours", timeZone: "Asia/Kuala_Lumpur", timeoutSeconds: 540 },
  async () => {
    await purgeTripData(getFirestore());
  },
);

/**
 * Every hour, on its own: events are removed an hour after they expire, so the 6-hourly trip purge (which can be busy
 * with a backlog or fail) is not what that promise hangs on.
 */
export const purgeExpiredEventsJob = onSchedule(
  { schedule: "every 1 hours", timeZone: "Asia/Kuala_Lumpur", timeoutSeconds: 300 },
  async () => {
    const result = emptyPurgeResult();
    await sweepExpiredEvents(getFirestore(), new Date(), result);
    logger.info("purgeExpiredEventsJob: done", { expiredEvents: result.expiredEvents, votes: result.votes });
  },
);
