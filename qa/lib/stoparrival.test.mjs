import { test } from 'node:test';
import assert from 'node:assert/strict';
import { status, tally } from './stoparrival.mjs';

// The same cases as ios/ikutTests/StopArrivalTests.swift: a stop 20 km north of (3, 101).
const M = 111_195; // meters per degree of latitude (close enough for the 150 m edges)
const target = { latitude: 3 + 20_000 / M, longitude: 101, routeOffset: 20_000, isMeeting: false };
const at = (meters) => ({ latitude: 3 + meters / M, longitude: 101 });
const car = (id, offset, extra = {}) => ({ id, number: Number(id.slice(1)), location: at(extra.along ?? offset), offset, age: 5, speed: 25, ...extra });

test('here within 150 m either side, not beyond', () => {
  for (const o of [19_851, 19_900, 20_000, 20_149]) assert.equal(status(car('c1', o), target).kind, 'here', String(o));
  for (const o of [19_800, 20_200]) assert.equal(status(car('c1', o), target).kind, 'away', String(o));
});

test('a stale fix is never here, however close', () => {
  assert.equal(status(car('c1', 20_000, { age: 61 }), target).kind, 'lastSeenHere');
  assert.equal(status(car('c1', 17_000, { age: 300 }), target).kind, 'away');
  assert.equal(status(car('c1', 20_000, { age: 60 }), target).kind, 'here');
  assert.equal(status(car('c1', 20_000, { age: null }), target).kind, 'here');
});

test('minutes away from the offset and the pace, else the car own speed', () => {
  assert.deepEqual(status(car('c1', 17_000), target, { pace: 0.06 }), { kind: 'away', distance: 3000, seconds: 180 });
  assert.deepEqual(status(car('c1', 17_000), target), { kind: 'away', distance: 3000, seconds: 120 });
});

test('a joining car at the meeting point: its time to merge; here within 150 m with no offset', () => {
  const meet = { ...target, routeOffset: 0, isMeeting: true };
  const far = car('c3', null, { along: 11_000, timeToMerge: 420 });
  const s = status(far, meet, { pace: 0.04 });
  assert.equal(s.seconds, 420);
  assert.ok(Math.abs(s.distance - 9000) < 20);
  assert.equal(status(car('c3', null, { along: 19_900 }), meet).kind, 'here');
  assert.equal(status({ id: 'c3' }, meet).kind, 'unknown');
});

test('3 of 4 here counts every car once, joining ones too, by badge number', () => {
  const t = tally(target, [
    car('c4', 18_000), car('c1', 20_000), car('c3', null, { along: 20_030 }), car('c2', 19_920),
  ], { pace: 0.06 });
  assert.equal(t.title, '3 of 4 here');
  assert.deepEqual(t.rows.map((r) => r.id), ['c1', 'c2', 'c3', 'c4']);
  assert.equal(t.rows[3].status.seconds, 120);
});
