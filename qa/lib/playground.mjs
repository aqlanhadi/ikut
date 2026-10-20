// The maths of the playground (qa/demo-playground.mjs): where a car is after a second of driving, the straight road a
// car that starts off the route takes to its merge point, the points a simulator plays, who votes on which stop, and
// reading Firestore's REST format. Pure functions, tested in playground.test.mjs.

import { EARTH_RADIUS, RouteLine } from './route.mjs';

export const MAX_KMH = 200;

/** Parse "lat,lng" (a free start). Returns { latitude, longitude } or null. */
export function parseStart(text) {
  const m = /^\s*(-?\d+(?:\.\d+)?)\s*[,;\s]\s*(-?\d+(?:\.\d+)?)\s*$/.exec(String(text ?? ''));
  if (!m) return null;
  const latitude = Number(m[1]);
  const longitude = Number(m[2]);
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;
  return { latitude, longitude };
}

export const clampKmh = (v) => Math.min(MAX_KMH, Math.max(0, Number.isFinite(Number(v)) ? Number(v) : 0));

/** A mistake in a command that can be told to the person in plain words. */
export class UserError extends Error {}

/** A finite number in [lo, hi] (numbers or numeric strings only), else a UserError saying what is wrong. */
export function numberIn(v, lo, hi, what) {
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  if (!Number.isFinite(n) || n < lo || n > hi) throw new UserError(`${what} should be a number from ${lo} to ${hi}.`);
  return n;
}

/** The start of a prepare command: the literal "default", or "lat,lng" text. Nothing else (no objects). */
export function startFrom(v) {
  if (v === undefined || v === null || v === 'default') return 'default';
  if (typeof v !== 'string') throw new UserError('Start should look like 3.45,101.40 (latitude, longitude).');
  const p = parseStart(v);
  if (!p) throw new UserError('Start should look like 3.45,101.40 (latitude, longitude).');
  return p;
}

/** The build folder: under /tmp, plain name, never starting with "-" (xcodebuild would read it as an option). */
export function validDerivedData(v) {
  if (v === undefined || v === null || v === '') return null;
  if (typeof v !== 'string' || !/^\/(tmp|private\/tmp)\/[\w][\w.-]*$/.test(v)) throw new UserError('The build folder should be a folder directly under /tmp, like /tmp/ikut-dd-q4.');
  return v;
}

/** Within this many meters of the route's end a phone is parked (simctl location start needs two waypoints). */
export const PARK_NEAR_END = 80;
export const shouldPark = (offset, length) => length - offset < PARK_NEAR_END;

/**
 * Which new trip to offer. `candidates`: [{ tripId, cars (count), firstCarDistance (m from the start, or null when it has no
 * position yet) }]. Auto-pick only when there is exactly one, with one car, whose first car reports near the start.
 */
export function autoPick(candidates, nearMeters = 300) {
  if (candidates.length !== 1) return null;
  const c = candidates[0];
  return c.cars === 1 && c.firstCarDistance !== null && c.firstCarDistance <= nearMeters ? c : null;
}

/** One step of driving: meters along the route after `dt` seconds at `kmh`. Stops at the end. */
export function advanceOffset(offset, kmh, dt, length) {
  return Math.min(length, Math.max(0, offset + (kmh / 3.6) * dt));
}

/** The point `meters` away from `p` in direction `bearingDeg` (great circle). */
export function destinationPoint(p, bearingDeg, meters) {
  const rad = Math.PI / 180;
  const d = meters / EARTH_RADIUS;
  const b = bearingDeg * rad;
  const lat1 = p.latitude * rad;
  const lon1 = p.longitude * rad;
  const lat2 = Math.asin(Math.sin(lat1) * Math.cos(d) + Math.cos(lat1) * Math.sin(d) * Math.cos(b));
  const lon2 = lon1 + Math.atan2(Math.sin(b) * Math.sin(d) * Math.cos(lat1), Math.cos(d) - Math.sin(lat1) * Math.sin(lat2));
  return { latitude: lat2 / rad, longitude: ((lon2 / rad + 540) % 360) - 180 };
}

/**
 * The road of a car that starts off the route: from a side point `sideMeters` from the route (to the left of the
 * direction of travel, about `runUp` meters before the merge) in a straight, densified line to the merge point at
 * `mergeOffset`, then on along the route for `tail` meters (CarRouteLogic cuts it 500 m past the merge).
 * Returns the coordinates.
 */
export function offRouteCoords(route, mergeOffset, sideMeters, { runUp = 1500, tail = 600, step = 40 } = {}) {
  const merge = route.coordinateAtOffset(mergeOffset);
  const back = route.coordinateAtOffset(Math.max(0, mergeOffset - runUp));
  const ahead = route.coordinateAtOffset(Math.max(0, mergeOffset - runUp) + 25);
  const dLat = ahead.latitude - back.latitude;
  const dLon = (ahead.longitude - back.longitude) * Math.cos((back.latitude * Math.PI) / 180);
  const heading = (Math.atan2(dLon, dLat) * 180) / Math.PI; // bearing of the route there
  const side = destinationPoint(back, heading - 90, sideMeters);
  const line = new RouteLine([side, merge]);
  const out = [];
  for (let m = 0; m < line.length; m += step) out.push(line.coordinateAtOffset(m));
  out.push(merge);
  for (let m = step; m <= tail; m += step) out.push(route.coordinateAtOffset(Math.min(route.length, mergeOffset + m)));
  return out;
}

/** The points a simulator is told to play: the car's point, then every `step` meters up to `ahead` meters on. */
export function feedPoints(route, offset, { step = 80, ahead = 25_000 } = {}) {
  const pts = [route.coordinateAtOffset(offset)];
  for (let off = offset + step; off < Math.min(route.length, offset + ahead); off += step) pts.push(route.coordinateAtOffset(off));
  if (pts.length < 2 && offset < route.length) pts.push(route.coordinateAtOffset(route.length)); // simctl needs two waypoints
  return pts;
}

/** A nudge of about half a meter, alternating, so a parked simulator location counts as a new one. */
export const nudged = (c, n) => ({ latitude: c.latitude + (n % 2 ? 0.000005 : 0), longitude: c.longitude });

/** An open stop request: category stopRequest, not resolved (no expiresAt yet). */
export const isOpenStop = (e) => e.category === 'stopRequest' && !e.expiresAt;

/**
 * Which open stop requests a car should vote on now. `seen` is a Map eventId -> first time seen (ms), updated here;
 * `voted` a Set of event ids. A car waits `delayMs` after it first sees a request, never votes on its own, once.
 */
export function pendingVotes(events, carId, seen, voted, now, delayMs = 5000) {
  const due = [];
  for (const e of events) {
    if (!isOpenStop(e) || e.carId === carId || voted.has(e.id)) continue;
    if (!seen.has(e.id)) seen.set(e.id, now);
    if (now - seen.get(e.id) >= delayMs) due.push(e.id);
  }
  return due;
}

/** A place for a suggestion: `ahead` meters in front of the lead car, on the route (the stopStory shape). */
export function suggestionAhead(route, leadOffset, name, ahead = 4000) {
  const routeOffset = Math.min(route.length, leadOffset + ahead);
  const c = route.coordinateAtOffset(routeOffset);
  return { name, latitude: c.latitude, longitude: c.longitude, routeOffset };
}

// ---- Firestore REST (the emulator, as the owner): { fields: { a: { stringValue } } } to plain objects

export function decodeValue(v) {
  if (v === null || v === undefined) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('nullValue' in v) return null;
  if ('timestampValue' in v) return Date.parse(v.timestampValue);
  if ('geoPointValue' in v) return { latitude: v.geoPointValue.latitude ?? 0, longitude: v.geoPointValue.longitude ?? 0 };
  if ('arrayValue' in v) return (v.arrayValue.values ?? []).map(decodeValue);
  if ('mapValue' in v) return decodeFields(v.mapValue.fields);
  return null;
}
export function decodeFields(fields = {}) {
  return Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, decodeValue(v)]));
}
/** A REST document to { id, ...fields }; timestamps become ms since the epoch. */
export const decodeDoc = (d) => ({ id: d.name.split('/').pop(), ...decodeFields(d.fields) });

/** Whole seconds since `ms`, or null. */
export const ageSeconds = (ms, now) => (typeof ms === 'number' ? Math.max(0, Math.round((now - ms) / 1000)) : null);
