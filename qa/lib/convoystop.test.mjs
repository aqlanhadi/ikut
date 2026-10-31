import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CAP, MoveOff, RestTracker, current, mayStartOrEnd } from './convoystop.mjs';

// The cases of ios/ikutTests/ConvoyStopTests.swift (cap, who may, MoveOff) and the rest timer of StoppedBatteryTests.swift.

const trip = (stoppedAt, status = 'active') => ({ status, stoppedAt, stoppedBy: stoppedAt == null ? null : 'lead', stoppedEventId: stoppedAt == null ? null : 'e1' });
/** About `m` metres north of (3, 101). */
const spot = (m) => ({ latitude: 3 + m / 111_194.9, longitude: 101 });

test('the phase is on from We have stopped, off after Continue, an ended trip, and the 90 minute cap', () => {
  assert.deepEqual(current(trip(1000), 1060), { since: 1000, by: 'lead', eventId: 'e1' });
  assert.equal(current(trip(null), 1000), null);
  assert.equal(current(null, 1000), null);
  assert.equal(current(trip(1000, 'ended'), 1000), null);
  assert.notEqual(current(trip(1000), 1000 + CAP - 1), null);
  assert.equal(current(trip(1000), 1000 + CAP), null);
  assert.equal(CAP, 5400);
});

test('only the lead car and the organizer start or end it', () => {
  const table = [[false, false, false], [true, false, true], [false, true, true], [true, true, true]];
  for (const [isLeadTracker, isOrganizer, may] of table) assert.equal(mayStartOrEnd({ isLeadTracker, isOrganizer }), may);
});

const moveOff = (fixes) => {
  const w = new MoveOff();
  return fixes.map(([m, at, moving, phase = 0]) => w.check({ phase, here: spot(m), at, moving }));
};
const settled = [[0, 0, false], [10, 60, false], [5, 125, false]];

test('a settled lead car driving off more than 500 m ends the phase once', () => {
  assert.deepEqual(moveOff([...settled, [300, 200, true], [560, 230, true], [900, 260, true]]), [false, false, false, false, true, false]);
});

test('one coarse fix while parked never ends it; a car still rolling in does not either', () => {
  assert.ok(!moveOff([...settled, [700, 140, false], [0, 150, false], [450, 200, true]]).includes(true));
  assert.deepEqual(moveOff([[0, 0, true], [550, 30, true]]), [false, false]);
});

test('a red light short of the car park does not settle, and a mistaken stop ends at 2 km', () => {
  assert.ok(!moveOff([[0, 0, false], [0, 40, false], [300, 60, true], [600, 90, true]]).includes(true));
  assert.deepEqual(moveOff([[0, 0, true], [1500, 60, true], [2100, 80, true]]), [false, false, true]);
});

test('a new phase starts afresh and no phase forgets everything', () => {
  assert.deepEqual(moveOff([...settled, [600, 200, true], [600, 1800, false, 1800], [1200, 1830, true, 1800]]), [false, false, false, true, false, false]);
  assert.ok(!moveOff([...settled, [2000, 130, false, null], [2600, 140, true, null]]).includes(true));
});

// ---------------------------------------------------------------- RestTracker

function rig() {
  const log = [];
  const t = new RestTracker({ onPower: (low) => log.push(low) });
  return { t, log };
}
const rest = (m = 0) => ({ ...spot(m), speed: 0 });
const drive = (m) => ({ ...spot(m), speed: 25 });

test('a car at rest in a stopped phase drops to low power after 120 s, and Continue brings full back at once', () => {
  const { t, log } = rig();
  t.fix(rest(), 0);
  t.setConvoyStopped(true, 10);
  t.fix(rest(), 60);
  assert.deepEqual(log, []);
  t.fix(rest(3), 129); // 119 s into the phase
  assert.deepEqual(log, []);
  t.tick(130);
  assert.deepEqual(log, [true]);
  t.setConvoyStopped(false, 200);
  assert.deepEqual(log, [true, false]);
});

test('no low power without a stopped phase, however long it is at rest', () => {
  const { t, log } = rig();
  for (let s = 0; s < 600; s += 10) t.fix(rest(), s);
  assert.deepEqual(log, []);
});

test('in low power a fix that shows nothing new is not urgent, and a real move wakes it and is', () => {
  const { t, log } = rig();
  t.fix(rest(), 0);
  t.setConvoyStopped(true, 0);
  t.tick(120);
  assert.equal(t.fix(rest(20), 130), false);
  assert.equal(t.fix(rest(40), 140), false, 'inside the 100 m rest radius of where it rested');
  assert.equal(t.fix(drive(400), 150), true);
  assert.deepEqual(log, [true, false]);
  // The timer starts afresh from the move: not low again 100 s later.
  t.tick(250);
  assert.deepEqual(log, [true, false]);
  t.tick(271);
  assert.deepEqual(log, [true, false, true]);
});

test('a car still driving in is urgent and never settles while it keeps moving', () => {
  const { t, log } = rig();
  t.fix(drive(0), 0);
  t.setConvoyStopped(true, 0);
  for (let s = 10; s <= 300; s += 10) assert.equal(t.fix(drive(s * 25), s), true);
  assert.deepEqual(log, []);
});
