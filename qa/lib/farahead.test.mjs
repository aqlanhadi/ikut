import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CatchUpHeadsUp, carPhrase, catchUpSpoken, driftedGaps, entries, referenceId, relativeDistance, spokenStopRequest, togetherPairs } from './farahead.mjs';

// The same cases as ios/ikutTests/FarAheadTests.swift. Offsets in meters, speeds in m/s.
const car = (id, offset, speed, extra = {}) => ({ id, name: `${id}’s Myvi`, offset, speed, age: 2, ...extra });
const daniel = (offset = 38_000) => car('Daniel', offset, 0);

test('a car parked far ahead: arrival from the lead, no separation warning about it', () => {
  const convoy = entries([daniel(), car('Aisha', 1000, 27, { isLead: true }), car('Wyna', 800, 27)]);
  assert.equal(referenceId(convoy), 'Aisha');
  const together = togetherPairs(convoy);
  assert.deepEqual(driftedGaps(convoy, together), []);
});

test('the lead not tracking: arrival from the car with most cars around it', () => {
  const convoy = entries([daniel(), car('Aisha', 1000, 27, { isLead: true, age: 300 }), car('Wyna', 800, 27), car('Hafiz', 600, 27)]);
  assert.equal(referenceId(convoy), 'Hafiz'); // Wyna and Hafiz each have one car within 2 km; the one further back wins
  const two = entries([daniel(), car('Aisha', 1000, 27, { isLead: true, age: 300 }), car('Wyna', 800, 27)]);
  assert.equal(referenceId(two), 'Wyna');
});

test('cars that left together and drift 6 km apart: warned', () => {
  let together = new Set();
  const start = entries([car('Aisha', 1000, 27, { isLead: true }), car('Wyna', 800, 27)]);
  together = new Set([...together, ...togetherPairs(start)]);
  const later = entries([car('Aisha', 7800, 27, { isLead: true }), car('Wyna', 1800, 27)]);
  together = new Set([...together, ...togetherPairs(later)]);
  assert.deepEqual(driftedGaps(later, together), ['Wyna']);
});

test('the lead coming up to two parked cars: no warning about the gap between them', () => {
  const start = entries([car('Aisha', 10_000, 27, { isLead: true }), car('Wyna', 9200, 27), car('Daniel', 28_000, 0), car('Sam', 24_000, 0)]);
  let together = togetherPairs(start);
  const later = entries([car('Aisha', 23_000, 27, { isLead: true }), car('Wyna', 22_200, 27), car('Daniel', 28_000, 0), car('Sam', 24_000, 0)]);
  together = new Set([...together, ...togetherPairs(later)]);
  assert.ok(together.has('Aisha|Daniel'));
  assert.deepEqual(driftedGaps(later, together), []);
});

test('everyone far apart: no warnings until cars that were together part', () => {
  const far = entries([car('Aisha', 30_000, 27, { isLead: true }), car('Wyna', 18_000, 27), car('Hafiz', 6000, 27)]);
  assert.equal(referenceId(far), 'Aisha');
  assert.deepEqual(driftedGaps(far, togetherPairs(far)), []);
});

test('an arrived car is never the reference; no fresh car, no reference', () => {
  const convoy = entries([car('Hafiz', 90_000, 0, { arrived: true }), car('Wyna', 1000, 27), car('Faiz', 900, 27)]);
  assert.equal(referenceId(convoy), 'Faiz');
  assert.equal(referenceId(entries([car('Aisha', 1000, 27, { isLead: true, age: 300 })])), null);
});

test('stop request words: over 2 km says how far, closer stays plain', () => {
  assert.equal(relativeDistance(-40_000), '40 km behind');
  assert.equal(relativeDistance(12_300), '12 km ahead');
  assert.equal(relativeDistance(-2900), '2.9 km behind');
  assert.equal(relativeDistance(-1500), null);
  assert.equal(spokenStopRequest('stopFuel', 'Wyna', relativeDistance(-40_000)), 'Wyna needs fuel, 40 km behind. Tap OK.');
  assert.equal(spokenStopRequest('stopFuel', 'Wyna', relativeDistance(-1500)), 'Wyna needs fuel. Tap OK.');
});

test('heads-up: once, about 2 minutes before the next moving car reaches the parked one', () => {
  const h = new CatchUpHeadsUp();
  const at = (aisha) => entries([daniel(), car('Aisha', aisha, 27.8, { isLead: true }), car('Wyna', aisha - 200, 27.8)]);
  assert.equal(h.check(at(20_000), 'Daniel'), null); // 18 km, 10 min away
  const due = h.check(at(38_000 - 3300), 'Daniel');
  assert.equal(due?.carId, 'Aisha');
  assert.ok(due.seconds <= 120 && due.seconds > 110);
  assert.equal(catchUpSpoken(due), 'Aisha’s car is 3.3 km behind you.');
  assert.equal(h.check(at(38_000 - 2000), 'Daniel'), null); // once
});

test('heads-up: once per stop, again after driving on', () => {
  const h = new CatchUpHeadsUp();
  const at = (aisha, d, speed = 0) => entries([car('Daniel', d, speed), car('Aisha', aisha, 25, { isLead: true }), car('Wyna', aisha - 200, 25)]);
  assert.equal(h.check(at(20_000, 38_000), 'Daniel'), null);
  assert.equal(h.check(at(35_100, 38_000), 'Daniel')?.stop, 1);
  assert.equal(h.check(at(37_900, 38_300), 'Daniel'), null); // GPS wander at the stop
  assert.equal(h.check(at(40_000, 40_200, 25), 'Daniel'), null); // drives on: re-armed
  assert.equal(h.check(at(75_000, 90_000), 'Daniel'), null);
  assert.equal(h.check(at(87_100, 90_000), 'Daniel')?.stop, 2);
  assert.equal(h.check(at(88_000, 90_000), 'Daniel'), null);
});

test('heads-up: quiet when the car behind was never seen far, or my car is moving', () => {
  const h = new CatchUpHeadsUp();
  assert.equal(h.check(entries([daniel(), car('Aisha', 38_000 - 1000, 27.8)]), 'Daniel'), null);
  const moving = entries([car('Daniel', 38_000, 25), car('Aisha', 20_000, 27.8)]);
  assert.equal(CatchUpHeadsUp.nearestBehind(moving, 'Daniel'), null);
  // A parked car behind is skipped: the one timed is the nearest still driving.
  const parkedBehind = entries([daniel(), car('Mei', 36_000, 0), car('Aisha', 20_000, 27.8)]);
  assert.equal(CatchUpHeadsUp.nearestBehind(parkedBehind, 'Daniel')?.carId, 'Aisha');
  assert.equal(carPhrase('Red Myvi'), 'Red Myvi');
});
