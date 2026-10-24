// Who is at a stop (D25 piece 3b), ported from the app. Arrival comes from positions only.
//
//   HERE_RADIUS  <- ios/ikut/Convoy/NextStop.swift      (hereRadius: 150 m, either side)
//   isFresh      <- ios/ikut/Hazards/HazardLogic.swift  (isFresh: a fix up to 60 s old; no timestamp counts as fresh)
//   status       <- ios/ikut/Convoy/StopArrival.swift   (status: here / away / unknown)
//   tally        <- ios/ikut/Convoy/StopArrival.swift   (tally: every car once, convoy and joining, by badge number;
//                                                        skipping cars stay as rows but leave the count, D25 5b)
//
// A target is {latitude, longitude, routeOffset, isMeeting}; a car is {id, number, location: {latitude, longitude},
// offset (main-route meters, null while joining), age (s since its fix, null without one), speed (m/s, floored),
// timeToMerge (s, joining cars only)}. A car with no `location` has no position yet.

import { haversine } from './route.mjs';

export const HERE_RADIUS = 150; // m
export const STALE_AFTER = 60; // s

export const isFresh = (age) => age === null || age === undefined || age <= STALE_AFTER;

/** {kind: 'here'} | {kind: 'lastSeenHere'} (within 150 m on a fix older than 60 s) | {kind: 'away', distance, seconds}
 *  (each null when unknown) | {kind: 'unknown'}. */
export function status(car, target, { pace = null } = {}) {
  if (!car.location) return { kind: 'unknown' };
  const straight = haversine(car.location, target);
  const alongRoute = typeof car.offset === 'number' ? Math.abs(target.routeOffset - car.offset) : null;
  const near = straight <= HERE_RADIUS || (alongRoute ?? Infinity) <= HERE_RADIUS;
  if (near) return { kind: isFresh(car.age) ? 'here' : 'lastSeenHere' };
  if (typeof car.offset === 'number' && car.offset > target.routeOffset) return { kind: 'passed' };
  const perMeter = pace ?? (car.speed > 0 ? 1 / car.speed : null);
  if (alongRoute !== null) return { kind: 'away', distance: alongRoute, seconds: perMeter === null ? null : perMeter * alongRoute };
  if (target.isMeeting && typeof car.timeToMerge === 'number') return { kind: 'away', distance: straight, seconds: car.timeToMerge };
  return { kind: 'away', distance: straight, seconds: perMeter === null ? null : perMeter * straight };
}

/** Every car once, by badge number then id: {rows: [{id, status, skipping, notSharing}], here, total, title: "3 of 4 here"}.
 *  `options.skipping` is the set of car ids that said they are skipping the stop, `options.notSharing` the cars nobody
 *  shares location from (no trackerUserId, #231): both stay as rows but are not counted in `here` or `total`. (A car with no position yet is a row with status unknown and counts; the caller passes every trip car.) */
export function tally(target, cars, options = {}) {
  const skipping = options.skipping ?? new Set();
  const notSharing = options.notSharing ?? new Set();
  const rows = [...cars]
    .sort((a, b) => (a.number ?? Infinity) - (b.number ?? Infinity) || (a.id < b.id ? -1 : 1))
    .map((c) => ({ id: c.id, status: status(c, target, options), skipping: skipping.has(c.id), notSharing: notSharing.has(c.id) }));
  const counted = rows.filter((r) => !r.skipping && !r.notSharing);
  const here = counted.filter((r) => r.status.kind === 'here').length;
  return { rows, here, total: counted.length, title: `${here} of ${counted.length} here` };
}
