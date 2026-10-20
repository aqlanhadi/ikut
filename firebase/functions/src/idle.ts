import type { Position, TimestampLike, Trip, TripEvent } from "./model.js";

/** A trip with no activity for this long is ended. */
export const IDLE_MS = 12 * 60 * 60 * 1000;

export type IdleTrip = Pick<Trip, "status"> & {
  createdAt: TimestampLike;
  lastActivityAt?: TimestampLike | null;
};

/** Newest of the trip's own activity signals: lastActivityAt (may be missing) and createdAt. */
export function tripActivityMillis(trip: Pick<IdleTrip, "createdAt" | "lastActivityAt">): number {
  return Math.max(trip.createdAt.toMillis(), trip.lastActivityAt?.toMillis() ?? 0);
}

/**
 * True when an active trip has seen nothing for IDLE_MS. Activity is the latest of
 * lastActivityAt, createdAt, the newest position update and the newest event.
 */
export function isIdle(
  trip: IdleTrip,
  latestPosition: { updatedAt: TimestampLike } | Pick<Position, "updatedAt"> | null | undefined,
  latestEvent: { createdAt: TimestampLike } | Pick<TripEvent, "createdAt"> | null | undefined,
  now: Date,
): boolean {
  if (trip.status !== "active") return false;
  const last = Math.max(
    tripActivityMillis(trip),
    latestPosition?.updatedAt.toMillis() ?? 0,
    latestEvent?.createdAt.toMillis() ?? 0,
  );
  return now.getTime() - last >= IDLE_MS;
}
