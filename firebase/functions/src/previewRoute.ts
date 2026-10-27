/** Polyline (precision 5) helpers for previewTrip: shrink the trip's main route to what a phone screen draws. */

export interface LatLng {
  latitude: number;
  longitude: number;
}

export function decodePolyline(encoded: string): LatLng[] {
  const out: LatLng[] = [];
  let i = 0;
  let lat = 0;
  let lng = 0;
  const next = (): number | undefined => {
    let result = 0;
    let shift = 0;
    let b: number;
    do {
      if (i >= encoded.length) return undefined;
      b = encoded.charCodeAt(i++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };
  while (i < encoded.length) {
    const dLat = next();
    const dLng = next();
    if (dLat === undefined || dLng === undefined) break;
    lat += dLat;
    lng += dLng;
    out.push({ latitude: lat / 1e5, longitude: lng / 1e5 });
  }
  return out;
}

export function encodePolyline(points: LatLng[]): string {
  let out = "";
  let pLat = 0;
  let pLng = 0;
  const put = (v: number) => {
    let n = v < 0 ? ~(v << 1) : v << 1;
    while (n >= 0x20) {
      out += String.fromCharCode((0x20 | (n & 0x1f)) + 63);
      n >>= 5;
    }
    out += String.fromCharCode(n + 63);
  };
  for (const p of points) {
    const lat = Math.round(p.latitude * 1e5);
    const lng = Math.round(p.longitude * 1e5);
    put(lat - pLat);
    put(lng - pLng);
    pLat = lat;
    pLng = lng;
  }
  return out;
}

/** Meters from p to segment a-b on a local flat projection (fine at the scale of a drive). */
function distanceToSegment(p: LatLng, a: LatLng, b: LatLng): number {
  const k = 111_320;
  const cos = Math.cos((a.latitude * Math.PI) / 180);
  const px = (p.longitude - a.longitude) * cos * k;
  const py = (p.latitude - a.latitude) * k;
  const bx = (b.longitude - a.longitude) * cos * k;
  const by = (b.latitude - a.latitude) * k;
  const len2 = bx * bx + by * by;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, (px * bx + py * by) / len2));
  return Math.hypot(px - t * bx, py - t * by);
}

/** Douglas-Peucker, iterative so a long route can't overflow the stack. Keeps the first and last point. */
export function simplify(points: LatLng[], toleranceMeters: number): LatLng[] {
  if (points.length <= 2) return points;
  const keep = new Array<boolean>(points.length).fill(false);
  keep[0] = keep[points.length - 1] = true;
  const stack: Array<[number, number]> = [[0, points.length - 1]];
  while (stack.length > 0) {
    const [s, e] = stack.pop()!;
    let worst = 0;
    let at = -1;
    for (let i = s + 1; i < e; i++) {
      const d = distanceToSegment(points[i], points[s], points[e]);
      if (d > worst) {
        worst = d;
        at = i;
      }
    }
    if (at >= 0 && worst > toleranceMeters) {
      keep[at] = true;
      stack.push([s, at], [at, e]);
    }
  }
  return points.filter((_, i) => keep[i]);
}

function metersBetween(a: LatLng, b: LatLng): number {
  const k = 111_320;
  const cos = Math.cos((((a.latitude + b.latitude) / 2) * Math.PI) / 180);
  return Math.hypot((b.longitude - a.longitude) * cos * k, (b.latitude - a.latitude) * k);
}

export const ROUTE_LEAD_CUT_METERS = 3_000;
export const ROUTE_MIN_METERS = 6_000;

/**
 * The route from `startMeters` along it onward, beginning exactly at `first` (default: the point at that distance).
 * Empty when the line is shorter than `minTotalMeters` or the cut leaves nothing.
 */
export function routeFrom(points: LatLng[], startMeters: number, first?: LatLng, minTotalMeters = 0): LatLng[] {
  const cum = [0];
  for (let i = 1; i < points.length; i++) cum.push(cum[i - 1] + metersBetween(points[i - 1], points[i]));
  const total = cum[cum.length - 1] ?? 0;
  if (points.length < 2 || total < minTotalMeters || startMeters >= total) return [];
  let i = 1;
  while (i < points.length && cum[i] <= startMeters) i++;
  const a = points[i - 1];
  const b = points[i];
  const seg = cum[i] - cum[i - 1];
  const t = seg === 0 ? 0 : (startMeters - cum[i - 1]) / seg;
  const at = first ?? { latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t };
  return [at, ...points.slice(i)];
}

/** The main route as a precision-5 polyline of at most `maxPoints` points, widening the tolerance until it fits; "" when unreadable. */
export function simplifiedRoute(
  encoded: unknown,
  opts: { toleranceMeters?: number; maxPoints?: number; meet?: { routeOffset: number; coordinate?: LatLng } } = {},
): string {
  const { toleranceMeters = 100, maxPoints = 400, meet } = opts;
  if (typeof encoded !== "string" || encoded.length === 0) return "";
  let points = decodePolyline(encoded);
  if (points.length < 2) return "";
  // The line never starts at anyone's own start: at the meeting point, or 3 km in; under 6 km there is no line.
  points = meet
    ? routeFrom(points, Math.max(0, meet.routeOffset), meet.coordinate, ROUTE_MIN_METERS)
    : routeFrom(points, ROUTE_LEAD_CUT_METERS, undefined, ROUTE_MIN_METERS);
  if (points.length < 2) return "";
  let tol = toleranceMeters;
  points = simplify(points, tol);
  while (points.length > maxPoints && tol < 20_000) {
    tol *= 2;
    points = simplify(points, tol);
  }
  return encodePolyline(points);
}
