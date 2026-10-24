// The route rebuilt mid-trip (D25 4d), ported from the app, plus the geometry the rebuild scenario drives on.
//
//   rebuildRoute <- ios/ikut/Trip/RouteRebuild.swift (build, cutOffset, ahead): the old line is kept point for point up
//                   to where the organizer is, then the legs go through the open stops still ahead to the destination
//   join         <- ios/ikut/Trip/StopRouting.swift  (join: a leg's first point within 3 m of the last is dropped; the
//                   offset of each stop is the line's cumulative distance at the junction)
//   isOpen       <- lib/stopleave.mjs (PlannedStop.isOpen)
//
// Maps is not here: a leg is the stretch of `directLine` (the real road) between its two ends, which is what Maps
// answers for a road that is there. The stops are {id, name, coordinate: {latitude, longitude}, routeOffset, kind,
// order, skipped?, leftAt?, arrivedAt?}.

import { RouteLine, bearing, haversine, truncate, Polyline } from './route.mjs';
import { isOpen } from './stopleave.mjs';

export const JUNCTION_TOLERANCE = 3; // m, StopRouting.junctionTolerance
export const ON_ROUTE_TOLERANCE = 100; // m, OffRouteDetector.distance

const RAD = Math.PI / 180;

/** The point `meters` from `from` along `bearingDegrees`. */
export function destinationPoint(from, bearingDegrees, meters) {
  const d = meters / 6_371_008.8;
  const b = bearingDegrees * RAD;
  const lat1 = from.latitude * RAD;
  const lon1 = from.longitude * RAD;
  const lat2 = Math.asin(Math.sin(lat1) * Math.cos(d) + Math.cos(lat1) * Math.sin(d) * Math.cos(b));
  const lon2 = lon1 + Math.atan2(Math.sin(b) * Math.sin(d) * Math.cos(lat1), Math.cos(d) - Math.sin(lat1) * Math.sin(lat2));
  return { latitude: lat2 / RAD, longitude: lon2 / RAD };
}

/**
 * The road as planned with a town stop: the direct road up to `from` (meters along it), a loop out through the town
 * (`bulge` m off the highway at the middle) and back onto the highway at `to`, then the direct road on. Returns the
 * coordinates, the town's place (the loop's far point) and the extra distance the loop adds over the direct road.
 */
export function townDetour(direct, { from, to, bulge, step = 100 }) {
  const coordinates = direct.coordinates.filter((_, i) => direct.cumulative[i] < from);
  let apex = null;
  for (let s = from; s <= to + 1e-6; s += step) {
    const base = direct.coordinateAtOffset(s);
    const heading = bearing(direct.coordinateAtOffset(Math.max(0, s - 20)), direct.coordinateAtOffset(s + 20));
    const lateral = bulge * Math.sin((Math.PI * (s - from)) / (to - from));
    const point = lateral > 1 ? destinationPoint(base, heading + 90, lateral) : base;
    coordinates.push(point);
    if (!apex || lateral > apex.lateral) apex = { ...point, lateral };
  }
  coordinates.push(direct.coordinateAtOffset(to));
  direct.coordinates.forEach((c, i) => { if (direct.cumulative[i] > to) coordinates.push(c); });
  const line = new RouteLine(coordinates);
  return { coordinates, town: { latitude: apex.latitude, longitude: apex.longitude }, extra: line.length - direct.length };
}

/** The stretch of `line` between two offsets, ends included. */
export function stretch(line, from, to) {
  const out = [line.coordinateAtOffset(from)];
  line.coordinates.forEach((c, i) => { if (line.cumulative[i] > from && line.cumulative[i] < to) out.push(c); });
  out.push(line.coordinateAtOffset(to));
  return out;
}

/** RouteRebuild.cutOffset: meters along `line` where the organizer is, on the right stretch when it passes a road twice. */
export function cutOffset(line, organizer, organizerOffset) {
  let hint = null;
  if (typeof organizerOffset === 'number') {
    const i = line.cumulative.reduce((last, c, k) => (c <= organizerOffset ? k : last), 0);
    hint = Math.min(i, Math.max(0, line.segmentCount - 1));
  }
  return line.project(organizer, { hint })?.offset ?? null;
}

/** RouteRebuild.ahead: the open stops the new route goes through: not the meeting point, beyond `cut`, by order. */
export const ahead = (stops, cut) => stops.filter((s) => isOpen(s) && s.kind !== 'meet' && s.routeOffset > cut).sort((a, b) => a.order - b.order);

/** StopRouting.join over coordinate lists: the line and the offset at each junction between the legs. */
export function join(legs) {
  const coordinates = [];
  const junctions = [];
  legs.forEach((leg, i) => {
    const points = leg.slice();
    if (coordinates.length && points.length && haversine(coordinates.at(-1), points[0]) <= JUNCTION_TOLERANCE) points.shift();
    coordinates.push(...points);
    if (i < legs.length - 1) junctions.push(Math.max(0, coordinates.length - 1));
  });
  const line = new RouteLine(coordinates);
  return { coordinates, line, stopOffsets: junctions.map((j) => line.cumulative[Math.min(j, line.cumulative.length - 1)]) };
}

/**
 * RouteRebuild.build. `organizer` is the organizer's fix, `organizerOffset` its last convoyOffset (the route it was
 * published against, `oldLine`). Returns the new route as the batch writes it: `route` (the polyline), `routeSeconds`,
 * `offsets` (stop id -> new routeOffset, for the stops ahead not yet reached) and the `cut`.
 */
export function rebuildRoute({ oldLine, directLine, stops, organizer, organizerOffset, destination }) {
  const cut = cutOffset(oldLine, organizer, organizerOffset);
  if (cut === null) throw new Error('no route');
  const prefix = truncate(oldLine, cut);
  const via = ahead(stops, cut);
  const points = [prefix.at(-1), ...via.map((s) => s.coordinate), destination];
  const legs = [];
  for (let i = 0; i < points.length - 1; i++) {
    const a = directLine.project(points[i]).offset;
    const b = directLine.project(points[i + 1]).offset;
    legs.push(stretch(directLine, a, b));
  }
  const joined = join([prefix, ...legs]);
  const offsets = {};
  via.forEach((stop, i) => { if (!stop.arrivedAt && stop.id) offsets[stop.id] = joined.stopOffsets[i + 1]; });
  // Maps' travel time stands in as the length at 27 m/s (the drive's cruising speed).
  return { cut, route: Polyline.encode(joined.coordinates), routeSeconds: joined.line.length / 27, offsets, line: joined.line, via };
}

/** A track along `line` from `startOffset` at `speed` m/s (0: parked there), 1 Hz, as readGpx gives it: [{latitude, longitude, t}]. */
export function syntheticTrack(line, { startOffset, speed, seconds }) {
  return Array.from({ length: seconds + 1 }, (_, t) => ({ ...line.coordinateAtOffset(Math.min(line.length, startOffset + speed * t)), t }));
}

/**
 * Position writes of a car after the rebuild that still read past `stopOffset` by more than `radius` (the old line's
 * offset for a stop that moved up): [{T, convoyOffset}] -> how many. One is the known transient.
 */
export const staleReads = (writes, { from, stopOffset, radius = 150 }) => writes.filter((w) => w.T >= from && w.convoyOffset > stopOffset + radius).length;

/** The values a stop's offset took, in order, repeats dropped: [old, new] after a rebuild that moved it once. */
export function distinctValues(snapshots) {
  const out = [];
  for (const v of snapshots) if (out.at(-1) !== v) out.push(v);
  return out;
}
