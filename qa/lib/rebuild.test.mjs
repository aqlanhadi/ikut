import test from 'node:test';
import assert from 'node:assert/strict';
import { RouteLine, Polyline } from './route.mjs';
import { loadRoutes } from '../generate-gpx.mjs';
import { driftedGaps, entries, togetherPairs } from './farahead.mjs';
import { ahead, distinctValues, rebuildRoute, staleReads, syntheticTrack, townDetour, ON_ROUTE_TOLERANCE } from './rebuild.mjs';

const direct = new RouteLine(loadRoutes().mainCoords);
const { coordinates, town, extra } = townDetour(direct, { from: 15_000, to: 19_000, bulge: 1500 });
const oldLine = new RouteLine(Polyline.decode(Polyline.encode(coordinates)));
const next = direct.coordinateAtOffset(22_000);
const stops = (extra2 = {}) => [
  { id: 'town', name: 'Lunch', coordinate: town, routeOffset: oldLine.project(town).offset, kind: 'food', order: 0, ...extra2 },
  { id: 'next', name: 'R&R', coordinate: next, routeOffset: oldLine.project(next).offset, kind: 'fuel', order: 1 },
];
const organizer = direct.coordinateAtOffset(8_300);
const destination = direct.coordinates.at(-1);
const run = (list = stops({ skipped: true })) => rebuildRoute({ oldLine, directLine: direct, stops: list, organizer, organizerOffset: 8_300, destination });

test('the town loop is longer than the highway it replaces and leaves it by more than the on-route tolerance', () => {
  assert.ok(extra > 500 && extra < 3000, `extra ${extra}`);
  assert.ok(direct.project(town).distance > 1000);
  const onHighway = direct.coordinateAtOffset(17_000);
  assert.ok(oldLine.project(onHighway).distance > ON_ROUTE_TOLERANCE);
  assert.ok(oldLine.project(direct.coordinateAtOffset(8_000)).distance < 5);
});

test('with the town stop skipped the rebuilt route is the highway: the stop ahead moves by what the loop added, once', () => {
  const list = stops({ skipped: true });
  const r = run(list);
  assert.deepEqual(Object.keys(r.offsets), ['next']);
  assert.ok(Math.abs(list[1].routeOffset - r.offsets.next - extra) < 20, `${list[1].routeOffset} -> ${r.offsets.next}, loop adds ${extra}`);
  assert.ok(Math.abs(r.offsets.next - 22_000) < 15);
  assert.ok(Math.abs(r.line.length - direct.length) < 30);
});

test('the line behind the organizer is kept point for point', () => {
  const r = run();
  assert.ok(Math.abs(r.cut - 8_300) < 5);
  const kept = oldLine.coordinates.filter((_, i) => oldLine.cumulative[i] < r.cut - 1);
  const decoded = Polyline.decode(r.route);
  kept.forEach((c, i) => assert.ok(Math.abs(c.latitude - decoded[i].latitude) < 2e-5 && Math.abs(c.longitude - decoded[i].longitude) < 2e-5));
});

test('a stop not skipped stays on the route: both stops get offsets, the town one on the loop', () => {
  const r = run(stops());
  assert.deepEqual(Object.keys(r.offsets).sort(), ['next', 'town']);
  assert.ok(r.offsets.town < r.offsets.next);
});

test('a stop behind the organizer, left, or reached is not moved', () => {
  assert.deepEqual(ahead(stops({ leftAt: 1 }), 8_300).map((s) => s.id), ['next']);
  assert.deepEqual(ahead(stops(), 17_500).map((s) => s.id), ['next']);
  assert.deepEqual(Object.keys(run(stops({ arrivedAt: 1 })).offsets), ['next']);
});

test('syntheticTrack drives at the speed and parks at 0', () => {
  const t = syntheticTrack(direct, { startOffset: 1000, speed: 20, seconds: 10 });
  assert.equal(t.length, 11);
  assert.ok(Math.abs(direct.project(t[10]).offset - 1200) < 2);
  assert.equal(new Set(syntheticTrack(direct, { startOffset: 5000, speed: 0, seconds: 5 }).map((p) => p.latitude)).size, 1);
});

test('staleReads counts writes past the moved stop since the rebuild; distinctValues drops repeats', () => {
  const writes = [{ T: 100, convoyOffset: 23_000 }, { T: 121, convoyOffset: 23_000 }, { T: 126, convoyOffset: 22_000 }];
  assert.equal(staleReads(writes, { from: 120, stopOffset: 22_000 }), 1);
  assert.equal(staleReads(writes, { from: 100, stopOffset: 22_000 }), 2);
  assert.deepEqual(distinctValues([1, 1, 2, 2, 2]), [1, 2]);
});

test('a rebuild that moves every car by what the loop added warns of nothing; one car losing the kept stretch does', () => {
  const car = (id, offset) => ({ id, name: id, isLead: id === 'a', offset, speed: 27, age: 1 });
  const together = togetherPairs(entries([car('a', 8_000), car('b', 7_200)]));
  const shifted = entries([car('a', 8_000 + 1_071), car('b', 7_200 + 1_071)]);
  assert.deepEqual(driftedGaps(shifted, together), []);
  const lost = entries([car('a', 8_000), car('b', 0)]);
  assert.deepEqual(driftedGaps(lost, together), ['b']);
});
