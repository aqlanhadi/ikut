import { test } from 'node:test';
import assert from 'node:assert/strict';
import { summarize } from './battery.mjs';

const min = 60_000;

test('drain per hour from first and last reading', () => {
  const s = summarize([{ t: 0, battery: 0.9 }, { t: 30 * min, battery: null }, { t: 60 * min, battery: 0.84 }]);
  assert.equal(s.startPct, 90);
  assert.equal(s.endPct, 84);
  assert.ok(Math.abs(s.drainPerHour - 6) < 1e-9);
});

test('no rate under 15 minutes of readings', () => {
  assert.equal(summarize([{ t: 0, battery: 0.9 }, { t: 10 * min, battery: 0.89 }]).drainPerHour, null);
});

test('silence over 60 s is a gap; 30 s heartbeats are not', () => {
  const s = summarize([{ t: 0 }, { t: 30_000 }, { t: 60_000 }, { t: 150_000 }].map((u) => ({ ...u, battery: null })));
  assert.deepEqual(s.gaps.map((g) => g.seconds), [90]);
});

test('silence since the last write is an open gap', () => {
  const s = summarize([{ t: 0, battery: 0.5 }], 5 * min);
  assert.equal(s.gaps.length, 1);
  assert.equal(s.gaps[0].open, true);
  assert.equal(s.gaps[0].seconds, 300);
});
