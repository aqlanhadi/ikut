import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RouteLine, CarRouteLogic, haversine } from './route.mjs';
import { loadRoutes } from '../generate-gpx.mjs';
import {
  advanceOffset, clampKmh, decodeDoc, destinationPoint, feedPoints, isOpenStop, nudged, offRouteCoords, parseStart,
  pendingVotes, suggestionAhead, ageSeconds, UserError, numberIn, startFrom, validDerivedData, shouldPark, autoPick,
  MAX_POINTS, PALETTE, FIRST_NAMES, EVENT_KINDS, STOP_TYPES, REPORT_TYPES, LEAVE_SLACK, answersByCar, buildTrack, carNameFor, carryState, composeTrack, coordIn, coordsIn,
  divergeOffset, eventKindIn, eventStatus, fallbackStartRoad, locate, mainDistance, mainLeg, nameIn, newCarState, nextCar, nextWait, openStopSnapshot,
  optionalCoords, ownLeg, placeOnRoute, planDeviation, planEnding, planStart, relocate, sideRoad, sliceFrom, stepTrack, straightRoad, trackFeedPoints,
  trackFromOffset, trackHeading, trackLength, trackPoint, voteAnswer, waitLeg,
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


// ================================================================ Q7: tracks

const M = CarRouteLogic.mergeTolerance;
/** A side road leaving the route at `offset`: goes `meters` out to the left in 40 m steps, then (optionally) keeps going. */
function branch(offset, meters, { side = -90 } = {}) {
  const a = route.coordinateAtOffset(offset);
  const b = route.coordinateAtOffset(offset + 25);
  const heading = (Math.atan2((b.longitude - a.longitude) * Math.cos((a.latitude * Math.PI) / 180), b.latitude - a.latitude) * 180) / Math.PI;
  const out = [a];
  for (let m = 40; m <= meters; m += 40) out.push(destinationPoint(a, heading + side, m));
  return out;
}

test('a main-only track is the old km placement: same points, same length', () => {
  const t = trackFromOffset(route, 3000);
  assert.equal(trackLength(t), route.length - 3000);
  assert.deepEqual(trackPoint(t, 0), route.coordinateAtOffset(3000));
  assert.deepEqual(trackPoint(t, 1234), route.coordinateAtOffset(4234));
  assert.deepEqual(feedPoints(route, 3000), trackFeedPoints(trackFromOffset(route, 0), 3000));
  const loc = locate(t, 500);
  assert.equal(loc.phase, 'onRoute');
  assert.equal(loc.onMain, true);
  assert.equal(Math.round(loc.mainOffset), 3500);
  assert.ok(Math.abs(loc.heading - trackHeading(trackFromOffset(route, 0), 3500)) < 0.01);
});

test('a track lays main stretches and own roads end to end; locate says which leg and whether it is the shared route', () => {
  const side = new RouteLine(branch(5000, 800));
  const t = buildTrack(route, [mainLeg(2000, 5000), ownLeg('ending', side), mainLeg(9000, 9000)]);
  assert.ok(Math.abs(t.length - (3000 + side.length)) < 1e-6);
  assert.equal(t.legs.length, 2, 'a zero-length leg is dropped');
  const a = locate(t, 1000);
  assert.equal(a.phase, 'onRoute');
  assert.equal(Math.round(a.mainOffset), 3000);
  const b = locate(t, 3000 + 400);
  assert.equal(b.onMain, false);
  assert.equal(b.mainOffset, null);
  assert.equal(b.phase, 'ending');
  assert.ok(haversine(b.point, side.coordinateAtOffset(400)) < 0.01);
  const end = locate(t, t.length + 100);
  assert.equal(end.phase, 'arrived');
  assert.ok(haversine(end.point, side.coordinates.at(-1)) < 0.01);
  assert.ok(haversine(trackPoint(t, 2999), trackPoint(t, 3001)) < 3, 'no jump where the legs meet');
});

test('feed points follow the track from a distance, through own legs, and stop where asked', () => {
  const side = new RouteLine(branch(5000, 800));
  const t = buildTrack(route, [mainLeg(4000, 5000), ownLeg('ending', side)]);
  const pts = trackFeedPoints(t, 500);
  assert.deepEqual(pts[0], trackPoint(t, 500));
  assert.ok(haversine(pts.at(-1), side.coordinates.at(-1)) < 80);
  assert.ok(pts.some((p) => route.project(p).distance > 100), 'goes off the route');
  const cut = trackFeedPoints(t, 100, { stopAt: 1000 });
  assert.ok(haversine(cut.at(-1), trackPoint(t, 1000)) < 80);
  assert.equal(trackFeedPoints(t, t.length).length, 1);
  assert.equal(trackFeedPoints(t, t.length - 10).length, 2);
  assert.equal(trackFeedPoints(t, 1000, { stopAt: 1000 }).length, 1, 'already at the wait: nothing to play');
});

test('stepping: speed, pause, end of track', () => {
  const t = trackFromOffset(route, route.length - 100);
  let st = newCarState();
  st = stepTrack(t, st, 90, 1, true);
  assert.equal(st.d, 25);
  assert.equal(stepTrack(t, st, 90, 5, false).d, 25);
  assert.equal(stepTrack(t, st, 0, 5, true).d, 25);
  assert.equal(stepTrack(t, st, 200, 60, true).d, 100);
});

test('a wait: the car stops at the pin, stands for its seconds only while playing, then goes on', () => {
  const out = new RouteLine(branch(3000, 400));
  const back = new RouteLine([out.coordinates.at(-1), ...branch(3600, 400).reverse().slice(0, 1), route.coordinateAtOffset(3800), route.coordinateAtOffset(4300)]);
  const t = buildTrack(route, [mainLeg(2000, 3000), ownLeg('out', out), waitLeg(30, out.coordinates.at(-1)), ownLeg('back', back), mainLeg(3800, route.length)]);
  const pinAt = 1000 + out.length;
  let st = newCarState();
  st = { ...st, d: pinAt - 10 };
  assert.equal(nextWait(t, st).startAt, pinAt);
  st = stepTrack(t, st, 90, 1, true);
  assert.equal(st.d, pinAt, 'stopped at the pin, not past it');
  assert.deepEqual(st.waiting, { id: 'wait', left: 30 });
  assert.equal(locate(t, st.d, { waiting: 'wait' }).phase, 'waiting');
  assert.ok(haversine(locate(t, st.d, { waiting: 'wait' }).point, out.coordinates.at(-1)) < 0.01);
  assert.equal(locate(t, st.d).phase, 'back', 'without the wait flag the same distance is the start of the way back');
  for (let i = 0; i < 10; i++) st = stepTrack(t, st, 90, 1, true);
  assert.equal(Math.round(st.waiting.left), 20);
  assert.equal(stepTrack(t, st, 90, 5, false).waiting.left, st.waiting.left, 'paused: the clock waits too');
  for (let i = 0; i < 20; i++) st = stepTrack(t, st, 90, 1, true);
  assert.equal(st.waiting, null);
  assert.equal(nextWait(t, st), null, 'served: it does not wait again');
  st = stepTrack(t, st, 90, 1, true);
  assert.equal(st.d, pinAt + 25);
  assert.equal(locate(t, st.d).phase, 'back');
  const zero = buildTrack(route, [mainLeg(2000, 3000), waitLeg(0, route.coordinateAtOffset(3000))]);
  assert.equal(nextWait(zero, newCarState()), null, 'a wait of 0 seconds is no wait');
});

test('relocate keeps a car where it is when the track changes after it', () => {
  const side = new RouteLine(branch(6000, 600));
  const before = trackFromOffset(route, 2000);
  const after = buildTrack(route, [mainLeg(2000, 6000), ownLeg('ending', side)]);
  assert.equal(relocate(before, 1500, null, after), 1500, 'on the shared route');
  const ownOnly = buildTrack(route, [ownLeg('start', side), mainLeg(6000, route.length)]);
  const longer = buildTrack(route, [ownLeg('start', side), mainLeg(6000, 9000), ownLeg('ending', new RouteLine(branch(9000, 500)))]);
  assert.equal(relocate(ownOnly, 300, null, longer), 300, 'on the same own leg');
  assert.equal(relocate(after, 4000 + 100, null, before), null, 'the own leg is gone');
  assert.equal(mainDistance(after, 7000), null);
  assert.equal(mainDistance(after, 3000), 1000);
});

test('divergeOffset: a road that touches the route and leaves; one that ends on it; one that never shares it', () => {
  // runs on the route 2000-5000 (as a Google road would), then leaves for good
  const shared = [];
  for (let m = 2000; m <= 5000; m += 40) shared.push(route.coordinateAtOffset(m));
  const leaving = new RouteLine([...shared, ...branch(5000, 1200).slice(1)]);
  const d = divergeOffset(route, leaving);
  assert.ok(Math.abs(d.mainOffset - 5000) < 80, `leaves at ${d.mainOffset}`);
  assert.ok(Math.abs(d.roadOffset - 3000) < 80, `road offset ${d.roadOffset}`);
  assert.equal(d.never, undefined);

  // touches the route in the middle, goes away, comes back and leaves for good: the last leave counts
  const wiggle = new RouteLine([...branch(1000, 600).reverse(), ...branch(1000, 600).slice(1), ...shared.slice(0, 20), ...branch(shared.length ? 2000 + 19 * 40 : 0, 900).slice(1)]);
  const w = divergeOffset(route, wiggle);
  assert.ok(Math.abs(w.mainOffset - (2000 + 19 * 40)) < 80, `last leave ${w.mainOffset}`);

  assert.equal(divergeOffset(route, new RouteLine(shared)), null, 'ends on the route');
  const far = new RouteLine(branch(7000, 2000, { side: 90 }).map((p) => destinationPoint(p, 0, 0)).slice(2));
  const never = divergeOffset(route, far);
  assert.equal(never.never, true);
  assert.equal(never.roadOffset, 0);
});

test('planStart: within 150 m of the route the car starts on it at the projected offset', () => {
  const near = destinationPoint(route.coordinateAtOffset(4000), 90, 60);
  const p = planStart(route, near, [near, route.coordinateAtOffset(9000)]);
  assert.equal(p.kind, 'main');
  assert.ok(Math.abs(p.offset - 4000) < 120);
  const edge = destinationPoint(route.coordinateAtOffset(4000), 90, 200);
  assert.equal(planStart(route, edge, null).kind, 'road');
});

test('planStart: a Google road is cut at the merge and the car is joining (CarRouteLogic.makePlan)', () => {
  const start = branch(5000, 2500)[branch(5000, 2500).length - 1];
  const road = [...branch(5000, 2500).reverse(), ...[0, 600, 1200].map((m) => route.coordinateAtOffset(5000 + m))];
  const p = planStart(route, start, road);
  assert.equal(p.kind, 'road');
  assert.equal(p.straight, false);
  assert.equal(p.plan.state, 'joining');
  assert.ok(Math.abs(p.mergeMain - 5000) < 100, `merge ${p.mergeMain}`);
  assert.ok(Math.abs(p.plan.mergeOffset - p.mergeMain) < 100);
  assert.ok(haversine(p.line.coordinates[0], start) < 3, 'starts at the pin');
  assert.ok(Math.abs(p.line.length - 2500) < 150, 'the own leg ends at the merge');
  const t = composeTrack(route, { start: p });
  assert.equal(locate(t, 100).phase, 'joining');
  assert.equal(locate(t, p.line.length + 100).phase, 'onRoute');
  assert.ok(Math.abs(locate(t, p.line.length + 100).mainOffset - (p.mergeMain + 100)) < 1);
  assert.ok(Math.abs(t.length - (p.line.length + route.length - p.mergeMain)) < 1);
});

test('planStart without a road: a straight line to the route about 1.5 km ahead of its nearest point', () => {
  const start = destinationPoint(route.coordinateAtOffset(4000), -90, 1800);
  const coords = fallbackStartRoad(route, start);
  assert.deepEqual(coords[0], start);
  const p = planStart(route, start, null);
  assert.equal(p.kind, 'road');
  assert.equal(p.straight, true);
  assert.equal(p.plan.kind, 'merges');
  assert.ok(Math.abs(p.mergeMain - (route.project(start).offset + 1500)) < 150, `merge ${p.mergeMain}`);
  const bad = planStart(route, start, [start, destinationPoint(start, 0, 300)]);
  assert.equal(bad.straight, true, 'a road that never reaches the route falls back to the straight one');
  const nearEnd = planStart(route, destinationPoint(route.coordinateAtOffset(route.length - 300), -90, 1000), null);
  assert.equal(nearEnd.kind, 'road');
  assert.ok(nearEnd.mergeMain <= route.length);
});

test('planEnding: the car leaves where the road leaves the route for good, then parks at the end', () => {
  const shared = [];
  for (let m = 3000; m <= 6000; m += 40) shared.push(route.coordinateAtOffset(m));
  const road = [...shared, ...branch(6000, 3000).slice(1)];
  const end = road.at(-1);
  const e = planEnding(route, { end, road });
  assert.equal(e.kind, 'road');
  assert.ok(Math.abs(e.leaveOffset - 6000) < 80, `leaves at ${e.leaveOffset}`);
  assert.ok(Math.abs(e.line.length - 3000) < 150);
  assert.ok(haversine(e.line.coordinates[0], route.coordinateAtOffset(e.leaveOffset)) < 1, 'starts on the route');
  assert.ok(haversine(e.line.coordinates.at(-1), end) < 1);
  assert.equal(e.plan.kind, 'neverMerges');
  assert.equal(e.plan.state, 'joining');
  const t = composeTrack(route, { startOffset: 3000, ending: e });
  assert.ok(Math.abs(t.length - (e.leaveOffset - 3000 + e.line.length)) < 1);
  assert.equal(locate(t, 100).phase, 'onRoute');
  assert.equal(locate(t, t.length - 1000).phase, 'ending');
  assert.equal(locate(t, t.length).phase, 'arrived');
});

test('planEnding with leaveKm: the car leaves there, whatever the road shares; without a road a straight line', () => {
  const road = branch(6500, 2000);
  const e = planEnding(route, { end: road.at(-1), road, leaveKm: 6.5 });
  assert.equal(e.leaveOffset, 6500);
  assert.ok(Math.abs(e.line.length - 2000) < 100);
  const straight = planEnding(route, { end: road.at(-1), leaveKm: 6.5 });
  assert.ok(Math.abs(straight.line.length - 2000) < 100);
  assert.throws(() => planEnding(route, { end: road.at(-1) }), UserError);
  // an end that is on the route: the car simply parks there
  const sharedRoad = [];
  for (let m = 3000; m <= 6000; m += 40) sharedRoad.push(route.coordinateAtOffset(m));
  const on = planEnding(route, { end: sharedRoad.at(-1), road: sharedRoad });
  assert.equal(on.kind, 'onRoute');
  assert.ok(Math.abs(on.parkOffset - 6000) < 5);
  const t = composeTrack(route, { startOffset: 3000, ending: on });
  assert.ok(Math.abs(t.length - 3000) < 5);
  assert.equal(locate(t, t.length).phase, 'arrived');
});

test('planDeviation: out to the pin, wait, back, merging further ahead; the car doc gets the whole road', () => {
  const out = branch(4000, 1500);
  const pin = out.at(-1);
  const back = [pin, ...branch(6000, 1500).reverse(), ...[0, 400, 800].map((m) => route.coordinateAtOffset(6000 + m))];
  const dev = planDeviation(route, { leaveKm: 4, pin, out, back });
  assert.equal(dev.leaveOffset, 4000);
  assert.ok(Math.abs(dev.mergeMain - 6000) < 100, `merge ${dev.mergeMain}`);
  assert.ok(Math.abs(dev.out.length - 1500) < 100);
  assert.ok(haversine(dev.out.coordinates[0], route.coordinateAtOffset(4000)) < 1);
  assert.ok(haversine(dev.back.coordinates[0], pin) < 1);
  assert.ok(route.project(dev.back.coordinates.at(-1)).distance <= M + 5, 'the way back ends on the route');
  assert.equal(dev.plan.state, 'joining');
  assert.ok(Math.abs(dev.plan.mergeOffset - dev.mergeMain) < 100);
  const t = composeTrack(route, { startOffset: 1000, deviation: { ...dev, waitSeconds: 30 } });
  const phases = [];
  for (let d = 0; d <= t.length; d += 100) phases.push(locate(t, d).phase);
  const order = phases.filter((p, i) => p !== phases[i - 1]);
  assert.deepEqual(order, ['onRoute', 'out', 'back', 'onRoute'], 'shared route, out, back, shared route again (the wait has no distance)');
  assert.ok(Math.abs(t.length - (route.length - 1000 - (dev.mergeMain - 4000) + dev.out.length + dev.back.length)) < 1);
  assert.equal(nextWait(t, newCarState()).seconds, 30);
});

test('planDeviation without roads: straight lines out and back', () => {
  const pin = destinationPoint(route.coordinateAtOffset(5000), -90, 1500);
  const dev = planDeviation(route, { leaveKm: 4.5, pin });
  assert.ok(dev.mergeMain > 4500);
  assert.ok(Math.abs(dev.out.length - haversine(route.coordinateAtOffset(4500), pin)) < 60);
});

test('planDeviation: a way back that never meets the route, or meets it before the pin, is a plain message', () => {
  const out = branch(4000, 1500);
  const pin = out.at(-1);
  assert.throws(() => planDeviation(route, { leaveKm: 4, pin, out, back: [pin, destinationPoint(pin, 0, 500)] }), /never meets the route/);
  assert.throws(() => planDeviation(route, { leaveKm: 4, pin: route.coordinateAtOffset(4100), out: [route.coordinateAtOffset(4000), route.coordinateAtOffset(4100)], back: [route.coordinateAtOffset(4100), route.coordinateAtOffset(4600)] }), UserError);
});

test('composeTrack: pieces must fit in order, with plain messages', () => {
  const dev = planDeviation(route, { leaveKm: 4, pin: branch(4000, 1500).at(-1), out: branch(4000, 1500), back: [branch(4000, 1500).at(-1), ...branch(6000, 1500).reverse(), route.coordinateAtOffset(6600)] });
  const end = planEnding(route, { end: branch(5000, 2000).at(-1), road: branch(5000, 2000), leaveKm: 5 });
  assert.throws(() => composeTrack(route, { startOffset: 1000, deviation: { ...dev, waitSeconds: 5 }, ending: end }), /before this deviation is over/, 'the ending leaves before the deviation is over');
  assert.throws(() => composeTrack(route, { startOffset: 5000, deviation: { ...dev, waitSeconds: 5 } }), /behind where the car starts/);
  assert.ok(composeTrack(route, { startOffset: 4000 - LEAVE_SLACK / 2, deviation: { ...dev, waitSeconds: 5 } }));
  assert.throws(() => composeTrack(route, { startOffset: 1000, deviation: { ...dev, mergeMain: 3000, waitSeconds: 1 } }), /behind the point where the car leaves/);
});

test('coordinates and lists are checked with plain words', () => {
  assert.deepEqual(coordIn({ latitude: 3, longitude: 101, extra: 1 }), { latitude: 3, longitude: 101 });
  for (const bad of [null, 5, {}, { latitude: NaN, longitude: 1 }, { latitude: '3', longitude: 1 }, { latitude: 91, longitude: 0 }, { latitude: 0, longitude: Infinity }]) {
    assert.throws(() => coordIn(bad, 'The pin'), (e) => e instanceof UserError && /^The pin needs a latitude and a longitude/.test(e.message));
  }
  assert.equal(coordsIn([{ latitude: 1, longitude: 1 }, { latitude: 2, longitude: 2 }]).length, 2);
  assert.throws(() => coordsIn([{ latitude: 1, longitude: 1 }]), /at least 2 points/);
  assert.throws(() => coordsIn('x'), UserError);
  assert.throws(() => coordsIn([{ latitude: 1, longitude: 1 }, { latitude: 'a', longitude: 2 }], 'The road'), /Point 2 of the road/);
  const many = Array.from({ length: MAX_POINTS + 1 }, () => ({ latitude: 1, longitude: 1 }));
  assert.throws(() => coordsIn(many), /too many points/);
  assert.equal(coordsIn(many.slice(1)).length, MAX_POINTS);
  assert.equal(optionalCoords(undefined), null);
  assert.equal(optionalCoords(null), null);
});

test('new cars take the next first name, car name and colour, distinct from the phones and each other', () => {
  const used = [{ label: 'Daniel', color: '#7C3AED' }, { label: 'Hafiz', color: '#0F766E' }];
  const seen = new Set(['#0a6cff', '#d9480f', '#7c3aed', '#0f766e']);
  for (let i = 0; i < 6; i++) {
    const c = nextCar(used, 3 + i);
    assert.ok(FIRST_NAMES.includes(c.label));
    assert.match(c.name, new RegExp(`^${c.label}’s [A-Za-z0-9]+$`));
    assert.ok(!seen.has(c.color.toLowerCase()), `${c.color} is new`);
    seen.add(c.color.toLowerCase());
    used.push(c);
  }
  assert.equal(nextCar([], 0).label, 'Mei Ling');
  assert.equal(nextCar([{ label: 'Mei Ling', color: PALETTE[0] }], 1).label, 'Arjun');
  assert.equal(new Set(PALETTE).size, PALETTE.length);
  assert.equal(carNameFor('Siti', 2), 'Siti’s Saga');
  assert.equal(nameIn('  Mei   Ling '), 'Mei Ling');
  for (const bad of ['', '   ', 5, 'x'.repeat(31)]) assert.throws(() => nameIn(bad), UserError);
});

test('events: type, category, severity and expiry are what the app writes (TripEvent.swift)', () => {
  assert.deepEqual(eventKindIn('debris', REPORT_TYPES, 'Type'), { type: 'debris', category: 'hazard', severity: 'high', expirySeconds: 2700 });
  assert.deepEqual(eventKindIn('heavyRain', REPORT_TYPES, 'Type'), { type: 'heavyRain', category: 'condition', severity: 'medium', expirySeconds: 3600 });
  assert.deepEqual(eventKindIn('stopFuel', STOP_TYPES, 'Type'), { type: 'stopFuel', category: 'stopRequest', severity: 'medium', expirySeconds: null });
  assert.equal(REPORT_TYPES.length, 11);
  assert.throws(() => eventKindIn('stopFuel', REPORT_TYPES, 'Type'), UserError);
  assert.throws(() => eventKindIn('nope', STOP_TYPES, 'Type'), /one of: stopRest/);
  assert.equal(Object.keys(EVENT_KINDS).length, 15);
});

test('a place for a stop answer is put on the route and has the validSuggestion shape', () => {
  const at = destinationPoint(route.coordinateAtOffset(7000), 90, 300);
  const p = placeOnRoute(route, { name: '  R&R Bidor ', ...at, junk: 1 });
  assert.deepEqual(Object.keys(p).sort(), ['latitude', 'longitude', 'name', 'routeOffset']);
  assert.equal(p.name, 'R&R Bidor');
  assert.ok(Math.abs(p.routeOffset - 7000) < 100);
  for (const bad of [null, { name: '', ...at }, { name: 'x'.repeat(101), ...at }, { name: 'A', latitude: NaN, longitude: 1 }]) assert.throws(() => placeOnRoute(route, bad), UserError);
});

test('what each car answered, as the card reads it', () => {
  assert.equal(voteAnswer({ agree: true }), 'yes');
  assert.equal(voteAnswer({ agree: false }), 'notNow');
  assert.equal(voteAnswer({ agree: false, answer: 'notNow', suggestion: { name: 'X' } }), 'another');
  assert.equal(voteAnswer({ agree: true, answer: 'yes', suggestion: { name: 'X' } }), 'yes');
  const keys = new Map([['c1', 'daniel'], ['c2', 'phone1']]);
  assert.deepEqual(answersByCar([{ id: 'c1', agree: true, answer: 'yes', suggestion: { name: 'Shell' } }, { id: 'c2', agree: false, answer: 'notNow' }, { id: 'zz', agree: true }], keys),
    { daniel: { answer: 'yes', place: 'Shell' }, phone1: { answer: 'notNow', place: null } });
  const now = 1_000_000;
  assert.equal(eventStatus({}, now), 'open');
  assert.equal(eventStatus({ status: 'pinned' }, now), 'pinned');
  assert.equal(eventStatus({ place: { name: 'x' } }, now), 'pinned');
  assert.equal(eventStatus({ status: 'closed' }, now), 'closed');
  assert.equal(eventStatus({ expiresAt: now - 1 }, now), 'closed');
  assert.equal(eventStatus({ expiresAt: now + 5 }, now), 'open');
  assert.equal(openStopSnapshot({ category: 'stopRequest' }, now), true);
  assert.equal(openStopSnapshot({ category: 'stopRequest', status: 'closed' }, now), false);
  assert.equal(openStopSnapshot({ category: 'stopRequest', expiresAt: { toMillis: () => now - 1 } }, now), false);
  assert.equal(openStopSnapshot({ category: 'hazard' }, now), false);
});

test('sliceFrom and straightRoad', () => {
  const line = new RouteLine(route.coordinates.slice(0, 50));
  const s = sliceFrom(line, 1000);
  assert.ok(haversine(s[0], line.coordinateAtOffset(1000)) < 0.01);
  assert.ok(Math.abs(new RouteLine(s).length - (line.length - 1000)) < 1);
  const a = route.coordinateAtOffset(0);
  const b = destinationPoint(a, 45, 1000);
  const r = straightRoad(a, b);
  assert.deepEqual(r.at(-1), b);
  assert.ok(Math.abs(new RouteLine(r).length - 1000) < 2);
});

test('a synthetic side road leaves the route where asked', () => {
  const r = sideRoad(route, 5000, 1000);
  assert.deepEqual(r[0], route.coordinateAtOffset(5000));
  assert.ok(Math.abs(haversine(r[0], r.at(-1)) - 1000) < 2);
  assert.ok(route.project(r.at(-1)).distance > 900);
  const right = sideRoad(route, 5000, 1000, { side: 90 });
  assert.ok(haversine(r.at(-1), right.at(-1)) > 1900, 'the other side');
});

test('a second deviation on the same car waits again', () => {
  const mk = (leave, id) => {
    const out = sideRoad(route, leave, 800);
    const back = [out.at(-1), ...sideRoad(route, leave + 1500, 800).reverse(), route.coordinateAtOffset(leave + 1900)];
    return { ...planDeviation(route, { leaveKm: leave / 1000, pin: out.at(-1), out, back }), waitSeconds: 10, id };
  };
  const one = composeTrack(route, { startOffset: 1000, deviation: mk(4000, 1) });
  let st = newCarState();
  for (let i = 0; i < 400 && !(st.served.has('wait1')); i++) st = stepTrack(one, st, 200, 1, true);
  assert.ok(st.served.has('wait1'), 'the first wait was served');
  for (let i = 0; i < 400 && locate(one, st.d, {}).phase !== 'onRoute'; i++) st = stepTrack(one, st, 200, 1, true);
  const two = composeTrack(route, { startOffset: 1000, deviation: mk(9000, 2) }); // the first deviation is over and cleared
  st = carryState(one, st, two);
  assert.equal(st.served.size, 0, 'the old wait is gone with its leg');
  assert.equal(nextWait(two, st).id, 'wait2');
  for (let i = 0; i < 400 && !st.waiting; i++) st = stepTrack(two, st, 200, 1, true);
  assert.equal(st.waiting.id, 'wait2', 'it stops and waits at the second pin');
});
