// Leaving a planned stop (D25 piece 4a), ported from the app.
//
//   isOpen     <- ios/ikut/Model/PlannedStop.swift  (isOpen: not skipped and not left)
//   nextStop   <- ios/ikut/Convoy/NextStop.swift    (next: the first open stop not more than 150 m behind the offset)
//   leavingAt  <- ios/ikut/Convoy/StopLeave.swift   (leavingAt: a meeting point's meetAt, else arrivedAt + minutes)
//
// A stop is a document of trips/{id}/stops as the sim reads it: {name, routeOffset, kind, minutes?, meetAt?, skipped?,
// arrivedAt?, leftAt?}, the times as Firestore Timestamps or epoch milliseconds (anything with toMillis, or a number).

import { HERE_RADIUS } from './stoparrival.mjs';

const millis = (t) => (t === undefined || t === null ? null : typeof t === 'number' ? t : t.toMillis());

export const isOpen = (stop) => stop.skipped !== true && !stop.leftAt && !stop.leftBy;

/** The first open stop by place on the route that `offset` has not left more than the here-radius behind. */
export function nextStop(stops, offset) {
  return stops.filter((s) => isOpen(s) && s.routeOffset >= offset - HERE_RADIUS).sort((a, b) => a.routeOffset - b.routeOffset)[0] ?? null;
}

/** Epoch milliseconds the card reads as "Leaving at", or null (no planned length, or the lead car not counted yet). */
export function leavingAt(stop) {
  if (stop.kind === 'meet') return millis(stop.meetAt);
  const arrived = millis(stop.arrivedAt);
  if (arrived === null || typeof stop.minutes !== 'number') return null;
  return arrived + stop.minutes * 60_000;
}
