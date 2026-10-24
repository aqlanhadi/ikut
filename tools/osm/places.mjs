// D4 spike: stop places from OpenStreetMap, as pure functions (no network, no files), so the Swift port has a
// tested reference. Coordinates are {latitude, longitude}; offsets are meters along the trip's main route,
// measured with the app's RouteLine (qa/lib/route.mjs is its line-for-line port), so a place's offset here is the
// `routeOffset` a planned stop gets in the app.
//
//   toPlaces(elements)               OSM elements (Overpass JSON or an extract in the same shape) -> places
//   roadIndex(elements)              slip roads (motorway_link, service) as a graph, and the motorway carriageways
//   slipRoads(place, roads)          where traffic turns off the motorway to a place and rejoins it, with the gate
//   carriageway(slips, line)         'ours' | 'opposite' | null, from the slip roads
//   sideOf(point, line)              left or right of the route line (Malaysia drives on the left)
//   along(places, line, ...)         places within reach of the route, with offset, side, carriageway, entrance
//   suggestStops(candidates, trip)   "Suggest stops": an R&R on our side about every 2 hours
//   rankForRequest(candidates, ask)  a stop request on the road: 3 places at most, each with where and why

import { haversine, bearing, RouteLine } from '../../qa/lib/route.mjs';

const RAD = Math.PI / 180;
const EARTH = 6_371_008.8;

// ---------------------------------------------------------------- small geometry

/** Local flat x/y in meters around `origin` (good to a few cm over a few km). */
export function xy(p, origin) {
  return {
    x: (p.longitude - origin.longitude) * RAD * EARTH * Math.cos(origin.latitude * RAD),
    y: (p.latitude - origin.latitude) * RAD * EARTH,
  };
}

/** Smallest difference between two bearings, 0...180. */
export function angleBetween(a, b) {
  const d = Math.abs(((a - b) % 360 + 360) % 360);
  return d > 180 ? 360 - d : d;
}

export function pointInRing(p, ring) {
  if (!ring || ring.length < 4) return false;
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[i], b = ring[j];
    if ((a.latitude > p.latitude) !== (b.latitude > p.latitude)
      && p.longitude < (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude) {
      inside = !inside;
    }
  }
  return inside;
}

/** Meters from `p` to the ring's edge (0 inside). */
export function distanceToRing(p, ring) {
  if (pointInRing(p, ring)) return 0;
  let best = Infinity;
  for (let i = 0; i < ring.length - 1; i++) {
    const a = xy(ring[i], p), b = xy(ring[i + 1], p);
    const dx = b.x - a.x, dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    const t = len2 > 0 ? Math.min(1, Math.max(0, -(a.x * dx + a.y * dy) / len2)) : 0;
    best = Math.min(best, Math.hypot(a.x + t * dx, a.y + t * dy));
  }
  return best;
}

function centroid(points) {
  const pts = points.length > 1 && key(points[0]) === key(points[points.length - 1]) ? points.slice(0, -1) : points;
  return {
    latitude: pts.reduce((s, p) => s + p.latitude, 0) / pts.length,
    longitude: pts.reduce((s, p) => s + p.longitude, 0) / pts.length,
  };
}

/** Same OSM node, same coordinate: ways that share a node join at an identical point. */
export const key = (p) => `${p.latitude.toFixed(7)},${p.longitude.toFixed(7)}`;
const geo = (g) => ({ latitude: g.lat, longitude: g.lon });

// ---------------------------------------------------------------- places

const NAME_KEYS = ['name:en', 'name', 'short_name', 'alt_name'];
const nameOf = (tags) => NAME_KEYS.map((k) => tags[k]).find(Boolean) ?? null;

/** Where an element is and its outline (closed ways only). */
function shape(e) {
  if (e.type === 'node') return { coordinate: { latitude: e.lat, longitude: e.lon }, ring: null };
  if (e.geometry?.length) {
    const pts = e.geometry.map(geo);
    const closed = pts.length >= 4 && key(pts[0]) === key(pts[pts.length - 1]);
    return { coordinate: centroid(pts), ring: closed ? pts : null };
  }
  if (e.bounds) {
    // A multipolygon fetched with `out tags` has only its bounds: use the box as its outline (an extract built
    // with osmium has the real one).
    const b = e.bounds;
    const box = [[b.minlat, b.minlon], [b.minlat, b.maxlon], [b.maxlat, b.maxlon], [b.maxlat, b.minlon], [b.minlat, b.minlon]]
      .map(([latitude, longitude]) => ({ latitude, longitude }));
    return { coordinate: { latitude: (b.minlat + b.maxlat) / 2, longitude: (b.minlon + b.maxlon) / 2 }, ring: box };
  }
  return null;
}

/** A point thing (fuel, toilets, charger) belongs to a place when it is inside its outline, or within
 * `NEAR` of a place mapped as a single point. */
export const NEAR = 200;

/**
 * Services (`highway=services`: fuel, food, toilets, parking by the OSM wiki's definition), rest areas
 * (`highway=rest_area`: parking and maybe toilets, no fuel) and lone fuel stations, with what each has.
 * Facilities come from the place's own tags and the fuel/toilets/charging points mapped inside it.
 */
export function toPlaces(elements) {
  const sites = [];
  const amenities = [];
  for (const e of elements) {
    const t = e.tags ?? {};
    const s = shape(e);
    if (!s) continue;
    const id = `${e.type}/${e.id}`;
    if (t.highway === 'services' || t.highway === 'rest_area') {
      sites.push({ id, kind: t.highway, name: nameOf(t), tags: t, ...s });
    } else if (['fuel', 'toilets', 'charging_station'].includes(t.amenity)) {
      amenities.push({ id, amenity: t.amenity, brand: t.brand ?? t.name ?? null, ...s });
    }
  }
  const belongs = (a, site) => (site.ring ? distanceToRing(a.coordinate, site.ring) <= 30 : haversine(a.coordinate, site.coordinate) <= NEAR);
  const used = new Set();
  const places = sites.map((site) => {
    const inside = amenities.filter((a) => belongs(a, site));
    inside.forEach((a) => used.add(a.id));
    const t = site.tags;
    const fuelHere = inside.filter((a) => a.amenity === 'fuel');
    const facilities = {
      fuel: fuelHere.length > 0 || t.amenity === 'fuel' || t.fuel === 'yes',
      toilets: inside.some((a) => a.amenity === 'toilets') || t.toilets === 'yes' || t.toilet === 'yes',
      // OSM's services tag means food is there; a rest area is only parking (wiki). Not checked against shops.
      food: site.kind === 'services',
      ev: inside.some((a) => a.amenity === 'charging_station'),
    };
    const brands = [...new Set(fuelHere.map((a) => a.brand).filter(Boolean).concat(t.amenity === 'fuel' && t.brand ? [t.brand] : []))];
    return { id: site.id, kind: site.kind, name: site.name, coordinate: site.coordinate, ring: site.ring, facilities, brands };
  });
  // Fuel stations that are not part of a services area: a town petrol station, or a pump mapped on its own.
  for (const a of amenities) {
    if (a.amenity !== 'fuel' || used.has(a.id)) continue;
    places.push({
      id: a.id, kind: 'fuel', name: a.brand, coordinate: a.coordinate, ring: null,
      facilities: { fuel: true, toilets: false, food: false, ev: false }, brands: a.brand ? [a.brand] : [],
    });
  }
  return places;
}

// ---------------------------------------------------------------- roads

/** One-way-ness as OSM tags it: motorways and slip roads are one-way unless tagged otherwise, service roads two-way. */
function direction(t) {
  if (t.oneway === '-1') return -1;
  if (t.oneway === 'no') return 0;
  if (t.oneway === 'yes') return 1;
  return t.highway === 'motorway' || t.highway === 'motorway_link' ? 1 : 0;
}

/** The roads that lead into an R&R. Malaysian R&Rs have their slip roads mapped as `motorway_link` at some sites
 * and as one-way `service` roads at most others, so both count. */
const ACCESS = new Set(['motorway_link', 'service']);

/**
 * The access roads (`motorway_link`, `service`) as a graph of their points, and the motorway carriageways
 * (`motorway`) with their bearing at each point. Ways come from `out geom`, with no node ids, so they join where
 * they share a coordinate (an OSM node is the same coordinate in every way that uses it).
 */
export function roadIndex(elements) {
  const motorwayAt = new Map(); // key -> {bearing, ref, way}
  const points = new Map(); // key -> coordinate
  const next = new Map(); // key -> [{to, meters}] in the direction of travel (both ways on a two-way road)
  const prev = new Map(); // key -> [{to, meters}] the reverse
  const edge = (m, a, b, meters) => { if (!m.has(a)) m.set(a, []); m.get(a).push({ to: b, meters }); };
  for (const e of elements) {
    const hw = e.tags?.highway;
    if (hw !== 'motorway' && !ACCESS.has(hw)) continue;
    if (!e.geometry || e.geometry.length < 2) continue;
    let pts = e.geometry.map(geo);
    const dir = direction(e.tags);
    if (dir === -1) pts = pts.reverse();
    if (hw === 'motorway') {
      for (let i = 0; i < pts.length; i++) {
        const a = pts[Math.max(0, i - 1)], b = pts[Math.min(pts.length - 1, i + 1)];
        motorwayAt.set(key(pts[i]), { bearing: bearing(a, b), ref: e.tags.ref ?? null, way: `way/${e.id}`, point: pts[i] });
      }
      continue;
    }
    for (let i = 0; i < pts.length; i++) {
      points.set(key(pts[i]), pts[i]);
      if (i === 0) continue;
      const a = key(pts[i - 1]), b = key(pts[i]);
      const m = haversine(pts[i - 1], pts[i]);
      edge(next, a, b, m); edge(prev, b, a, m);
      if (dir === 0) { edge(next, b, a, m); edge(prev, a, b, m); }
    }
  }
  return { motorwayAt, points, next, prev };
}

/** A road point belongs to a place's gate when it lies inside the outline or within `TOUCH` meters of it
 * (`NEAR` of a place mapped as a single point). */
export const TOUCH = 40;
function touches(p, place) {
  return place.ring ? distanceToRing(p, place.ring) <= TOUCH : haversine(p, place.coordinate) <= NEAR;
}

/** Slip roads are short: a search stops this far (meters of road) from the place. */
export const MAX_SLIP = 2_500;

/** From every gate point, along `graph` (prev: where traffic comes from; next: where it goes), to the first
 * motorway point on each path. Returns [{junction, bearing, gate, meters}]. */
function search(gates, graph, roads) {
  const best = new Map(); // key -> {meters, gate}
  const queue = gates.map((g) => ({ k: g, meters: 0, gate: g }));
  for (const q of queue) best.set(q.k, q);
  const hits = new Map();
  while (queue.length) {
    queue.sort((a, b) => a.meters - b.meters);
    const cur = queue.shift();
    if (best.get(cur.k) !== cur) continue;
    const mw = roads.motorwayAt.get(cur.k);
    if (mw) {
      if (!hits.has(cur.k)) hits.set(cur.k, { junction: mw.point, bearing: mw.bearing, ref: mw.ref, gate: roads.points.get(cur.gate), meters: cur.meters });
      continue; // never drive along the motorway itself
    }
    for (const { to, meters } of graph.get(cur.k) ?? []) {
      const m = cur.meters + meters;
      if (m > MAX_SLIP) continue;
      const old = best.get(to);
      if (old && old.meters <= m) continue;
      const item = { k: to, meters: m, gate: cur.gate };
      best.set(to, item);
      queue.push(item);
    }
  }
  return [...hits.values()];
}

/**
 * How a place is reached from the motorway and left for it. `entries` are the motorway points where traffic turns
 * off toward the place (searching back along one-way roads from its gate), `exits` where it rejoins; each with the
 * carriageway's bearing there and the `gate`: the point where that road reaches the place (the point to route to,
 * so a leg ends on the slip road of our side, never on the far carriageway).
 */
export function slipRoads(place, roads) {
  const gates = [];
  for (const [k, p] of roads.points) if (touches(p, place)) gates.push(k);
  if (!gates.length) return { entries: [], exits: [] };
  return { entries: search(gates, roads.prev, roads), exits: search(gates, roads.next, roads) };
}

/** Within this of the route, a junction is on the route's own road (a dual carriageway is 20 to 60 m across). */
export const ON_ROAD = 120;
/** Bearings this close are the same direction of travel; this far apart, the other carriageway. */
const SAME = 60, OPPOSITE = 120;

/** Route bearing at `offset`, over 50 m either side. */
export function routeBearing(line, offset) {
  const a = line.coordinateAtOffset(Math.max(0, offset - 50));
  const b = line.coordinateAtOffset(Math.min(line.length, offset + 50));
  return bearing(a, b);
}

/** 'ours' or 'opposite' for one slip road junction, null when it is not on the route's road. */
function junctionSide(s, line) {
  const p = line.project(s.junction);
  if (!p || p.distance > ON_ROAD) return null;
  const d = angleBetween(s.bearing, routeBearing(line, p.offset));
  if (d <= SAME) return 'ours';
  if (d >= OPPOSITE) return 'opposite';
  return null;
}

/**
 * Which carriageway of the route a place serves, from its slip roads: the side of the nearest entry (the shortest
 * road from the motorway into the place), else of the nearest exit; null when no slip road reaches the route's road
 * (none mapped, or a place on another highway). Nearest, not every one: two-way service roads behind an R&R often
 * link both sides (a staff road under the highway), so a long path to the far carriageway is not a way in.
 */
export function carriageway(slips, line) {
  for (const list of [slips.entries, slips.exits]) {
    const sided = list.map((s) => ({ s, side: junctionSide(s, line) })).filter((x) => x.side).sort((a, b) => a.s.meters - b.s.meters);
    if (sided.length) return sided[0].side;
  }
  return null;
}

/** Left or right of the route at the place's nearest point, with the offset and distance. Driving on the left,
 * our side is the left. */
export function sideOf(point, line) {
  const p = line.project(point);
  if (!p) return null;
  const i = p.segmentIndex;
  const a = xy(line.coordinates[i], point), b = xy(line.coordinates[i + 1], point);
  // Cross product of the segment direction and the vector to the point (at the origin): positive = left.
  const cross = (b.x - a.x) * (0 - a.y) - (b.y - a.y) * (0 - a.x);
  return { offset: p.offset, distance: p.distance, side: cross > 0 ? 'left' : 'right' };
}

/** An outline with corners more than `SPAN` meters to each side of the route line spans the road. */
export const SPAN = 15;
export function straddles(ring, line) {
  let left = false, right = false;
  for (const p of ring) {
    const s = sideOf(p, line);
    if (!s || s.distance < SPAN || s.distance > REACH) continue;
    if (s.side === 'left') left = true; else right = true;
  }
  return left && right;
}

/** Malaysia drives on the left: services on our carriageway sit to the left of the route. */
export const OUR_SIDE = 'left';

/** How far off the route line a place is still considered (an R&R's far edge is 150 to 400 m from the road). */
export const REACH = 600;

/**
 * Places within `reach` of the route, in route order, each with its offset, side, carriageway from the slip
 * roads, the entrance to route to, and `ours`. The side of the line decides: on KL-Ipoh it is right for every
 * site PLUS lists, while the slip roads answer for few (most R&R slip roads are unmapped or untagged).
 */
export function along(places, line, roads, { reach = REACH } = {}) {
  const out = [];
  for (const place of places) {
    const s = sideOf(place.coordinate, line);
    if (!s || s.distance > reach) continue;
    // An overhead-bridge R&R (Sungai Buloh) spans the road and serves both directions: its outline reaches well
    // over both sides of the line.
    if (place.ring && straddles(place.ring, line)) s.side = 'both';
    const slips = roads ? slipRoads(place, roads) : { entries: [], exits: [] };
    const cw = carriageway(slips, line);
    // Our way in: an entry on our carriageway before the place (the diverge), the nearest one.
    const ourEntry = slips.entries
      .filter((e) => junctionSide(e, line) === 'ours')
      .map((e) => ({ e, at: line.project(e.junction).offset }))
      .filter(({ at }) => at <= s.offset + 200)
      .sort((a, b) => b.at - a.at)[0];
    // The side of the line decides; the slip roads are reported next to it (the spike measures how often they agree).
    const verdict = s.side === OUR_SIDE || s.side === 'both' ? 'ours' : 'opposite';
    out.push({
      ...place, offset: s.offset, distance: Math.round(s.distance), side: s.side, carriageway: cw,
      ours: verdict === 'ours',
      // Route here: the gate on our slip road when it is mapped, else the place itself (its own outline, on its
      // own side when each side is mapped apart).
      entrance: ourEntry?.e.gate ?? place.coordinate,
      slipEntrance: Boolean(ourEntry),
      // Where the stop sits on the route: where our slip road leaves it, else the place projected.
      routeOffset: ourEntry ? ourEntry.at : s.offset,
    });
  }
  return out.sort((a, b) => a.routeOffset - b.routeOffset);
}

// ---------------------------------------------------------------- suggest stops (planning)

/** Kinds of stop an R&R suggestion covers, in the app's `PlannedStopKind` words. */
export function stopKind(place) {
  if (place.facilities.fuel) return 'fuel';
  if (place.facilities.food) return 'food';
  if (place.facilities.toilets) return 'toilet';
  return 'rest';
}

/** OSM tags some lay-bys `services` (Tanjung Malim, Bikam: a pump and a stall); their names give them away.
 * "Hentian sebelah" is Malay for lay-by. */
const LAYBY = /lay-?by|hentian sebelah/i;

/** An R&R good enough to suggest on its own: services with fuel (and so food and toilets), not a lay-by or a
 * lone pump. */
export const isRnR = (p) => p.kind === 'services' && p.facilities.fuel && !LAYBY.test(p.name ?? '');

/**
 * "Suggest stops" in the lobby: about every `every` seconds of driving, the R&R on our carriageway nearest that
 * time, within `window` either side; none in the last `minFromEnd` of the trip (you are nearly there). A trip with
 * no such time but longer than `halfwayFrom` gets one stop near halfway instead, so KL to Ipoh (2 h 24 min) still
 * gets a break. Time along the route is `routeSeconds` spread evenly over its length, as the app's ETAs do.
 * Returns [{place, at (s), target (s), why}] in route order.
 */
export function suggestStops(candidates, {
  routeLength, routeSeconds, every = 7200, window = 1800, minFromEnd = 1800, halfwayFrom = 5400, existing = [],
}) {
  const time = (offset) => (offset / routeLength) * routeSeconds;
  const pool = candidates.filter((c) => c.ours && isRnR(c));
  const targets = [];
  for (let t = every; t <= routeSeconds - minFromEnd; t += every) targets.push({ target: t, window });
  // Too short for a break every 2 h, long enough to want one: one stop near halfway, anywhere in the middle half
  // of the trip (KL to Ipoh is 2 h 24 min, so its 2 h mark falls in the last half hour).
  if (!targets.length && routeSeconds >= halfwayFrom) targets.push({ target: routeSeconds / 2, window: routeSeconds / 4 });
  const picks = [];
  let last = 0;
  for (const { target, window } of targets) {
    // A stop the organizer already has near this time counts as the break.
    if (existing.some((o) => Math.abs(time(o) - target) <= window)) continue;
    const near = pool
      .map((c) => ({ c, at: time(c.routeOffset) }))
      .filter(({ at }) => Math.abs(at - target) <= window && at > last && at <= routeSeconds - minFromEnd)
      // Nearest the target; a tie (within 5 min) goes to the one with more for everyone (EV charging, then toilets).
      .sort((a, b) => {
        const d = Math.abs(a.at - target) - Math.abs(b.at - target);
        if (Math.abs(d) > 300) return d;
        return score(b.c) - score(a.c) || d;
      });
    if (!near.length) continue;
    const { c, at } = near[0];
    last = at;
    picks.push({ place: c, at, target, why: `${Math.round(at / 60)} min along · ${facilityWords(c)}` });
  }
  return picks;
}

const score = (c) => (c.facilities.ev ? 2 : 0) + (c.facilities.toilets ? 1 : 0);

export function facilityWords(p) {
  const f = p.facilities;
  return [f.fuel && 'fuel', f.food && 'food', f.toilets && 'toilets', f.ev && 'EV charging'].filter(Boolean).join(', ');
}

// ---------------------------------------------------------------- a stop request on the road

/** How soon each reason needs a stop, in seconds of driving from the front car. Toilet is urgent, food can wait. */
export const LAYBY_PENALTY = 15 * 60;
export const REASON_WINDOW = { toilet: 20 * 60, fuel: 40 * 60, rest: 45 * 60, food: 60 * 60 };
const NEEDS = { toilet: 'toilets', fuel: 'fuel', food: 'food', rest: null };

/**
 * Places for a stop request: ahead of the front car on our carriageway, reachable within the most urgent open
 * reason's window (or the asker's fuel range), covering every open reason, nearest first. At most 3, each with
 * one line of why. `speed` is m/s (the convoy's pace, or the route's average).
 */
export function rankForRequest(candidates, { frontOffset, reasons, speed, fuelRangeMeters = null, max = 3 }) {
  const limit = Math.min(...reasons.map((r) => (r === 'fuel' && fuelRangeMeters ? fuelRangeMeters / speed : REASON_WINDOW[r])));
  const covers = (c) => reasons.every((r) => !NEEDS[r] || c.facilities[NEEDS[r]]);
  const rows = candidates
    .filter((c) => c.ours && c.routeOffset > frontOffset + 500)
    .map((c) => ({ c, secs: (c.routeOffset - frontOffset) / speed }))
    .filter(({ secs }) => secs <= limit);
  // Covering every reason beats being nearer; then nearest, a lay-by counting `LAYBY_PENALTY` further than it is
  // (an R&R 10 min beyond a lay-by stall is the better stop).
  const cost = (r) => r.secs + (isRnR(r.c) ? 0 : LAYBY_PENALTY);
  rows.sort((a, b) => (covers(b.c) - covers(a.c)) || (cost(a) - cost(b)));
  return rows.slice(0, max).map(({ c, secs }) => ({
    place: c, minutes: Math.round(secs / 60),
    where: requestWhere(c.routeOffset - frontOffset, secs),
    why: requestWhy(c, reasons),
  }));
}

/** "18 km ahead · about 12 min", the RequestStop canvas's words for a place on the route ahead of the lead. */
export function requestWhere(meters, secs) {
  return `${Math.max(1, Math.round(meters / 1000))} km ahead · about ${Math.max(1, Math.round(secs / 60))} min`;
}

/** "toilets" or "toilets, no fuel": what the place has and lacks of what was asked for ("parking" for a rest). */
export function requestWhy(place, reasons) {
  const asked = [...new Set(reasons.map((r) => NEEDS[r]).filter(Boolean))];
  const has = asked.filter((n) => place.facilities[n]);
  const lacks = asked.filter((n) => !place.facilities[n]);
  return [has.join(', ') || (asked.length ? '' : 'parking'), lacks.length ? `no ${lacks.join(', ')}` : ''].filter(Boolean).join(', ');
}

export { RouteLine };
