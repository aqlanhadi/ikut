import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Polyline } from './route.mjs';
import {
  decodePolyline, measure, snapToRoute, pointAtOffset, sidePoint, limitPoints, roadKey, distance, placeAtCmd, endingCmd, deviateCmd, voteCmd, stoppedCmd, prepareStartsCmd,
  clampWait, endingOrigin, canMovePin, ghostOf, geometryChanges, stopPrompts, answerText, initialOf, badgeClasses, problemOwner,
} from '../dashboard/page-logic.mjs';

// a straight 10 km road going east at latitude 3
const line = Array.from({ length: 11 }, (_, i) => ({ lat: 3, lng: 101 + i * 0.0090 }));
const route = measure(line);

test('decodePolyline reads what the playground encodes', () => {
  const coords = [{ latitude: 3.12345, longitude: 101.5 }, { latitude: 3.2, longitude: 101.41234 }, { latitude: 2.9, longitude: 101.9 }];
  const back = decodePolyline(Polyline.encode(coords));
  assert.deepEqual(back, coords.map((c) => ({ lat: c.latitude, lng: c.longitude })));
  assert.deepEqual(decodePolyline(''), []);
});

test('snapToRoute: offset along the route and distance from it', () => {
  const s = snapToRoute(route, { lat: 3.001, lng: 101.045 }); // about 111 m north of 5 km
  assert.ok(Math.abs(s.offset - 5000) < 30, `offset ${s.offset}`);
  assert.ok(Math.abs(s.distance - 111) < 5, `distance ${s.distance}`);
  assert.equal(snapToRoute(route, { lat: 3, lng: 100 }).offset, 0, 'before the start');
  assert.ok(Math.abs(snapToRoute(route, { lat: 3, lng: 102 }).offset - route.length) < 1e-6, 'after the end');
});

test('pointAtOffset and snapToRoute agree, and clamp to the ends', () => {
  const p = pointAtOffset(route, 3210);
  assert.ok(Math.abs(snapToRoute(route, p).offset - 3210) < 1);
  assert.deepEqual(pointAtOffset(route, -5), line[0]);
  assert.deepEqual(pointAtOffset(route, 1e9), line[10]);
});

test('sidePoint is that far from the route, to the left of a car driving east (north)', () => {
  const p = sidePoint(route, 4, 800);
  assert.ok(p.lat > 3, 'north of an eastbound road');
  assert.ok(Math.abs(snapToRoute(route, p).distance - 800) < 10);
  assert.ok(sidePoint(route, 4, -800).lat < 3);
});

test('limitPoints keeps the ends and the order', () => {
  const pts = Array.from({ length: 50000 }, (_, i) => ({ lat: i, lng: 0 }));
  const out = limitPoints(pts, 19000);
  assert.equal(out.length, 19000);
  assert.deepEqual(out[0], pts[0]);
  assert.deepEqual(out.at(-1), pts.at(-1));
  assert.ok(out.every((p, i) => i === 0 || p.lat > out[i - 1].lat));
  assert.equal(limitPoints(pts.slice(0, 5)).length, 5);
});

test('roadKey is the same for the same ends to a metre, and different for the reverse', () => {
  const a = { lat: 3.123456, lng: 101.5 }, b = { lat: 3.2, lng: 101.6 };
  assert.equal(roadKey(a, b), roadKey({ lat: 3.1234561, lng: 101.5 }, b));
  assert.notEqual(roadKey(a, b), roadKey(b, a));
});

test('commands carry road fields only when there is a road', () => {
  const a = { lat: 3, lng: 101 }, b = { lat: 3.1, lng: 101.1 };
  assert.deepEqual(placeAtCmd('daniel', a), { cmd: 'placeAt', car: 'daniel', start: { latitude: 3, longitude: 101 } });
  assert.deepEqual(placeAtCmd('daniel', a, []).road, undefined);
  assert.deepEqual(placeAtCmd('daniel', a, [a, b]).road, [{ latitude: 3, longitude: 101 }, { latitude: 3.1, longitude: 101.1 }]);
  assert.deepEqual(endingCmd('hafiz', b), { cmd: 'ending', car: 'hafiz', end: { latitude: 3.1, longitude: 101.1 } });
  assert.equal(endingCmd('hafiz', b, { leaveKm: 12.34567 }).leaveKm, 12.346);
  const d = deviateCmd('g3', b, { out: [a, b], waitSeconds: 45, leaveKm: 8 });
  assert.equal(d.waitSeconds, 45); assert.equal(d.leaveKm, 8); assert.ok(d.out); assert.equal(d.back, undefined);
  assert.equal(deviateCmd('g3', b).waitSeconds, 30);
  assert.equal(clampWait(9999), 600); assert.equal(clampWait(-4), 0); assert.equal(clampWait('x'), 30);
  assert.deepEqual(voteCmd('daniel', 'e1'), { cmd: 'vote', car: 'daniel', event: 'e1' });
  assert.deepEqual(stoppedCmd('e1'), { cmd: 'markStopped', event: 'e1' });
});

test('prepare starts: phone 2 follows phone 1 when it has no pin', () => {
  const a = { lat: 3, lng: 101 };
  const c = prepareStartsCmd(a, undefined, { skipBuild: true });
  assert.deepEqual(c.starts.phone2, c.starts.phone1);
  assert.equal(c.skipBuild, true);
});

test('endingOrigin: the car when on the route, the route at its offset otherwise', () => {
  assert.deepEqual(endingOrigin({ phase: 'onRoute', latitude: 3.0001, longitude: 101.02 }, route), { lat: 3.0001, lng: 101.02 });
  const p = endingOrigin({ phase: 'out', latitude: 3.5, longitude: 101.5, offset: 2000 }, route);
  assert.ok(Math.abs(snapToRoute(route, p).offset - 2000) < 1);
  const j = endingOrigin({ phase: 'joining', latitude: 3.5, longitude: 101.5, offset: 0, mergeKm: 6 }, route);
  assert.ok(Math.abs(snapToRoute(route, j).offset - 6000) < 1, 'where it merges');
});

test('canMovePin: an ending is fixed once the car is on it, a deviation once the car has left the route', () => {
  assert.ok(canMovePin({ phase: 'ending' }, 'start'));
  assert.ok(!canMovePin({ phase: 'ending' }, 'end'));
  assert.ok(canMovePin({ phase: 'out' }, 'end'));
  assert.ok(!canMovePin({ phase: 'out' }, 'deviation'));
  assert.ok(!canMovePin({ phase: 'waiting' }, 'deviation'));
  assert.ok(canMovePin({ phase: 'onRoute' }, 'deviation'));
});

test('ghostOf: only when the app has the car more than 500 m away', () => {
  const car = { latitude: 3, longitude: 101, reported: { latitude: 3.002, longitude: 101 } }; // 222 m
  assert.equal(ghostOf(car), null);
  const far = { ...car, reported: { latitude: 3.01, longitude: 101 } }; // 1.1 km
  assert.deepEqual(ghostOf(far), { lat: 3.01, lng: 101 });
  assert.equal(ghostOf({ ...car, reported: null }), null);
  assert.equal(ghostOf({ latitude: null, reported: { latitude: 3, longitude: 1 } }), null);
});

test('geometryChanges: only what changed is redrawn', () => {
  const geo = { version: 5, route: 'abc', cars: { daniel: { version: 2 }, hafiz: { version: 1 } } };
  assert.deepEqual(geometryChanges({ routeText: 'abc', cars: { daniel: 2, hafiz: 1 } }, null, geo), { route: false, cars: [], remove: [] });
  assert.deepEqual(geometryChanges({ routeText: 'abc', cars: { daniel: 1, hafiz: 1, g3: 4 } }, null, geo), { route: false, cars: ['daniel'], remove: ['g3'] });
  assert.deepEqual(geometryChanges({ routeText: null, cars: {} }, null, geo).cars, ['daniel', 'hafiz']);
  assert.equal(geometryChanges({ routeText: null, cars: {} }, null, geo).route, true);
});

const state = () => ({
  cars: [
    { key: 'phone1', label: 'Phone 1', kind: 'phone', joined: true },
    { key: 'daniel', label: 'Daniel', kind: 'generated', joined: true, color: '#7C3AED', offline: false },
    { key: 'hafiz', label: 'Hafiz', kind: 'generated', joined: true, color: '#0F766E', offline: true },
    { key: 'g3', label: 'Mei Ling', kind: 'generated', joined: true, color: '#c2255c', offline: false },
    { key: 'g4', label: 'Arjun', kind: 'generated', joined: false },
  ],
  events: [
    { id: 'e1', category: 'stopRequest', type: 'stopFuel', status: 'open', by: 'Phone 1', byKey: 'phone1', offset: 12000, message: 'Low on fuel, next R&R please', oks: { g3: true }, ok: 1 },
    { id: 'e2', category: 'stopRequest', type: 'stopRest', status: 'closed', by: 'Daniel', byKey: 'daniel', oks: {} },
    { id: 'e3', category: 'hazard', type: 'debris', status: 'open', by: 'Daniel', byKey: 'daniel', oks: {} },
    { id: 'e4', category: 'stopRequest', type: 'stopFood', status: 'open', by: 'Daniel', byKey: 'daniel', oks: {}, ok: 0 },
  ],
});

test('stopPrompts: one card per open stop request, rows for joined generated cars, OK per car', () => {
  const p = stopPrompts(state());
  assert.deepEqual(p.map((x) => x.id), ['e1', 'e4']);
  const e1 = p[0];
  assert.equal(e1.title, 'Fuel stop'); assert.equal(e1.fromPhone, true);
  assert.equal(e1.message, 'Low on fuel, next R&R please'); assert.equal(e1.okCount, 1);
  assert.deepEqual(e1.rows.map((r) => [r.key, r.canAnswer, r.ok]), [['daniel', true, false], ['hafiz', false, false], ['g3', false, true]]);
  assert.equal(e1.anyToAnswer, true);
  const e4 = p[1];
  assert.equal(e4.fromPhone, false); assert.equal(e4.message, null);
  assert.deepEqual(e4.rows.map((r) => [r.key, r.asker, r.canAnswer]), [['daniel', true, false], ['hafiz', false, false], ['g3', false, true]]);
  assert.deepEqual(stopPrompts({ cars: [], events: [] }), []);
  assert.deepEqual(stopPrompts(null), []);
});

test("stopPrompts: We've stopped is on the page only when a generated car with signal asked", () => {
  const p = stopPrompts(state());
  assert.equal(p[0].canStop, false); // a phone asked: tap it in the app
  assert.equal(p[1].canStop, true);
  const s = state();
  s.cars.find((c) => c.key === 'daniel').offline = true;
  assert.equal(stopPrompts(s)[1].canStop, false);
});

test('stopPrompts: the card is gone when the request is no longer open, and Everyone says OK has nothing to do once all did', () => {
  const s = state();
  s.events[0].status = 'closed';
  assert.deepEqual(stopPrompts(s).map((x) => x.id), ['e4']);
  s.events[3].oks = { g3: true };
  assert.equal(stopPrompts(s)[0].anyToAnswer, false);
});

test('answerText says it in plain words', () => {
  assert.equal(answerText({ asker: true }), 'asked');
  assert.equal(answerText({ offline: true, ok: false }), 'no signal');
  assert.equal(answerText({ ok: true }), 'OK');
  assert.equal(answerText({ ok: false }), 'waiting');
});

test('badges: initial, ring for phones, dashed while joining, faded with no signal', () => {
  assert.equal(initialOf('Phone 2'), '2'); assert.equal(initialOf('daniel'), 'D'); assert.equal(initialOf(''), '?');
  assert.equal(badgeClasses({ kind: 'phone', phase: 'onRoute' }), 'badge phone');
  assert.equal(badgeClasses({ kind: 'generated', phase: 'joining', offline: true }), 'badge joining offline');
  assert.equal(badgeClasses({ kind: 'generated', phase: 'onRoute' }), 'badge');
});

test('problemOwner: a problem right after a command belongs to that car', () => {
  assert.equal(problemOwner({ problem: 'x', problemAt: 10_500 }, { car: 'daniel', at: 10_000 }), 'daniel');
  assert.equal(problemOwner({ problem: 'x', problemAt: 1_000 }, { car: 'daniel', at: 10_000 }), null);
  assert.equal(problemOwner({ problem: null }, { car: 'daniel', at: 0 }), null);
  assert.equal(distance({ lat: 3, lng: 101 }, { lat: 3, lng: 101 }), 0);
});

import { defaultLeaveKm, straightDeviation } from '../dashboard/page-logic.mjs';

test('defaultLeaveKm: a km before the pin, but at least 150 m ahead of the car', () => {
  assert.equal(defaultLeaveKm(2000, 9000), 8);
  assert.equal(defaultLeaveKm(8800, 9000), 8.95);
  assert.equal(defaultLeaveKm(null, 500), 0.15);
});

test('straightDeviation: out to the pin, back to the route past it', () => {
  const pin = sidePoint(route, 5, 800);
  const { out, back } = straightDeviation(route, pin, 4);
  assert.ok(Math.abs(snapToRoute(route, out[0]).offset - 4000) < 5);
  assert.deepEqual(out[1], pin);
  assert.ok(Math.abs(snapToRoute(route, back[1]).offset - 6500) < 20);
});

import { seesStatus, ageText } from '../dashboard/page-logic.mjs';

test('seesStatus: joining is not a warning, a position gap or an old fix is', () => {
  const base = { joined: true, kind: 'generated', latitude: 3, longitude: 101, state: 'convoy', offset: 23000, trackMeters: { at: 1400, of: 5000 },
    reported: { offset: 6300, ageSeconds: 3, latitude: 3.0001, longitude: 101 } };
  assert.deepEqual(seesStatus(base), { text: 'The app has this car at 6.3 km, 3 s ago.', warn: false }, 'offsets are not compared');
  assert.deepEqual(seesStatus({ ...base, state: 'joining' }), { text: 'The app still has this car joining, 1.4 km along its own road.', warn: false });
  const far = seesStatus({ ...base, reported: { ...base.reported, latitude: 3.02 } });
  assert.equal(far.warn, true); assert.match(far.text, /2\.2 km from where it is/);
  const stale = seesStatus({ ...base, reported: { ...base.reported, ageSeconds: 75 } });
  assert.equal(stale.warn, true); assert.match(stale.text, /last heard from this car 75 s ago/);
  assert.equal(seesStatus({ ...base, reported: null }).warn, true);
  assert.equal(seesStatus({ ...base, joined: false }).warn, false);
  assert.equal(ageText(200), '3 min ago');
});

test('road coordinates go out rounded to 6 decimals', () => {
  const road = [{ lat: 3.123456789, lng: 101.987654321 }, { lat: 3.2, lng: 101.1 }];
  assert.deepEqual(placeAtCmd('daniel', road[0], road).road[0], { latitude: 3.123457, longitude: 101.987654 });
});

import { framePoints, shouldRefit } from '../dashboard/page-logic.mjs';

test('framePoints: the cars and the pins still ahead, never start pins', () => {
  const st = { cars: [
    { key: 'a', latitude: 3, longitude: 101, phase: 'onRoute', pins: { start: { latitude: 9, longitude: 9 }, end: null, deviation: null } },
    { key: 'b', latitude: 3.1, longitude: 101.1, phase: 'out', pins: { start: null, end: { latitude: 3.3, longitude: 101.3 }, deviation: { pin: { latitude: 3.2, longitude: 101.2 } } } },
    { key: 'c', latitude: 3.4, longitude: 101.4, phase: 'back', pins: { deviation: { pin: { latitude: 8, longitude: 8 } } } },
    { key: 'd', latitude: 3.5, longitude: 101.5, phase: 'arrived', pins: { end: { latitude: 3.5, longitude: 101.5 } } },
    { key: 'e', latitude: null, phase: null, pins: {} },
  ] };
  const pts = framePoints(st);
  assert.deepEqual(pts.map((p) => [p.lat, p.lng]), [[3, 101], [3.1, 101.1], [3.3, 101.3], [3.2, 101.2], [3.4, 101.4], [3.5, 101.5]]);
  assert.ok(!pts.some((p) => p.lat >= 8), 'no start pin, no driven-back deviation pin');
  assert.deepEqual(framePoints(null), []);
});

test('shouldRefit: when a point is out of view, or the points are small in it, at most every 4 s, within the zoom cap', () => {
  const view = { north: 4, south: 3, east: 102, west: 101 };
  const inside = [{ lat: 3.4, lng: 101.4 }, { lat: 3.8, lng: 101.9 }];
  const o = { zoom: 10, now: 100_000, lastFit: 0 };
  assert.equal(shouldRefit(inside, view, o), false, 'in view and big enough');
  assert.equal(shouldRefit([...inside, { lat: 5, lng: 101.5 }], view, o), true, 'one has left');
  const blob = [{ lat: 3.5, lng: 101.5 }, { lat: 3.52, lng: 101.52 }];
  assert.equal(shouldRefit(blob, view, o), true, 'a quarter of the view or less: zoom back in');
  assert.equal(shouldRefit(blob, view, { ...o, zoom: 15 }), false, 'already at the zoom cap');
  assert.equal(shouldRefit(blob, view, { ...o, lastFit: 98_000 }), false, 'fit 2 s ago');
  assert.equal(shouldRefit(blob, view, { ...o, lastFit: 98_000, force: true }), true);
  assert.equal(shouldRefit([], view, o), false);
  assert.equal(shouldRefit(blob, null, o), false);
});
