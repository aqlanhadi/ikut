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

/** The main route as a precision-5 polyline of at most `maxPoints` points, widening the tolerance until it fits; "" when unreadable. */
export function simplifiedRoute(encoded: unknown, toleranceMeters = 100, maxPoints = 400): string {
  if (typeof encoded !== "string" || encoded.length === 0) return "";
  let points = decodePolyline(encoded);
  if (points.length < 2) return "";
  let tol = toleranceMeters;
  points = simplify(points, tol);
  while (points.length > maxPoints && tol < 20_000) {
    tol *= 2;
    points = simplify(points, tol);
  }
  return encodePolyline(points);
}
