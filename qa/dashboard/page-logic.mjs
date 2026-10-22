// The playground page's plain logic, kept out of index.html so `node --test` can reach it (qa/lib/page-logic.test.mjs).
// No DOM and no Google Maps in here. The page imports it as /page-logic.mjs (server.mjs serves that one file).

const R = 6371000;
const rad = (d) => (d * Math.PI) / 180;
const deg = (r) => (r * 180) / Math.PI;

/** Metres between two {lat,lng} points. */
export function distance(a, b) {
  const dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** A Google-encoded polyline (precision 5 by default) as [{lat, lng}]. */
export function decodePolyline(str, precision = 5) {
  const out = [], f = 10 ** precision;
  let i = 0, lat = 0, lng = 0;
  const next = () => {
    let shift = 0, result = 0, b;
    do { b = str.charCodeAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20 && i < str.length);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };
  while (i < str.length) { lat += next(); lng += next(); out.push({ lat: lat / f, lng: lng / f }); }
  return out;
}

/** A path with its running length: `cum[i]` is the metres from the first point to point i. */
export function measure(path) {
  const cum = [0];
  for (let i = 1; i < path.length; i++) cum.push(cum[i - 1] + distance(path[i - 1], path[i]));
  return { path, cum, length: cum[cum.length - 1] ?? 0 };
}

/** The point on the measured path nearest `p`: `{offset (m), point, distance (m), index}`. Local flat maths per segment (fine at road scale). */
export function snapToRoute(route, p) {
  let best = null;
  const k = Math.cos(rad(p.lat));
  for (let i = 0; i + 1 < route.path.length; i++) {
    const a = route.path[i], b = route.path[i + 1];
    const ax = (a.lng - p.lng) * k, ay = a.lat - p.lat, bx = (b.lng - p.lng) * k, by = b.lat - p.lat;
    const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
    const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len2));
    const point = { lat: a.lat + (b.lat - a.lat) * t, lng: a.lng + (b.lng - a.lng) * t };
    const d = distance(p, point);
    if (!best || d < best.distance) best = { distance: d, point, index: i, offset: route.cum[i] + (route.cum[i + 1] - route.cum[i]) * t };
  }
  return best ?? (route.path[0] ? { distance: distance(p, route.path[0]), point: route.path[0], index: 0, offset: 0 } : null);
}

/** The point `meters` along the path (clamped to its ends). */
export function pointAtOffset(route, meters) {
  const { path, cum, length } = route;
  if (!path.length) return null;
  const m = Math.max(0, Math.min(length, meters));
  let i = 1;
  while (i < path.length - 1 && cum[i] < m) i++;
  if (path.length === 1) return path[0];
  const span = cum[i] - cum[i - 1] || 1, t = (m - cum[i - 1]) / span;
  return { lat: path[i - 1].lat + (path[i].lat - path[i - 1].lat) * t, lng: path[i - 1].lng + (path[i].lng - path[i - 1].lng) * t };
}

/** A point `meters` to the left of the route at `km` (negative: right). Used to give a deviation a pin when there is no map to click. */
export function sidePoint(route, km, meters) {
  const a = pointAtOffset(route, km * 1000 - 20), b = pointAtOffset(route, km * 1000 + 20), at = pointAtOffset(route, km * 1000);
  if (!a || !b || !at) return null;
  const bearing = Math.atan2((b.lng - a.lng) * Math.cos(rad(at.lat)), b.lat - a.lat) - Math.PI / 2;
  const d = meters / R;
  return { lat: at.lat + deg(d * Math.cos(bearing)), lng: at.lng + deg((d * Math.sin(bearing)) / Math.cos(rad(at.lat))) };
}

/** At most `max` points, evenly thinned, always keeping the first and the last (the playground takes 2 to 20,000 points a road). */
export function limitPoints(points, max = 19000) {
  if (points.length <= max) return points;
  const out = [], step = (points.length - 1) / (max - 1);
  for (let i = 0; i < max; i++) out.push(points[Math.round(i * step)]);
  return out;
}

const r5 = (n) => n.toFixed(5);
/** The cache key of a road: its two ends, to about a metre. */
export const roadKey = (a, b) => `${r5(a.lat)},${r5(a.lng)}>${r5(b.lat)},${r5(b.lng)}`;

/** {lat,lng} to the playground's {latitude, longitude}, and back. */
export const toCoord = (p) => ({ latitude: p.lat, longitude: p.lng });
export const fromCoord = (c) => (c ? { lat: c.latitude, lng: c.longitude } : null);
const r6 = (n) => Math.round(n * 1e6) / 1e6;
const toRoad = (path) => (path && path.length >= 2 ? limitPoints(path).map((p) => ({ latitude: r6(p.lat), longitude: r6(p.lng) })) : undefined); // 6 decimals is about 10 cm

// ---- commands (shapes: qa/README.md, "Tracks, pins and the command reference")

/** `road`, `out` and `back` are optional: left out when the routing gave nothing, the playground then draws straight lines. */
export const placeAtCmd = (car, start, road) => ({ cmd: 'placeAt', car, start: toCoord(start), ...(toRoad(road) && { road: toRoad(road) }) });
export const endingCmd = (car, end, { road, leaveKm } = {}) => ({ cmd: 'ending', car, end: toCoord(end), ...(toRoad(road) && { road: toRoad(road) }), ...(Number.isFinite(leaveKm) && { leaveKm: round(leaveKm, 3) }) });
export const deviateCmd = (car, pin, { out, back, waitSeconds = 30, leaveKm } = {}) => ({
  cmd: 'deviate', car, pin: toCoord(pin), waitSeconds: clampWait(waitSeconds),
  ...(toRoad(out) && { out: toRoad(out) }), ...(toRoad(back) && { back: toRoad(back) }), ...(Number.isFinite(leaveKm) && { leaveKm: round(leaveKm, 3) }),
});
export const voteCmd = (car, event, answer, place) => ({ cmd: 'vote', car, event, answer, ...(place && { place: { name: place.name, latitude: place.lat, longitude: place.lng } }) });
export const prepareStartsCmd = (phone1, phone2, extra = {}) => ({ cmd: 'prepare', starts: { phone1: toCoord(phone1), phone2: toCoord(phone2 ?? phone1) }, ...extra });
const round = (n, d) => Math.round(n * 10 ** d) / 10 ** d;
export const clampWait = (s) => { const n = Number(s); return Number.isFinite(n) ? Math.max(0, Math.min(600, Math.round(n))) : 30; };

/** Where a car's road for an ending begins when no leave point was picked: the car's own spot if it is on the shared route, where it merges while it is joining, else the route at its offset. */
export function endingOrigin(car, route) {
  if (car.phase === 'onRoute' && car.latitude != null) return { lat: car.latitude, lng: car.longitude };
  if (car.phase === 'joining' && typeof car.mergeKm === 'number') return pointAtOffset(route, car.mergeKm * 1000); // the road starts where it merges
  return pointAtOffset(route, car.offset ?? 0);
}

/** Pins can be moved until the car starts driving the piece: a start always, an ending until the car is on it, a deviation until it leaves the route. */
export const canMovePin = (car, kind) => kind === 'start' || (kind === 'end' ? car.phase !== 'ending' && car.phase !== 'arrived' : ['onRoute', 'parked', null, undefined].includes(car.phase));

/** The app's position is a ghost on the map when it is more than 500 m from where the playground has the car. */
export function ghostOf(car, limit = 500) {
  const r = car.reported;
  if (!r || r.latitude == null || car.latitude == null) return null;
  const here = { lat: car.latitude, lng: car.longitude }, there = { lat: r.latitude, lng: r.longitude };
  return distance(here, there) > limit ? there : null;
}

/** Do the geometry on screen and the state's versions differ? `drawn` is {geometry: n, cars: {key: n}}. Returns what to redraw. */
export function geometryChanges(drawn, state, geometry) {
  if (!geometry) return { route: false, cars: [], remove: Object.keys(drawn.cars) };
  const route = drawn.routeText !== geometry.route;
  const cars = Object.entries(geometry.cars).filter(([k, g]) => drawn.cars[k] !== g.version).map(([k]) => k);
  const remove = Object.keys(drawn.cars).filter((k) => !(k in geometry.cars));
  return { route, cars, remove };
}

// ---- stop requests

export const STOP_LABEL = { stopRest: 'a rest stop', stopFuel: 'a fuel stop', stopFood: 'a food stop', stopToilet: 'a toilet stop' };
const PLACE_TITLE = { stopRest: 'Rest stop', stopFuel: 'Fuel stop', stopFood: 'Food stop', stopToilet: 'Toilet stop' };
export const stopTitle = (type) => PLACE_TITLE[type] ?? 'Stop';

/**
 * The cards to show over the map: one per open stop request. `who` is the asker (a generated car, a phone or another car); each generated car that
 * can still answer gets a row: `answer` null while it has not, `canAnswer` false for the asker, a car with no signal or one that has answered.
 */
export function stopPrompts(state) {
  if (!state?.events) return [];
  const gen = state.cars.filter((c) => c.kind === 'generated' && c.joined);
  return state.events.filter((e) => e.category === 'stopRequest' && e.status === 'open').map((e) => {
    const rows = gen.map((c) => {
      const a = e.answers?.[c.key] ?? null;
      const asker = e.byKey === c.key;
      return { key: c.key, label: c.label, color: c.color, asker, offline: c.offline, answer: a?.answer ?? null, place: a?.place ?? null, canAnswer: !asker && !c.offline && !a };
    });
    return {
      id: e.id, type: e.type, title: stopTitle(e.type), by: e.by || 'Someone', byKey: e.byKey, offset: e.offset, latitude: e.latitude, longitude: e.longitude,
      agree: e.agree, disagree: e.disagree, suggestions: e.suggestions ?? [], rows, anyToAnswer: rows.some((r) => r.canAnswer), fromPhone: !gen.some((c) => c.key === e.byKey),
    };
  });
}

/** Words for one car's answer on a card. */
export function answerText(r) {
  if (r.asker) return 'asked';
  if (r.offline && !r.answer) return 'no signal';
  if (r.answer === 'yes') return r.place ? `agrees, ${r.place}` : 'agrees';
  if (r.answer === 'another') return r.place ? `suggests ${r.place}` : 'suggests another place';
  if (r.answer === 'notNow') return 'not now';
  return 'has not answered';
}

/** A name for a place picked on the map, as the vote carries it ("1 to 100 characters"). */
export const pickedPlaceName = (car, n) => `${car}’s pick${n ? ' ' + n : ''}`.slice(0, 100);

// ---- cars

export const initialOf = (label) => { const t = String(label ?? '?').trim(); return /^Phone\s*(\d)/i.exec(t)?.[1] ?? (t[0] ?? '?').toUpperCase(); }; // the phones are "Phone 1" and "Phone 2": their number, not two P's
export const km1 = (m) => (typeof m === 'number' && Number.isFinite(m) ? (m / 1000).toFixed(1) + ' km' : '–');

/** How a car looks on the map: ringed for a phone, dashed while joining, faded with no signal. */
export const badgeClasses = (car) => ['badge', car.kind === 'phone' ? 'phone' : '', car.phase === 'joining' || car.state === 'joining' ? 'joining' : '', car.offline ? 'offline' : ''].filter(Boolean).join(' ');

/** Which car a problem belongs to: the car of the last command, if it was sent just before the problem appeared. */
export function problemOwner(state, last) {
  if (!state?.problem) return null;
  if (last && state.problemAt && state.problemAt >= last.at - 3000) return last.car ?? null;
  return null;
}

// ---- pins on the map

/** Where a deviation leaves the route when the person only dropped its pin: a kilometre before the pin's nearest spot, never closer than 150 m ahead of the car. */
export function defaultLeaveKm(carOffsetMeters, pinOffsetMeters) {
  return Math.max((carOffsetMeters ?? 0) + 150, pinOffsetMeters - 1000) / 1000;
}

/** Roads for a deviation when routing gave none: straight out to the pin and straight back to the route 1.5 km on (the playground would otherwise draw the way back to the destination). */
export function straightDeviation(route, pin, leaveKm) {
  const leave = pointAtOffset(route, leaveKm * 1000);
  const snapped = snapToRoute(route, pin);
  const rejoin = pointAtOffset(route, Math.max(snapped.offset, leaveKm * 1000) + 1500);
  return { out: [leave, pin], back: [pin, rejoin] };
}

// ---- what the app has for a car

export const ageText = (s) => (s === null || s === undefined ? '' : s < 90 ? `${s} s ago` : `${Math.round(s / 60)} min ago`);

/**
 * One line for "what the app has", and whether it needs attention. Judged by where the app has the car on the map (more than 500 m from the playground's)
 * and how old that is (over 60 s is stale), never by comparing route offsets: a car the app still has joining has no convoy offset yet.
 */
export function seesStatus(c) {
  if (!c.joined) return { text: c.kind === 'generated' ? 'Joining…' : 'Not joined yet. Join on phone 2 with the code.', warn: false };
  const r = c.reported;
  if (!r) return { text: 'The app has no position for this car yet.', warn: true };
  const age = ageText(r.ageSeconds);
  if (r.ageSeconds !== null && r.ageSeconds > 60) return { text: `The app last heard from this car ${age} (stale: “Last seen” on the other phones).`, warn: true };
  const g = ghostOf(c);
  if (g) return { text: `The app has this car ${km1(distance({ lat: c.latitude, lng: c.longitude }, g))} from where it is, ${age}.`, warn: true };
  if (c.state === 'joining') {
    const along = typeof c.trackMeters?.at === 'number' ? `, ${km1(c.trackMeters.at)} along its own road` : '';
    return { text: `The app still has this car joining${along}.`, warn: false };
  }
  return { text: `The app has this car at ${km1(r.offset)}, ${age}.`, warn: false };
}
