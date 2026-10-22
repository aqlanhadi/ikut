import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Polyline } from './route.mjs';
import {
  decodePolyline, measure, snapToRoute, pointAtOffset, sidePoint, limitPoints, roadKey, distance, placeAtCmd, endingCmd, deviateCmd, voteCmd, prepareStartsCmd,
  clampWait, endingOrigin, canMovePin, ghostOf, geometryChanges, stopPrompts, answerText, initialOf, badgeClasses, problemOwner, pickedPlaceName,
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
  assert.deepEqual(voteCmd('daniel', 'e1', 'notNow', { name: 'Here', lat: 3, lng: 101 }), { cmd: 'vote', car: 'daniel', event: 'e1', answer: 'notNow', place: { name: 'Here', latitude: 3, longitude: 101 } });
  assert.equal(voteCmd('daniel', 'e1', 'yes').place, undefined);
});

test('prepare starts: phone 2 follows phone 1 when it has no pin', () => {
  const a = { lat: 3, lng: 101 };
  const c = prepareStartsCmd(a, undefined, { skipBuild: true });
  assert.deepEqual(c.starts.phone2, c.starts.phone1);
  assert.equal(c.skipBuild, true);
});

test('endingOrigin: the car when on the route, the route at its offset otherwise', () => {
  assert.deepEqual(endingOrigin({ phase: 'onRoute', latitude: 3.0001, longitude: 101.02 }, route), { lat: 3.0001, lng: 101.02 });
  const p = endingOrigin({ phase: 'joining', latitude: 3.5, longitude: 101.5, offset: 2000 }, route);
  assert.ok(Math.abs(snapToRoute(route, p).offset - 2000) < 1);
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
    { id: 'e1', category: 'stopRequest', type: 'stopFuel', status: 'open', by: 'Phone 1', byKey: 'phone1', offset: 12000, answers: { g3: { answer: 'yes', place: null } }, agree: 1, disagree: 0, suggestions: [] },
    { id: 'e2', category: 'stopRequest', type: 'stopRest', status: 'closed', by: 'Daniel', byKey: 'daniel', answers: {} },
    { id: 'e3', category: 'hazard', type: 'debris', status: 'open', by: 'Daniel', byKey: 'daniel', answers: {} },
    { id: 'e4', category: 'stopRequest', type: 'stopFood', status: 'open', by: 'Daniel', byKey: 'daniel', answers: {}, agree: 0, disagree: 0 },
    { id: 'e5', category: 'stopRequest', type: 'stopToilet', status: 'pinned', by: 'Daniel', byKey: 'daniel', answers: {} },
  ],
});

test('stopPrompts: one card per open stop request, rows for joined generated cars', () => {
  const p = stopPrompts(state());
  assert.deepEqual(p.map((x) => x.id), ['e1', 'e4']);
  const e1 = p[0];
  assert.equal(e1.title, 'Fuel stop'); assert.equal(e1.fromPhone, true);
  assert.deepEqual(e1.rows.map((r) => [r.key, r.canAnswer, r.answer]), [['daniel', true, null], ['hafiz', false, null], ['g3', false, 'yes']]);
  assert.equal(e1.anyToAnswer, true);
  const e4 = p[1];
  assert.equal(e4.fromPhone, false);
  assert.deepEqual(e4.rows.map((r) => [r.key, r.asker, r.canAnswer]), [['daniel', true, false], ['hafiz', false, false], ['g3', false, true]]);
  assert.deepEqual(stopPrompts({ cars: [], events: [] }), []);
  assert.deepEqual(stopPrompts(null), []);
});

test('stopPrompts: the card is gone when the request is no longer open, and Everyone agrees has nothing to do once all answered', () => {
  const s = state();
  s.events[0].status = 'closed';
  assert.deepEqual(stopPrompts(s).map((x) => x.id), ['e4']);
  s.events[3].answers = { g3: { answer: 'notNow', place: null } };
  assert.equal(stopPrompts(s)[0].anyToAnswer, false);
});

test('answerText says it in plain words', () => {
  assert.equal(answerText({ asker: true }), 'asked');
  assert.equal(answerText({ offline: true, answer: null }), 'no signal');
  assert.equal(answerText({ answer: 'yes', place: null }), 'agrees');
  assert.equal(answerText({ answer: 'yes', place: 'Shell' }), 'agrees, Shell');
  assert.equal(answerText({ answer: 'another', place: 'R&R Tapah' }), 'suggests R&R Tapah');
  assert.equal(answerText({ answer: 'notNow' }), 'not now');
  assert.equal(answerText({ answer: null }), 'has not answered');
});

test('badges: initial, ring for phones, dashed while joining, faded with no signal', () => {
  assert.equal(initialOf('daniel'), 'D'); assert.equal(initialOf(''), '?');
  assert.equal(badgeClasses({ kind: 'phone', phase: 'onRoute' }), 'badge phone');
  assert.equal(badgeClasses({ kind: 'generated', phase: 'joining', offline: true }), 'badge joining offline');
  assert.equal(badgeClasses({ kind: 'generated', phase: 'onRoute' }), 'badge');
});

test('problemOwner: a problem right after a command belongs to that car', () => {
  assert.equal(problemOwner({ problem: 'x', problemAt: 10_500 }, { car: 'daniel', at: 10_000 }), 'daniel');
  assert.equal(problemOwner({ problem: 'x', problemAt: 1_000 }, { car: 'daniel', at: 10_000 }), null);
  assert.equal(problemOwner({ problem: null }, { car: 'daniel', at: 0 }), null);
  assert.equal(pickedPlaceName('Daniel'), 'Daniel’s pick');
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
