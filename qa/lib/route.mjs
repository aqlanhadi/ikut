// Route geometry, ported line for line from the app so the simulator computes the same offsets.
//
//   Polyline        <- ios/ikut/Model/Polyline.swift          (Google encoded polyline, precision 5)
//   RouteLine       <- ios/ikut/Route/RouteGeometry.swift     (haversine, project, coordinate(atOffset:), mergeOffset, meetingMerge)
//   RouteSimplifier <- ios/ikut/CarRoute/CarRouteLogic.swift  (Douglas-Peucker, maxEncodedLength variant)
//   makeCarRoutePlan, truncate, planIfOnMain <- ios/ikut/CarRoute/CarRouteLogic.swift (CarRouteLogic)
//
// Coordinates are {latitude, longitude} objects, as CLLocationCoordinate2D.

export const EARTH_RADIUS = 6_371_008.8;
const RAD = Math.PI / 180;

// ---------------------------------------------------------------- Polyline

export const Polyline = {
  scale: 1e5,

  encode(coords) {
    let out = '';
    let lastLat = 0;
    let lastLng = 0;
    for (const c of coords) {
      // Swift's .rounded() is schoolbook (half away from zero); Math.round rounds half up. Match Swift.
      const lat = roundHalfAway(c.latitude * this.scale);
      const lng = roundHalfAway(c.longitude * this.scale);
      out += encodeValue(lat - lastLat);
      out += encodeValue(lng - lastLng);
      lastLat = lat;
      lastLng = lng;
    }
    return out;
  },

  /** Empty array for malformed input, as the app. */
  decode(str) {
    const bytes = Buffer.from(str, 'utf8');
    let index = 0;
    let lat = 0;
    let lng = 0;
    const out = [];
    const read = () => {
      let result = 0;
      let shift = 0;
      while (index < bytes.length) {
        const b = bytes[index++] - 63;
        if (b < 0 || shift >= 30) return null;
        result += (b & 0x1f) * 2 ** shift;
        shift += 5;
        if (b < 0x20) return result % 2 === 1 ? -(Math.floor(result / 2) + 1) : Math.floor(result / 2);
      }
      return null;
    };
    while (index < bytes.length) {
      const dLat = read();
      const dLng = dLat === null ? null : read();
      if (dLat === null || dLng === null) return [];
      lat += dLat;
      lng += dLng;
      out.push({ latitude: lat / this.scale, longitude: lng / this.scale });
    }
    return out;
  },
};

function roundHalfAway(x) {
  return x < 0 ? -Math.round(-x) : Math.round(x);
}

function encodeValue(value) {
  let v = value < 0 ? ~(value << 1) : value << 1;
  let s = '';
  while (v >= 0x20) {
    s += String.fromCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  return s + String.fromCharCode(v + 63);
}

// ---------------------------------------------------------------- RouteLine

function wrapLongitude(d) {
  if (d > 180) return d - 360;
  if (d < -180) return d + 360;
  return d;
}

export function haversine(a, b) {
  const lat1 = a.latitude * RAD;
  const lat2 = b.latitude * RAD;
  const dLat = lat2 - lat1;
  const dLon = wrapLongitude(b.longitude - a.longitude) * RAD;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Initial bearing a -> b, degrees clockwise from north, 0..<360. */
export function bearing(a, b) {
  const lat1 = a.latitude * RAD;
  const lat2 = b.latitude * RAD;
  const dLon = wrapLongitude(b.longitude - a.longitude) * RAD;
  const y = Math.sin(dLon) * Math.cos(lat2);
  const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLon);
  return (Math.atan2(y, x) / RAD + 360) % 360;
}

const TIE_DISTANCE = 5;

export class RouteLine {
  constructor(coordinates) {
    this.coordinates = coordinates;
    this.cumulative = [];
    this.segLength = [];
    this.cosLat = [];
    this.bx = [];
    this.by = [];
    if (coordinates.length > 0) {
      this.cumulative.push(0);
      for (let i = 0; i < coordinates.length - 1; i++) {
        const a = coordinates[i];
        const b = coordinates[i + 1];
        const len = haversine(a, b);
        this.segLength.push(len);
        this.cumulative.push(this.cumulative[i] + len);
        const c = Math.cos(((a.latitude + b.latitude) / 2) * RAD);
        this.cosLat.push(c);
        this.bx.push(wrapLongitude(b.longitude - a.longitude) * RAD * c * EARTH_RADIUS);
        this.by.push((b.latitude - a.latitude) * RAD * EARTH_RADIUS);
      }
    }
  }

  get length() { return this.cumulative.length ? this.cumulative[this.cumulative.length - 1] : 0; }
  get isEmpty() { return this.coordinates.length === 0; }
  get segmentCount() { return Math.max(0, this.coordinates.length - 1); }

  #evaluate(p, i) {
    const a = this.coordinates[i];
    const c = this.cosLat[i];
    const px = wrapLongitude(p.longitude - a.longitude) * RAD * c * EARTH_RADIUS;
    const py = (p.latitude - a.latitude) * RAD * EARTH_RADIUS;
    const len2 = this.bx[i] ** 2 + this.by[i] ** 2;
    const raw = len2 > 0 ? (px * this.bx[i] + py * this.by[i]) / len2 : 0;
    const t = Math.min(1, Math.max(0, raw));
    const dx = px - t * this.bx[i];
    const dy = py - t * this.by[i];
    return { distance: Math.hypot(dx, dy), segment: i, rawT: raw, t };
  }

  #best(p, lo, hi, hint) {
    let minD = Infinity;
    let chosen = null;
    for (let i = lo; i <= hi; i++) {
      const c = this.#evaluate(p, i);
      minD = Math.min(minD, c.distance);
      if (!(c.distance <= minD + TIE_DISTANCE)) continue;
      if (chosen === null || !(chosen.distance <= minD + TIE_DISTANCE)) { chosen = c; continue; }
      if (hint !== null && hint !== undefined) {
        if (Math.abs(c.segment - hint) < Math.abs(chosen.segment - hint)) chosen = c;
      } else if (c.distance < chosen.distance) {
        chosen = c;
      }
    }
    return chosen;
  }

  /** RouteLine.project: {offset, distance, segmentIndex, coordinate, clamp} or null for an empty route. */
  project(point, { hint = null, window = 24, fallbackDistance = 100 } = {}) {
    if (this.coordinates.length === 0) return null;
    if (this.segmentCount === 0) {
      return { offset: 0, distance: haversine(this.coordinates[0], point), segmentIndex: 0, coordinate: this.coordinates[0], clamp: 'none' };
    }
    const last = this.segmentCount - 1;
    let found;
    if (hint !== null && hint !== undefined) {
      const h = Math.min(Math.max(hint, 0), last);
      found = this.#best(point, Math.max(0, h - window), Math.min(last, h + window), h);
      if (found.distance > fallbackDistance) found = this.#best(point, 0, last, h);
    } else {
      found = this.#best(point, 0, last, null);
    }
    const a = this.coordinates[found.segment];
    const b = this.coordinates[found.segment + 1];
    const snapped = {
      latitude: a.latitude + found.t * (b.latitude - a.latitude),
      longitude: a.longitude + found.t * wrapLongitude(b.longitude - a.longitude),
    };
    let clamp = 'none';
    if (found.segment === 0 && found.rawT <= 0) clamp = 'beforeStart';
    if (found.segment === this.segmentCount - 1 && found.rawT >= 1) clamp = 'afterEnd';
    return {
      offset: this.cumulative[found.segment] + found.t * this.segLength[found.segment],
      distance: found.distance, segmentIndex: found.segment, coordinate: snapped, clamp,
    };
  }

  coordinateAtOffset(offset) {
    if (this.coordinates.length === 0) return null;
    if (this.segmentCount === 0 || offset <= 0) return this.coordinates[0];
    if (offset >= this.length) return this.coordinates[this.coordinates.length - 1];
    let lo = 0;
    let hi = this.coordinates.length - 1;
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (this.cumulative[mid] <= offset) lo = mid; else hi = mid;
    }
    const len = this.segLength[lo];
    const t = len > 0 ? (offset - this.cumulative[lo]) / len : 0;
    const a = this.coordinates[lo];
    const b = this.coordinates[lo + 1];
    return {
      latitude: a.latitude + t * (b.latitude - a.latitude),
      longitude: a.longitude + t * wrapLongitude(b.longitude - a.longitude),
    };
  }

  /**
   * RouteLine.meetingMerge(of:tolerance:): where a car's road to a meeting point joins this route: the very end of
   * `other`, when it ends at this route's start. Ignores an earlier stretch within tolerance (the other carriageway on
   * the way in). {otherOffset, mainOffset} or null.
   */
  meetingMerge(other, tolerance = 50) {
    if (this.isEmpty || other.coordinates.length === 0) return null;
    const start = this.coordinates[0];
    const end = other.coordinates[other.coordinates.length - 1];
    if (haversine(start, end) > tolerance) return null;
    return { otherOffset: other.length, mainOffset: 0 };
  }

  /** RouteLine.mergeOffset(of:tolerance:): {otherOffset, mainOffset} or null. */
  mergeOffset(other, tolerance = 50) {
    if (this.isEmpty || other.coordinates.length === 0) return null;
    const end = other.coordinates[other.coordinates.length - 1];
    let onProjection = this.project(end);
    if (!onProjection || onProjection.distance > tolerance) return null;
    let onOffset = other.length;
    const step = 25;
    let hint = onProjection.segmentIndex;
    let offOffset = null;
    let s = other.length - step;
    while (s > 0) {
      const c = other.coordinateAtOffset(s);
      const p = c && this.project(c, { hint, fallbackDistance: tolerance * 2 });
      if (!p) return null;
      if (p.distance > tolerance) { offOffset = s; break; }
      onOffset = s;
      onProjection = p;
      hint = p.segmentIndex;
      s -= step;
    }
    if (offOffset === null) {
      const p = this.project(other.coordinates[0], { hint, fallbackDistance: tolerance * 2 });
      return { otherOffset: 0, mainOffset: p ? p.offset : onProjection.offset };
    }
    let off = offOffset;
    while (onOffset - off > 1) {
      const mid = (onOffset + off) / 2;
      const c = other.coordinateAtOffset(mid);
      const p = c && this.project(c, { hint, fallbackDistance: tolerance * 2 });
      if (!p) break;
      if (p.distance > tolerance) {
        off = mid;
      } else {
        onOffset = mid;
        onProjection = p;
        hint = p.segmentIndex;
      }
    }
    return { otherOffset: onOffset, mainOffset: onProjection.offset };
  }
}

// ---------------------------------------------------------------- Car route plan (CarRouteLogic)

export const CarRouteLogic = {
  nearMainThreshold: 150,
  mergeTolerance: 50,
  tailPastMerge: 500,
  maxEncodedLength: 100_000,

  /** CarRouteLogic.planIfOnMain: a plan for a car near the main route, else null. */
  planIfOnMain(location, main) {
    const p = main.project(location);
    if (!p || p.distance > this.nearMainThreshold) return null;
    return { route: null, mergeOffset: p.offset, state: 'convoy', kind: 'onMainRoute' };
  },

  /**
   * CarRouteLogic.makePlan: cut a computed route at the merge, store it, and recompute the merge on the stored polyline.
   * `toMeetingPoint`: the road ends at the main route's start, so it joins only on arrival and is kept whole.
   */
  makePlan(computed, main, toMeetingPoint = false) {
    if (computed.length < 2 || main.isEmpty) return null;
    const full = new RouteLine(computed);
    if (toMeetingPoint) {
      const meet = main.meetingMerge(full, this.mergeTolerance);
      if (meet) {
        const simplified = simplifyToFit(computed, this.maxEncodedLength);
        return { route: Polyline.encode(simplified), mergeOffset: meet.mainOffset, state: 'joining', kind: 'merges' };
      }
    }
    const merge = main.mergeOffset(full, this.mergeTolerance);
    if (!merge) {
      const simplified = simplifyToFit(computed, this.maxEncodedLength);
      const proj = main.project(computed[computed.length - 1]);
      return { route: Polyline.encode(simplified), mergeOffset: proj ? proj.offset : main.length, state: 'joining', kind: 'neverMerges' };
    }
    const cut = truncate(full, merge.otherOffset + this.tailPastMerge);
    const simplified = simplifyToFit(cut, this.maxEncodedLength);
    const encoded = Polyline.encode(simplified);
    const stored = new RouteLine(Polyline.decode(encoded));
    const again = main.mergeOffset(stored, this.mergeTolerance);
    return { route: encoded, mergeOffset: again ? again.mainOffset : merge.mainOffset, state: 'joining', kind: 'merges' };
  },
};

export function truncate(line, offset) {
  if (!(offset < line.length)) return line.coordinates;
  const end = line.coordinateAtOffset(offset);
  const out = [];
  line.coordinates.forEach((c, i) => { if (line.cumulative[i] < offset) out.push(c); });
  out.push(end);
  return out;
}

// ---------------------------------------------------------------- Simplifier

function simplifyTolerance(points, tolerance) {
  if (points.length <= 2 || !(tolerance > 0)) return points;
  const lat0 = points[0].latitude;
  const c = Math.cos(lat0 * RAD);
  const xy = points.map((p) => [wrapLongitude(p.longitude - points[0].longitude) * RAD * c * EARTH_RADIUS, (p.latitude - lat0) * RAD * EARTH_RADIUS]);
  const keep = new Array(points.length).fill(false);
  keep[0] = true;
  keep[points.length - 1] = true;
  const stack = [[0, points.length - 1]];
  while (stack.length) {
    const [lo, hi] = stack.pop();
    if (hi - lo <= 1) continue;
    let maxD = 0;
    let index = lo;
    for (let i = lo + 1; i < hi; i++) {
      const d = segmentDistance(xy[i], xy[lo], xy[hi]);
      if (d > maxD) { maxD = d; index = i; }
    }
    if (maxD > tolerance) {
      keep[index] = true;
      stack.push([lo, index], [index, hi]);
    }
  }
  return points.filter((_, i) => keep[i]);
}

/** RouteSimplifier.simplify(_:maxEncodedLength:): untouched when it already fits. */
export function simplifyToFit(points, maxEncodedLength) {
  let result = points;
  let tolerance = 5;
  while (Polyline.encode(result).length > maxEncodedLength && result.length > 2 && tolerance < 1e6) {
    result = simplifyTolerance(points, tolerance);
    tolerance *= 2;
  }
  return result;
}

function segmentDistance(p, a, b) {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  const t = len2 > 0 ? Math.min(1, Math.max(0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2)) : 0;
  return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}
