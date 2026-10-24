// The maths of the playground (qa/demo-playground.mjs): where a car is after a second of driving, the straight road a
// car that starts off the route takes to its merge point, the points a simulator plays, who votes on which stop, and
// reading Firestore's REST format. Pure functions, tested in playground.test.mjs.

import { PROJECT_ID } from './firebase-config.mjs';
import { CarRouteLogic, EARTH_RADIUS, Polyline, RouteLine, bearing, haversine, simplifyToFit, truncate } from './route.mjs';

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

/** The points a simulator is told to play on the shared route: the car's point, then every `step` meters up to `ahead` meters on. */
export function feedPoints(route, offset, opts) {
  return trackFeedPoints(buildTrack(route, [mainLeg(0, route.length)]), offset, opts);
}

/** A nudge of about half a meter, alternating, so a parked simulator location counts as a new one. */
export const nudged = (c, n) => ({ latitude: c.latitude + (n % 2 ? 0.000005 : 0), longitude: c.longitude });

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

/**
 * A structured query against the Firestore emulator as its owner (no sign-in, rules bypassed): the matching documents,
 * raw (decode with `decodeDoc`). Throws an Error with `.status` when the emulator answers with an error.
 */
export async function ownerQuery(host, structuredQuery, projectId = PROJECT_ID) {
  const res = await fetch(`http://${host}:8080/v1/projects/${projectId}/databases/(default)/documents:runQuery`, {
    method: 'POST', headers: { Authorization: 'Bearer owner', 'Content-Type': 'application/json' }, body: JSON.stringify({ structuredQuery }),
  });
  if (!res.ok) throw Object.assign(new Error(`Firestore emulator: ${res.status} ${await res.text()}`), { status: res.status });
  return (await res.json()).filter((r) => r.document).map((r) => r.document);
}

/** Whole seconds since `ms`, or null. */
export const ageSeconds = (ms, now) => (typeof ms === 'number' ? Math.max(0, Math.round((now - ms) / 1000)) : null);

// ================================================================ Q7: tracks, pins

/** Longest list of coordinates a command may carry (a Google road for a few hundred km). */
export const MAX_POINTS = 20_000;

/** One coordinate {latitude, longitude} (other fields dropped), else a UserError naming `what`. */
export function coordIn(v, what = 'That place') {
  const lat = v && typeof v === 'object' ? v.latitude : undefined;
  const lng = v && typeof v === 'object' ? v.longitude : undefined;
  if (typeof lat !== 'number' || typeof lng !== 'number' || !Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    throw new UserError(`${what} needs a latitude and a longitude, like 3.45 and 101.40.`);
  }
  return { latitude: lat, longitude: lng };
}

/** A list of coordinates: between `min` and MAX_POINTS points, each valid. */
export function coordsIn(v, what = 'That road', { min = 2 } = {}) {
  if (!Array.isArray(v) || v.length < min) throw new UserError(`${what} needs at least ${min} points.`);
  if (v.length > MAX_POINTS) throw new UserError(`${what} has too many points (the most is ${MAX_POINTS}).`);
  return v.map((p, i) => coordIn(p, `Point ${i + 1} of ${what.toLowerCase()}`));
}

/** The same, but an absent value (undefined or null) is "no road sent". */
export const optionalCoords = (v, what, opts) => (v === undefined || v === null ? null : coordsIn(v, what, opts));

// ---------------------------------------------------------------- tracks
//
// A track is the ordered legs a car drives: a stretch of the shared route (main offsets from-to), an own road (a RouteLine
// with a role: start | out | back | ending), or a wait (zero length, at a pin). A car keeps one distance along its track.

export const mainLeg = (from, to, { park = false } = {}) => ({ kind: 'main', from, to, park });
export const ownLeg = (role, line, id = role) => ({ kind: 'own', role, id, line });
export const waitLeg = (seconds, at, id = 'wait') => ({ kind: 'wait', seconds, at, id });

/** Lays the legs end to end (zero-length main and own legs are dropped). `main` is the shared route's RouteLine. */
export function buildTrack(main, legs) {
  const out = [];
  let at = 0;
  for (const leg of legs) {
    const length = leg.kind === 'main' ? Math.max(0, leg.to - leg.from) : leg.kind === 'own' ? leg.line.length : 0;
    if (leg.kind !== 'wait' && !(length > 0)) continue;
    out.push({ ...leg, startAt: at, length });
    at += length;
  }
  return { main, legs: out, length: at };
}

export const trackLength = (track) => track.length;

/** The old km placement: the shared route from `offset` to its end. */
export const trackFromOffset = (main, offset) => buildTrack(main, [mainLeg(Math.min(main.length, Math.max(0, offset)), main.length)]);

const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

function legAt(track, d, waitingId = null) {
  if (waitingId) {
    const w = track.legs.findIndex((l) => l.id === waitingId && l.kind === 'wait');
    if (w >= 0) return w;
  }
  const dd = clamp(d, 0, track.length);
  let last = -1;
  for (let i = 0; i < track.legs.length; i++) {
    const l = track.legs[i];
    if (l.kind === 'wait') continue;
    last = i;
    if (dd < l.startAt + l.length) return i;
  }
  return last;
}

function pointOn(track, leg, dd) {
  const local = leg.kind === 'wait' ? 0 : clamp(dd - leg.startAt, 0, leg.length);
  if (leg.kind === 'main') return track.main.coordinateAtOffset(leg.from + local);
  if (leg.kind === 'own') return leg.line.coordinateAtOffset(local);
  return leg.at;
}

/** The point at track distance `d` (a wait counts as no distance: the point is where the next leg starts). */
export function trackPoint(track, d) {
  const i = legAt(track, d);
  return i < 0 ? track.main.coordinates[0] : pointOn(track, track.legs[i], clamp(d, 0, track.length));
}

const HEADING_STEP = 25;

/** Heading in degrees at track distance `d`: towards the point 25 m on (or from 25 m back at the very end). */
export function trackHeading(track, d) {
  const dd = clamp(d, 0, track.length);
  const here = trackPoint(track, dd);
  const ahead = trackPoint(track, Math.min(track.length, dd + HEADING_STEP));
  if (haversine(here, ahead) > 0.5) return bearing(here, ahead);
  const behind = trackPoint(track, Math.max(0, dd - HEADING_STEP));
  return haversine(behind, here) > 0.5 ? bearing(behind, here) : 0;
}

/**
 * Where a car is: { index, leg, local (m into the leg), point, heading, onMain, mainOffset (null off the shared route),
 * phase: onRoute | joining | out | waiting | back | ending | arrived }. `waiting` is the id of the wait leg the car is
 * standing at (a wait has no distance, so the car's own state says whether it is in it).
 */
export function locate(track, d, { waiting = null } = {}) {
  const dd = clamp(d, 0, track.length);
  const index = legAt(track, dd, waiting);
  if (index < 0) return { index: -1, leg: null, local: 0, point: track.main.coordinates[0], heading: 0, onMain: true, mainOffset: 0, phase: 'onRoute' };
  const leg = track.legs[index];
  const local = leg.kind === 'wait' ? 0 : clamp(dd - leg.startAt, 0, leg.length);
  const onMain = leg.kind === 'main';
  let phase;
  if (leg.kind === 'main') phase = leg.park && local >= leg.length - 0.5 ? 'arrived' : 'onRoute';
  else if (leg.kind === 'wait') phase = 'waiting';
  else if (leg.role === 'start') phase = 'joining';
  else if (leg.role === 'ending' && local >= leg.length - 0.5) phase = 'arrived';
  else phase = leg.role;
  return { index, leg, local, point: pointOn(track, leg, dd), heading: trackHeading(track, dd), onMain, mainOffset: onMain ? leg.from + local : null, phase };
}

/** The first wait this car still has to stand at, at or ahead of its distance; null when none. */
export function nextWait(track, st) {
  return track.legs.find((l) => l.kind === 'wait' && l.seconds > 0 && !st.served.has(l.id) && l.startAt >= st.d - 0.001) ?? null;
}

export const newCarState = () => ({ d: 0, waiting: null, served: new Set() });

/**
 * One step of driving along the track: `dt` seconds at `kmh`. The car stops at the next wait, stands there for its seconds
 * (the clock runs only while playing), then goes on. Returns a new state { d, waiting: {id, left} | null, served }.
 */
export function stepTrack(track, st, kmh, dt, playing) {
  if (st.waiting) {
    if (!playing) return st;
    const left = st.waiting.left - dt;
    if (left > 0) return { ...st, waiting: { ...st.waiting, left } };
    return { d: st.d, waiting: null, served: new Set([...st.served, st.waiting.id]) };
  }
  if (!playing || !(kmh > 0)) return st;
  const d = st.d + (kmh / 3.6) * dt;
  const w = nextWait(track, st);
  if (w && d >= w.startAt) return { d: w.startAt, waiting: { id: w.id, left: w.seconds }, served: st.served };
  return { ...st, d: clamp(d, 0, track.length) };
}

/** Track distance of shared-route offset `offset`, or null when that stretch is not on the track. */
export function mainDistance(track, offset) {
  const leg = track.legs.find((l) => l.kind === 'main' && offset >= l.from - 0.5 && offset <= l.to + 0.5);
  return leg ? leg.startAt + clamp(offset - leg.from, 0, leg.length) : null;
}

/** Where a car standing at `d` of `oldTrack` is on `newTrack` (same shared-route offset, or the same own leg and place); null when gone. */
export function relocate(oldTrack, d, waitingId, newTrack) {
  const loc = locate(oldTrack, d, { waiting: waitingId });
  if (!loc.leg) return null;
  if (loc.onMain) return mainDistance(newTrack, loc.mainOffset);
  const leg = newTrack.legs.find((l) => l.id === loc.leg.id && l.kind === loc.leg.kind);
  return leg ? leg.startAt + Math.min(loc.local, leg.length) : null;
}

/**
 * A car's state when its track changes to `newTrack`: the same place (see relocate), else `fallbackOffset` on the shared route,
 * else `nearestOffset`; waits already served or in progress are kept only while their leg is still on the new track.
 */
export function carryState(oldTrack, st, newTrack, { fallbackOffset = null, nearestOffset = 0 } = {}) {
  let d = relocate(oldTrack, st.d, st.waiting?.id ?? null, newTrack);
  if (d === null && fallbackOffset !== null) d = mainDistance(newTrack, fallbackOffset);
  if (d === null) d = mainDistance(newTrack, nearestOffset) ?? 0;
  const ids = new Set(newTrack.legs.map((l) => l.id));
  return { d, waiting: st.waiting && ids.has(st.waiting.id) ? st.waiting : null, served: new Set([...st.served].filter((id) => ids.has(id))) };
}

/**
 * The points a simulator plays from track distance `d`: every `step` meters up to `ahead` meters on, or up to `stopAt`
 * (the next wait). Two waypoints at least while there is track left (simctl needs two).
 */
export function trackFeedPoints(track, d, { step = 80, ahead = 25_000, stopAt = null } = {}) {
  const end = Math.min(track.length, stopAt ?? Infinity, d + ahead);
  const pts = [trackPoint(track, d)];
  for (let x = d + step; x < end; x += step) pts.push(trackPoint(track, x));
  if (pts.length < 2 && d < end) pts.push(trackPoint(track, end));
  return pts;
}

// ---------------------------------------------------------------- building tracks from pins

/** Within this distance two points are the same place for stitching roads together. */
const SAME_PLACE = 2;

/** `coords` starting at `first` (prepended when the road does not start there already). */
const startingAt = (coords, first) => (haversine(coords[0], first) > SAME_PLACE ? [first, ...coords] : coords);
const endingAt = (coords, last) => (haversine(coords[coords.length - 1], last) > SAME_PLACE ? [...coords, last] : coords);

/** A straight, densified road from `a` to `b` (every `step` meters). */
export function straightRoad(a, b, step = 40) {
  const line = new RouteLine([a, b]);
  const out = [];
  for (let m = 0; m < line.length; m += step) out.push(line.coordinateAtOffset(m));
  out.push(b);
  return out;
}

/** The coordinates of `line` from `offset` on. */
export function sliceFrom(line, offset) {
  return [line.coordinateAtOffset(offset), ...line.coordinates.filter((_, i) => line.cumulative[i] > offset)];
}

/** A synthetic side road: leaves the route at `offset` and goes `meters` out to the left (or right: side 90), every `step` meters. */
export function sideRoad(main, offset, meters, { side = -90, step = 40 } = {}) {
  const a = main.coordinateAtOffset(offset);
  const b = main.coordinateAtOffset(offset + 25);
  const heading = bearing(a, b);
  const out = [a];
  for (let m = step; m <= meters; m += step) out.push(destinationPoint(a, heading + side, m));
  return out;
}

/** The shared route for `meters` from `offset`, as coordinates every `step` meters. */
function alongMain(main, offset, meters, step = 40) {
  const out = [];
  for (let m = step; m <= meters; m += step) out.push(main.coordinateAtOffset(Math.min(main.length, offset + m)));
  return out;
}

/**
 * The road of a car whose start has no Google road (no Maps key): a straight line from the start to the shared route about
 * `ahead` meters ahead of the start's nearest point, then `tail` meters along the route (so CarRouteLogic finds the merge).
 */
export function fallbackStartRoad(main, start, { ahead = 1500, tail = 600 } = {}) {
  const p = main.project(start);
  const mergeAt = Math.min(main.length, p.offset + ahead);
  const target = main.coordinateAtOffset(mergeAt);
  return [...straightRoad(start, target), ...alongMain(main, mergeAt, tail)];
}

/**
 * A car that starts at a pin. Within CarRouteLogic.nearMainThreshold of the shared route it starts on it: { kind: 'main', offset }.
 * Otherwise `road` (Google's road from the pin towards the destination, or a straight fallback) is cut at the merge:
 * { kind: 'road', line (the own leg, start to merge), mergeMain, mergeOwn, plan (CarRouteLogic.makePlan: what the car doc gets), straight }.
 */
export function planStart(main, start, road = null) {
  const near = main.project(start);
  if (!near) throw new UserError('The trip has no route yet.');
  if (near.distance <= CarRouteLogic.nearMainThreshold) return { kind: 'main', offset: near.offset };
  let coords = road && road.length >= 2 ? startingAt(road, start) : null;
  let plan = coords && CarRouteLogic.makePlan(coords, main);
  let straight = false;
  if (!plan || plan.kind !== 'merges') {
    coords = fallbackStartRoad(main, start);
    plan = CarRouteLogic.makePlan(coords, main);
    straight = true;
  }
  const full = new RouteLine(coords);
  const merge = main.mergeOffset(full, CarRouteLogic.mergeTolerance);
  if (!merge || !plan) throw new UserError('That road never reaches the shared route.');
  const line = new RouteLine(truncate(full, merge.otherOffset));
  if (line.length < 1) return { kind: 'main', offset: merge.mainOffset };
  return { kind: 'road', line, mergeMain: merge.mainOffset, mergeOwn: merge.otherOffset, plan, straight };
}

/**
 * Where `road` (a RouteLine) leaves the shared route for good: the last point within `tolerance` of it.
 * { roadOffset, mainOffset } there; { ..., never: true } when no point of the road is on the route (it leaves at its start);
 * null when the road ends on the route (it never leaves).
 */
export function divergeOffset(main, road, tolerance = CarRouteLogic.mergeTolerance, step = 25) {
  const samples = [];
  for (let s = 0; s < road.length; s += step) samples.push(s);
  samples.push(road.length);
  const hints = [];
  let hint = null;
  let lastOn = -1;
  samples.forEach((s, i) => {
    const p = main.project(road.coordinateAtOffset(s), { hint, fallbackDistance: tolerance * 2 });
    hint = p.segmentIndex;
    hints.push(hint);
    if (p.distance <= tolerance) lastOn = i;
  });
  if (lastOn < 0) return { roadOffset: 0, mainOffset: main.project(road.coordinates[0]).offset, never: true };
  if (lastOn === samples.length - 1) return null;
  let lo = samples[lastOn];
  let hi = samples[lastOn + 1];
  const h = hints[lastOn];
  while (hi - lo > 1) {
    const mid = (lo + hi) / 2;
    const p = main.project(road.coordinateAtOffset(mid), { hint: h, fallbackDistance: tolerance * 2 });
    if (p.distance <= tolerance) lo = mid; else hi = mid;
  }
  return { roadOffset: lo, mainOffset: main.project(road.coordinateAtOffset(lo), { hint: h, fallbackDistance: tolerance * 2 }).offset };
}

/**
 * A car's own ending: `road` runs from a point on the shared route to `end` (without `road`, a straight line from the leave
 * point, which then needs `leaveKm`). With `leaveKm` the car leaves the route there; without, where the road leaves it for good.
 * { kind: 'road', line (leave point to end), leaveOffset, end, plan (what the car doc gets: a road that never rejoins) }, or
 * { kind: 'onRoute', parkOffset } when the end is on the shared route (the car just parks there).
 */
export function planEnding(main, { end, road = null, leaveKm = null }) {
  const hasLeave = leaveKm !== null && leaveKm !== undefined;
  if (!road && !hasLeave) throw new UserError('Without a road the ending needs the km where the car leaves the route.');
  let leaveOffset;
  let coords;
  if (hasLeave) {
    leaveOffset = clamp(leaveKm * 1000, 0, main.length);
    const from = main.coordinateAtOffset(leaveOffset);
    coords = road ? startingAt(road, from) : straightRoad(from, end);
  } else {
    const full = new RouteLine(road);
    const d = divergeOffset(main, full);
    if (d === null) return { kind: 'onRoute', parkOffset: main.project(end).offset, end };
    leaveOffset = d.mainOffset;
    coords = startingAt(sliceFrom(full, d.roadOffset), main.coordinateAtOffset(leaveOffset));
  }
  coords = endingAt(coords, end);
  const line = new RouteLine(coords);
  if (line.length < 1) throw new UserError('The ending is where the car leaves the route; pick a place further away.');
  return { kind: 'road', line, leaveOffset, end, plan: CarRouteLogic.makePlan(coords, main) };
}

/**
 * A deviation: the car leaves the shared route at `leaveKm`, drives `out` to the `pin`, waits, and drives `back` (a road from
 * the pin towards the destination, cut where it meets the shared route again). Without roads, straight lines (a fallback for no
 * Maps key). { leaveOffset, out (RouteLine), back (RouteLine), mergeMain, pin, plan (the car doc: out + back as one road) }.
 */
export function planDeviation(main, { leaveKm, pin, out = null, back = null }) {
  const leaveOffset = clamp(leaveKm * 1000, 0, main.length);
  const from = main.coordinateAtOffset(leaveOffset);
  const outCoords = endingAt(out ? startingAt(out, from) : straightRoad(from, pin), pin);
  let backCoords = back ? startingAt(back, pin) : null;
  if (!backCoords) backCoords = [pin, ...fallbackStartRoad(main, pin)];
  const combined = [...outCoords, ...backCoords.slice(1)];
  const plan = CarRouteLogic.makePlan(combined, main);
  if (!plan || plan.kind !== 'merges') throw new UserError('The way back from that pin never meets the route again. Try a pin nearer a road that leads on.');
  const full = new RouteLine(combined);
  const merge = main.mergeOffset(full, CarRouteLogic.mergeTolerance);
  const outLine = new RouteLine(outCoords);
  if (!merge || merge.otherOffset <= outLine.length + 1) throw new UserError('The way back joins the route before the pin. Pick a pin further off the route.');
  const backLine = new RouteLine(truncate(new RouteLine(backCoords), merge.otherOffset - outLine.length));
  return { leaveOffset, out: outLine, back: backLine, mergeMain: merge.mainOffset, pin, plan };
}

/** How far behind a car's earlier point a new leave point may be before it is a mistake (the page computes it from a spot just passed). */
export const LEAVE_SLACK = 200;

/**
 * Lays a car's whole track from its pieces: `startOffset` (or `start`, a planStart road, then its merge), then an optional
 * deviation (shared route to its leave point, out, wait, back), then an optional ending (shared route to its leave point and
 * its own road, or just the shared route to a parking offset). Throws a UserError when the pieces do not fit in that order.
 */
export function composeTrack(main, { startOffset = 0, start = null, deviation = null, ending = null }) {
  const legs = [];
  let cursor;
  if (start) { legs.push(ownLeg('start', start.line, 'start')); cursor = start.mergeMain; } else cursor = clamp(startOffset, 0, main.length);
  const leaveAfter = (leave, message) => {
    if (leave < cursor - LEAVE_SLACK) throw new UserError(message);
    return Math.max(cursor, leave);
  };
  const afterWhat = deviation ? 'before this deviation is over' : start ? 'before the car has joined the route' : 'behind where the car starts';
  if (deviation) {
    const leave = leaveAfter(deviation.leaveOffset, start ? 'The deviation leaves the route before the car has joined it.' : 'The deviation leaves the route behind where the car starts.');
    if (deviation.mergeMain < leave) throw new UserError('The way back joins the route behind the point where the car leaves it.');
    const tag = deviation.id ?? 0; // each deviation has its own leg ids, so a second one waits again
    legs.push(mainLeg(cursor, leave), ownLeg('out', deviation.out, `out${tag}`), waitLeg(deviation.waitSeconds, deviation.pin, `wait${tag}`), ownLeg('back', deviation.back, `back${tag}`));
    cursor = deviation.mergeMain;
  }
  if (ending && ending.kind === 'onRoute') legs.push(mainLeg(cursor, Math.max(cursor, ending.parkOffset), { park: true }));
  else if (ending) {
    const leave = leaveAfter(ending.leaveOffset, `The ending leaves the route ${afterWhat}.`);
    legs.push(mainLeg(cursor, leave), ownLeg('ending', ending.line));
  } else legs.push(mainLeg(cursor, main.length));
  return buildTrack(main, legs);
}

// ---------------------------------------------------------------- the cars

export const MAX_GENERATED = 8;
export const FIRST_NAMES = ['Mei Ling', 'Arjun', 'Siti', 'Kumar', 'Aina', 'Wei Jie', 'Farah', 'Raj'];
export const CAR_MODELS = ['Myvi', 'Axia', 'Saga', 'City', 'X70', 'Hilux', 'Persona', 'Vios'];
/** Distinct from the phones (#0a6cff, #d9480f), Daniel (#7C3AED), Hafiz (#0F766E) and each other. */
export const PALETTE = ['#c2255c', '#2b8a3e', '#b08900', '#1098ad', '#495057', '#8b5e34'];

/** The next generated car's first name, car name and colour, skipping those in use (`used`: [{ label, color }]). */
export function nextCar(used, counter = used.length) {
  const labels = new Set(used.map((u) => u.label));
  const colors = new Set(used.map((u) => String(u.color).toLowerCase()));
  const label = FIRST_NAMES.find((n) => !labels.has(n)) ?? `Car ${counter + 1}`;
  const color = PALETTE.find((c) => !colors.has(c)) ?? PALETTE[counter % PALETTE.length];
  return { label, name: carNameFor(label, counter), color };
}

/** "Mei Ling’s Myvi": the car name for a first name; `n` picks the model. */
export const carNameFor = (label, n = 0) => `${label}’s ${CAR_MODELS[((n % CAR_MODELS.length) + CAR_MODELS.length) % CAR_MODELS.length]}`;

/** A first name typed by the person: trimmed, 1 to 30 characters. */
export function nameIn(v) {
  const s = typeof v === 'string' ? v.trim().replace(/\s+/g, ' ') : '';
  if (s.length < 1 || s.length > 30) throw new UserError('A name should be 1 to 30 letters.');
  return s;
}

// ---------------------------------------------------------------- events and answers

/** A stop request closes itself this long after it was asked (EventCategory.stopRequest.defaultExpiry, the rules' cap on expiresAt). */
export const STOP_LIFETIME_SECONDS = 30 * 60;

/** What the Report sheet and the stop buttons write, as the app does (TripEvent.swift: category, severity, expiry). */
export const EVENT_KINDS = {
  debris: { category: 'hazard', severity: 'high', expirySeconds: 45 * 60 },
  accident: { category: 'hazard', severity: 'high', expirySeconds: 45 * 60 },
  pothole: { category: 'hazard', severity: 'high', expirySeconds: 45 * 60 },
  animal: { category: 'hazard', severity: 'high', expirySeconds: 45 * 60 },
  stoppedVehicle: { category: 'hazard', severity: 'high', expirySeconds: 45 * 60 },
  roadworks: { category: 'hazard', severity: 'high', expirySeconds: 45 * 60 },
  heavyRain: { category: 'condition', severity: 'medium', expirySeconds: 60 * 60 },
  trafficJam: { category: 'condition', severity: 'medium', expirySeconds: 60 * 60 },
  stopRest: { category: 'stopRequest', severity: 'medium', expirySeconds: STOP_LIFETIME_SECONDS },
  stopFuel: { category: 'stopRequest', severity: 'medium', expirySeconds: STOP_LIFETIME_SECONDS },
  stopFood: { category: 'stopRequest', severity: 'medium', expirySeconds: STOP_LIFETIME_SECONDS },
  stopToilet: { category: 'stopRequest', severity: 'medium', expirySeconds: STOP_LIFETIME_SECONDS },
  pullingOver: { category: 'status', severity: 'high', expirySeconds: null },
  carTrouble: { category: 'status', severity: 'high', expirySeconds: null },
  runningLate: { category: 'status', severity: 'high', expirySeconds: null },
};
export const STOP_TYPES = ['stopRest', 'stopFuel', 'stopFood', 'stopToilet'];
export const REPORT_TYPES = Object.keys(EVENT_KINDS).filter((t) => !STOP_TYPES.includes(t));

/** The kind of a type a person may ask for: one of `allowed`, else a UserError. */
export function eventKindIn(type, allowed, what) {
  if (typeof type !== 'string' || !allowed.includes(type)) throw new UserError(`${what} should be one of: ${allowed.join(', ')}.`);
  return { type, ...EVENT_KINDS[type] };
}

/** The longest message a stop request may carry (the rules' limit on `message`). */
export const MAX_MESSAGE = 280;

/** A passenger's optional message: trimmed, or null when empty; a UserError past 280 characters. */
export function messageIn(text) {
  if (text === undefined || text === null) return null;
  if (typeof text !== 'string') throw new UserError('A message is text.');
  const t = text.trim();
  if (t.length > MAX_MESSAGE) throw new UserError(`A message can be up to ${MAX_MESSAGE} letters.`);
  return t || null;
}

/** { carKey: true } for the cars that said OK on an event's vote docs; votes of cars outside the playground are left out. */
export function oksByCar(votes, keyOf) {
  const out = {};
  for (const v of votes) {
    const key = keyOf.get(v.id);
    if (key) out[key] = true;
  }
  return out;
}

/** open | closed: a request that was closed, or that has expired (30 minutes after it was asked), is closed; a hazard is open until it expires. */
export function eventStatus(e, now) {
  return e.status === 'closed' || (typeof e.expiresAt === 'number' && e.expiresAt <= now) ? 'closed' : 'open';
}

/** A stop request a car may still answer: not closed and not expired (the rules' openStop), from a client snapshot (Timestamps). */
export function openStopSnapshot(e, now = Date.now()) {
  const exp = e.expiresAt?.toMillis ? e.expiresAt.toMillis() : e.expiresAt;
  return e.category === 'stopRequest' && e.status !== 'closed' && !(typeof exp === 'number' && exp <= now);
}

/** The encoded form of a RouteLine's points for a map (simplified when very long). */
export const encodeLine = (line) => Polyline.encode(simplifyToFit(line.coordinates, 60_000));


/**
 * The deviation the car has been seen driving (out, waiting or back), as one decision: a deviation is over once the car has been off the route
 * for it and is back on it. Replacing or clearing the deviation forgets what was seen, or the next one is "over" before the car has left.
 */
export function deviationStep({ deviation, seen }, phase) {
  const seenNow = Boolean(deviation) && (seen || ['out', 'waiting', 'back'].includes(phase));
  return { seen: seenNow, over: Boolean(deviation) && seenNow && phase === 'onRoute' };
}
export const seenAfterChange = (before, after, seen) => (before === after ? seen : false);
