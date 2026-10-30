import type { Trip } from "./model.js";

// Pure parts of the trip summary, with no runtime imports so the unit tests can load this file directly.

/** Same sphere as ios/ikut/Route/RouteGeometry.swift `RouteLine.earthRadius`. */
const EARTH_RADIUS = 6_371_008.8;

/**
 * Strict polyline decode (precision 5), like ios/ikut/Model/Polyline.swift `decode`: a truncated or malformed string
 * gives `null` (Swift: an empty list), never a partial route, so the two sides agree on what has a distance.
 */
export function decodeStrict(encoded: string): { lat: number; lng: number }[] | null {
  const out: { lat: number; lng: number }[] = [];
  let i = 0;
  let lat = 0;
  let lng = 0;
  const next = (): number | null => {
    let result = 0;
    let shift = 0;
    while (i < encoded.length) {
      const b = encoded.charCodeAt(i++) - 63;
      // 5 bits a character; past 30 bits the 32-bit math below would overflow, and no real coordinate step needs it.
      if (b < 0 || shift >= 30) return null;
      result |= (b & 0x1f) << shift;
      shift += 5;
      if (b < 0x20) return result & 1 ? ~(result >> 1) : result >> 1;
    }
    return null;
  };
  while (i < encoded.length) {
    const dLat = next();
    const dLng = next();
    if (dLat === null || dLng === null) return null;
    lat += dLat;
    lng += dLng;
    out.push({ lat: lat / 1e5, lng: lng / 1e5 });
  }
  return out;
}

function wrapLongitude(d: number): number {
  if (d > 180) return d - 360;
  if (d < -180) return d + 360;
  return d;
}

/** Great-circle meters; mirrors `RouteLine.haversine`. */
function haversine(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const lat1 = (a.lat * Math.PI) / 180;
  const lat2 = (b.lat * Math.PI) / 180;
  const dLat = lat2 - lat1;
  const dLon = (wrapLongitude(b.lng - a.lng) * Math.PI) / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Mirrors `RecapLogic.routeDistance`: meters along the route, `null` for fewer than two points or a malformed string. */
export function routeDistanceMeters(encoded: string): number | null {
  const pts = decodeStrict(encoded);
  if (!pts || pts.length < 2) return null;
  let sum = 0;
  for (let i = 0; i < pts.length - 1; i++) sum += haversine(pts[i]!, pts[i + 1]!);
  return sum;
}

/**
 * Seconds the trip was underway: `startedAt` (the first Start Trip) to `endedAt`, or `createdAt` when it never
 * started. When `lastActivityMs` (newest position, event, lastActivityAt or startedAt) is `idleMs` (endIdleTrips' IDLE_MS) or more before
 * `endedAt`, it ends there instead. Like `RecapLogic.duration`, `null` unless the end is after the start. (The live recap counts from
 * `createdAt`, which for a trip planned the day before includes the waiting.)
 */
export function summaryDurationSeconds(
  trip: Pick<Trip, "createdAt" | "startedAt" | "endedAt">,
  lastActivityMs?: number | null,
  idleMs: number = Infinity,
): number | null {
  const start = trip.startedAt ?? trip.createdAt;
  if (!start || !trip.endedAt) return null;
  // A trip ended for being idle has endedAt at least `idleMs` after its last sign of life: the drive ended there.
  let end = trip.endedAt.toMillis();
  if (lastActivityMs != null && end - lastActivityMs >= idleMs) end = lastActivityMs;
  const seconds = (end - start.toMillis()) / 1000;
  return seconds > 0 ? seconds : null;
}

