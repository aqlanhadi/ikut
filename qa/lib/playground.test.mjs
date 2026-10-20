import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RouteLine, CarRouteLogic, haversine } from './route.mjs';
import { loadRoutes } from '../generate-gpx.mjs';
import {
  advanceOffset, clampKmh, decodeDoc, destinationPoint, feedPoints, isOpenStop, nudged, offRouteCoords, parseStart,
  pendingVotes, suggestionAhead, ageSeconds, UserError, numberIn, startFrom, validDerivedData, shouldPark, autoPick,
} from './playground.mjs';

const route = new RouteLine(loadRoutes().mainCoords);

test('driving: 90 km/h is 25 m a second, paused stays, the end of the route stops it', () => {
  assert.equal(advanceOffset(1000, 90, 1, route.length), 1025);
  assert.equal(advanceOffset(1000, 0, 5, route.length), 1000);
  assert.equal(advanceOffset(route.length - 10, 200, 5, route.length), route.length);
  assert.equal(advanceOffset(10, 90, -1, route.length), 0);
});

test('speed is kept between 0 and 200', () => {
  assert.equal(clampKmh(250), 200);
  assert.equal(clampKmh(-5), 0);
  assert.equal(clampKmh('abc'), 0);
  assert.equal(clampKmh('95'), 95);
});

test('a free start is "lat,lng"', () => {
  assert.deepEqual(parseStart('3.45, 101.4'), { latitude: 3.45, longitude: 101.4 });
  assert.equal(parseStart('hello'), null);
  assert.equal(parseStart('95,10'), null);
});

test('destinationPoint is the asked distance away', () => {
  const p = route.coordinateAtOffset(1000);
  for (const b of [0, 90, 200]) assert.ok(Math.abs(haversine(p, destinationPoint(p, b, 2000)) - 2000) < 2);
});

test('an off-route car starts far from the route and merges at the asked offset (state joining)', () => {
  const merge = 6000;
  const coords = offRouteCoords(route, merge, 2000);
  const start = coords[0];
  assert.ok(route.project(start).distance > 1500, 'the side point is off the route');
  const plan = CarRouteLogic.makePlan(coords, route);
  assert.equal(plan.state, 'joining');
  assert.equal(plan.kind, 'merges');
  assert.ok(Math.abs(plan.mergeOffset - merge) < 120, `merge ${plan.mergeOffset}`);
  const own = new RouteLine(coords);
  const m = route.mergeOffset(own, CarRouteLogic.mergeTolerance);
  assert.ok(own.length > m.otherOffset, 'the road goes on past the merge');
});

test('a simulator feed starts at the car and goes ahead in 80 m steps', () => {
  const pts = feedPoints(route, 3000);
  assert.deepEqual(pts[0], route.coordinateAtOffset(3000));
  assert.ok(Math.abs(haversine(pts[1], pts[2]) - 80) < 3);
  assert.equal(feedPoints(route, route.length - 10).length, 2, 'two waypoints near the end');
  assert.equal(feedPoints(route, route.length).length, 1);
  assert.ok(shouldPark(route.length - 79, route.length));
  assert.ok(!shouldPark(route.length - 81, route.length));
});

test('a parked nudge alternates', () => {
  const c = { latitude: 3, longitude: 101 };
  assert.notDeepEqual(nudged(c, 0), nudged(c, 1));
});

test('stop votes: after the delay, once, never on its own, only open stops', () => {
  const events = [
    { id: 'a', category: 'stopRequest', carId: 'phone' },
    { id: 'b', category: 'stopRequest', carId: 'me' },
    { id: 'c', category: 'hazard', carId: 'phone' },
    { id: 'd', category: 'stopRequest', carId: 'phone', expiresAt: 5 },
  ];
  assert.equal(isOpenStop(events[3]), false);
  const seen = new Map();
  const voted = new Set();
  assert.deepEqual(pendingVotes(events, 'me', seen, voted, 1000), []);
  assert.deepEqual(pendingVotes(events, 'me', seen, voted, 5999), []);
  assert.deepEqual(pendingVotes(events, 'me', seen, voted, 6000), ['a']);
  voted.add('a');
  assert.deepEqual(pendingVotes(events, 'me', seen, voted, 9000), []);
});

test('a suggestion is ahead of the lead, on the route', () => {
  const s = suggestionAhead(route, 5000, 'R&R Demo');
  assert.equal(s.routeOffset, 9000);
  assert.ok(route.project(s).distance < 5);
  assert.equal(suggestionAhead(route, route.length - 10, 'x').routeOffset, route.length);
});

test('Firestore REST documents decode', () => {
  const d = decodeDoc({
    name: 'projects/p/databases/(default)/documents/trips/t/events/e1',
    fields: {
      type: { stringValue: 'debris' }, routeOffset: { doubleValue: 1234.5 }, n: { integerValue: '3' },
      createdAt: { timestampValue: '2026-10-20T10:00:00.000Z' }, place: { mapValue: { fields: { name: { stringValue: 'R&R' } } } },
      location: { geoPointValue: { latitude: 3.1, longitude: 101.2 } },
    },
  });
  assert.equal(d.id, 'e1');
  assert.equal(d.routeOffset, 1234.5);
  assert.equal(d.n, 3);
  assert.equal(d.createdAt, Date.parse('2026-10-20T10:00:00Z'));
  assert.equal(d.place.name, 'R&R');
  assert.deepEqual(d.location, { latitude: 3.1, longitude: 101.2 });
  assert.equal(ageSeconds(d.createdAt, d.createdAt + 12_400), 12);
  assert.equal(ageSeconds(undefined, 5), null);
});

test('numbers in a command must be finite and in range', () => {
  assert.equal(numberIn('2.5', 0, 10, 'Km'), 2.5);
  for (const bad of [NaN, Infinity, 'abc', '', null, undefined, {}, -1, 11]) assert.throws(() => numberIn(bad, 0, 10, 'Km'), UserError);
});

test('start is "default" or "lat,lng" text, never an object', () => {
  assert.equal(startFrom(undefined), 'default');
  assert.equal(startFrom('default'), 'default');
  assert.deepEqual(startFrom('3.1,101.2'), { latitude: 3.1, longitude: 101.2 });
  assert.throws(() => startFrom({ latitude: NaN, longitude: 5 }), UserError);
  assert.throws(() => startFrom('nowhere'), UserError);
});

test('the build folder is a plain name under /tmp', () => {
  assert.equal(validDerivedData(undefined), null);
  assert.equal(validDerivedData('/tmp/ikut-dd-q4'), '/tmp/ikut-dd-q4');
  assert.equal(validDerivedData('/private/tmp/dd.1'), '/private/tmp/dd.1');
  for (const bad of ['-derivedDataPath', '/tmp/-x', '/tmp/a/b', '/etc/passwd', '/tmp/../etc', 'tmp/x', 5, {}]) assert.throws(() => validDerivedData(bad), UserError);
});

test('a trip is picked by itself only when it is the only one, has one car, and that car is at the start', () => {
  const one = { tripId: 'a', cars: 1, firstCarDistance: 40 };
  assert.equal(autoPick([one]), one);
  assert.equal(autoPick([]), null);
  assert.equal(autoPick([one, { ...one, tripId: 'b' }]), null);
  assert.equal(autoPick([{ ...one, cars: 4 }]), null, 'a trip that already has several cars');
  assert.equal(autoPick([{ ...one, firstCarDistance: null }]), null, 'no position yet');
  assert.equal(autoPick([{ ...one, firstCarDistance: 5000 }]), null, 'the first car is somewhere else');
});
