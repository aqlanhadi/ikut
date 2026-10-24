// node --test tools/osm/
// A synthetic dual carriageway running due north, with an R&R on each side, checks the place functions without
// any downloaded data.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  toPlaces, roadIndex, slipRoads, carriageway, sideOf, along, straddles, isRnR, suggestStops, rankForRequest,
  requestWhy, RouteLine,
} from './places.mjs';

const NORTH_LON = 101.5; // northbound carriageway (drive on the left: it is the western one)
const SOUTH_LON = 101.5004; // southbound, about 44 m east
const lats = Array.from({ length: 201 }, (_, i) => Number((3 + i * 0.005).toFixed(3))); // 3.000 ... 4.000
const g = (lat, lon) => ({ lat, lon });
const c = (lat, lon) => ({ latitude: lat, longitude: lon });
const box = (s, w, n, e) => [g(s, w), g(s, e), g(n, e), g(n, w), g(s, w)];

let id = 1;
const way = (tags, geometry) => ({ type: 'way', id: id++, tags, geometry });
const node = (tags, lat, lon) => ({ type: 'node', id: id++, tags, lat, lon });

function corridor() {
  return [
    way({ highway: 'motorway', ref: 'E1' }, lats.map((lat) => g(lat, NORTH_LON))),
    way({ highway: 'motorway', ref: 'E1' }, [...lats].reverse().map((lat) => g(lat, SOUTH_LON))),
    // West R&R at 3.5 (about 55.6 km along), serving northbound traffic.
    way({ highway: 'services', name: 'Test Rest Area North Bound' }, box(3.499, 101.4985, 3.501, 101.4995)),
    node({ amenity: 'fuel', brand: 'Petronas' }, 3.5, 101.499),
    node({ amenity: 'toilets' }, 3.5002, 101.4988),
    node({ amenity: 'charging_station' }, 3.4998, 101.4988),
    // Its slip roads: off the northbound carriageway at 3.495, back on at 3.505.
    way({ highway: 'motorway_link' }, [g(3.495, NORTH_LON), g(3.4975, 101.4998), g(3.4992, 101.4995)]),
    way({ highway: 'motorway_link' }, [g(3.5008, 101.4995), g(3.5025, 101.4998), g(3.505, NORTH_LON)]),
    // East R&R at 3.5, serving southbound traffic, its slip road off the southbound carriageway at 3.505.
    way({ highway: 'services', name: 'Test Rest Area South Bound' }, box(3.499, 101.5009, 3.501, 101.5019)),
    node({ amenity: 'fuel', brand: 'Shell' }, 3.5, 101.5014),
    way({ highway: 'service', oneway: 'yes' }, [g(3.505, SOUTH_LON), g(3.5025, 101.5007), g(3.5008, 101.5009)]),
    // A lay-by further north on our side, with toilets only, and no slip roads mapped.
    way({ highway: 'rest_area', name: 'Test Layby' }, box(3.699, 101.4990, 3.700, 101.4995)),
    node({ amenity: 'toilets' }, 3.6995, 101.4992),
    // A town fuel station 5 km off the road.
    node({ amenity: 'fuel', brand: 'BHPetrol' }, 3.6, 101.45),
  ];
}

const northbound = new RouteLine(lats.map((lat) => c(lat, NORTH_LON)));
const southbound = new RouteLine([...lats].reverse().map((lat) => c(lat, SOUTH_LON)));

test('places carry the facilities mapped inside them', () => {
  const places = toPlaces(corridor());
  const west = places.find((p) => p.name === 'Test Rest Area North Bound');
  assert.deepEqual(west.facilities, { fuel: true, toilets: true, food: true, ev: true });
  assert.deepEqual(west.brands, ['Petronas']);
  const layby = places.find((p) => p.name === 'Test Layby');
  assert.deepEqual(layby.facilities, { fuel: false, toilets: true, food: false, ev: false });
  // The town pump stands alone; the R&R pumps belong to their R&Rs.
  assert.deepEqual(places.filter((p) => p.kind === 'fuel').map((p) => p.name), ['BHPetrol']);
});

test('the west side is left going north and right going south', () => {
  assert.equal(sideOf(c(3.5, 101.499), northbound).side, 'left');
  assert.equal(sideOf(c(3.5, 101.499), southbound).side, 'right');
  assert.equal(sideOf(c(3.5, 101.5014), northbound).side, 'right');
});

test('slip roads tell which carriageway an R&R serves', () => {
  const els = corridor();
  const places = toPlaces(els), roads = roadIndex(els);
  const west = places.find((p) => p.name === 'Test Rest Area North Bound');
  const east = places.find((p) => p.name === 'Test Rest Area South Bound');
  assert.equal(carriageway(slipRoads(west, roads), northbound), 'ours');
  assert.equal(carriageway(slipRoads(east, roads), northbound), 'opposite');
  assert.equal(carriageway(slipRoads(east, roads), southbound), 'ours');
  const layby = places.find((p) => p.name === 'Test Layby');
  assert.equal(carriageway(slipRoads(layby, roads), northbound), null);
});

test('along the route: our side, the entrance on our slip road, and the offset where it leaves the road', () => {
  const els = corridor();
  const rows = along(toPlaces(els), northbound, roadIndex(els));
  const west = rows.find((p) => p.name === 'Test Rest Area North Bound');
  const east = rows.find((p) => p.name === 'Test Rest Area South Bound');
  assert.equal(west.ours, true);
  assert.equal(east.ours, false);
  assert.equal(west.slipEntrance, true);
  assert.deepEqual(west.entrance, c(3.4992, 101.4995)); // the gate, not the middle of the R&R
  assert.ok(Math.abs(west.routeOffset - northbound.project(c(3.495, NORTH_LON)).offset) < 1);
  // No slip road mapped: route to the lay-by itself, at its projected offset.
  const layby = rows.find((p) => p.name === 'Test Layby');
  assert.equal(layby.ours, true);
  assert.equal(layby.slipEntrance, false);
  // The town pump 5 km away is out of reach.
  assert.equal(rows.some((p) => p.name === 'BHPetrol'), false);
  // In route order.
  assert.deepEqual(rows.map((p) => p.routeOffset), [...rows.map((p) => p.routeOffset)].sort((a, b) => a - b));
});

test('an overhead R&R spanning the road serves both directions', () => {
  const ring = box(3.3, 101.4997, 3.3005, 101.5007).map((p) => c(p.lat, p.lon));
  assert.equal(straddles(ring, northbound), true);
  const west = box(3.499, 101.4985, 3.501, 101.4995).map((p) => c(p.lat, p.lon));
  assert.equal(straddles(west, northbound), false);
  const bridge = { type: 'way', id: 999, tags: { highway: 'services', name: 'Jejantas' }, geometry: box(3.3, 101.4997, 3.3005, 101.5007) };
  const both = along(toPlaces([bridge]), northbound, null);
  assert.equal(both[0].side, 'both');
  assert.equal(both[0].ours, true);
  assert.equal(along(toPlaces([bridge]), southbound, null)[0].ours, true);
});

// Candidates as along() returns them, on a 300 km route driven at 75 km/h (4 h).
const full = { fuel: true, food: true, toilets: true, ev: false };
const place = (name, km, extra = {}) => ({
  name, kind: 'services', ours: true, routeOffset: km * 1000, facilities: { ...full }, ...extra,
});
const fourHours = { routeLength: 300_000, routeSeconds: 14_400 };
const km = (min) => (min / 60) * 75; // minutes along -> km

test('an R&R is a services area with fuel, not a lay-by however OSM tags it', () => {
  assert.equal(isRnR(place('Tapah Rest Area', 1)), true);
  assert.equal(isRnR(place('Tanjung Malim Layby', 1)), false);
  assert.equal(isRnR(place('Hentian Sebelah Behrang', 1)), false);
  assert.equal(isRnR(place('X', 1, { kind: 'rest_area' })), false);
  assert.equal(isRnR(place('X', 1, { facilities: { ...full, fuel: false } })), false);
});

test('suggest stops: the R&R on our side nearest each 2 hours', () => {
  const picks = suggestStops([
    place('Early', km(110)), place('Late', km(140)), place('Other side', km(120), { ours: false }),
    place('Lay-by', km(120), { name: 'Some Layby' }),
  ], fourHours);
  assert.deepEqual(picks.map((p) => p.place.name), ['Early']);
  assert.equal(picks[0].why, '110 min along · fuel, food, toilets');
});

test('suggest stops: a near tie goes to the one with EV charging', () => {
  const picks = suggestStops([place('Plain', km(118)), place('Charger', km(122), { facilities: { ...full, ev: true } })], fourHours);
  assert.equal(picks[0].place.name, 'Charger');
});

test('suggest stops: a stop the organizer already has near 2 hours counts as the break', () => {
  assert.deepEqual(suggestStops([place('R&R', km(120))], { ...fourHours, existing: [km(125) * 1000] }), []);
});

test('suggest stops: none in the last half hour, none when nothing is within half an hour of the mark', () => {
  assert.deepEqual(suggestStops([place('Far', km(160))], fourHours), []);
  assert.deepEqual(suggestStops([place('Near the end', km(225))], fourHours), []);
});

test('suggest stops: a 2 h 24 min trip gets one stop near halfway, a 1 h trip none', () => {
  const trip = { routeLength: 180_000, routeSeconds: 8_640 }; // KL-Ipoh: 2 h 24 min
  const at = (min) => ((min * 60) / 8_640) * 180_000 / 1000;
  const picks = suggestStops([place('Quarter', at(30)), place('Middle', at(80)), place('End', at(130))], trip);
  assert.deepEqual(picks.map((p) => p.place.name), ['Middle']);
  assert.deepEqual(suggestStops([place('Middle', 40)], { routeLength: 80_000, routeSeconds: 3_600 }), []);
});

const speed = 25; // m/s, 90 km/h

test('a stop request: ahead of the lead, on our side, within the most urgent reason', () => {
  const rows = rankForRequest([
    place('Behind', 50), place('Just ahead', 60.3), place('Opposite', 70, { ours: false }),
    place('Toilet in 15 min', 60 + 22.5), place('In 25 min', 60 + 37.5),
  ], { frontOffset: 60_000, reasons: ['toilet'], speed });
  assert.deepEqual(rows.map((r) => r.place.name), ['Toilet in 15 min']);
  assert.equal(rows[0].why, '15 min ahead · toilets');
});

test('a stop request: covering every reason first, then nearest with lay-bys counted 15 min further', () => {
  const rows = rankForRequest([
    place('Toilets only', 70, { facilities: { fuel: false, food: false, toilets: true, ev: false } }),
    place('Lay-by with a pump', 66, { name: 'A Layby' }),
    place('R&R', 75),
    place('R&R further', 110),
  ], { frontOffset: 60_000, reasons: ['toilet', 'fuel'], speed });
  assert.deepEqual(rows.map((r) => r.place.name), ['R&R', 'A Layby', 'Toilets only']);
  assert.equal(rows[2].why, '7 min ahead · toilets, no fuel');
});

test('a stop request for fuel uses the asker\'s range when given', () => {
  const ask = { frontOffset: 0, reasons: ['fuel'], speed };
  assert.equal(rankForRequest([place('R&R', 55)], ask).length, 1); // 37 min, inside 40
  assert.equal(rankForRequest([place('R&R', 55)], { ...ask, fuelRangeMeters: 30_000 }).length, 0);
});

test('the why line names what is missing and never says 0 min', () => {
  assert.equal(requestWhy({ facilities: full }, ['rest'], 10), '1 min ahead · parking');
  assert.equal(requestWhy({ facilities: { ...full, food: false } }, ['food', 'toilet'], 600), '10 min ahead · toilets, no food');
});
