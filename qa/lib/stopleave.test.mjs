import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isOpen, leavingAt, nextStop } from './stopleave.mjs';

const stop = (name, routeOffset, extra = {}) => ({ name, routeOffset, kind: 'fuel', minutes: 20, ...extra });

// The same cases as ios/ikutTests/StopLeaveTests.swift.
test('a left or skipped stop is not open', () => {
  assert.equal(isOpen(stop('a', 1)), true);
  assert.equal(isOpen(stop('a', 1, { leftAt: 5 })), false);
  assert.equal(isOpen(stop('a', 1, { skipped: true })), false);
});

test('next stop moves on once a stop is left, even beside it', () => {
  const left = stop('Tapah', 10_000, { leftAt: 1 });
  const next = stop('Ipoh', 30_000);
  assert.equal(nextStop([left, next], 10_050).name, 'Ipoh');
  assert.equal(nextStop([stop('Tapah', 10_000), next], 10_050).name, 'Tapah');
  assert.equal(nextStop([left], 10_050), null);
  assert.equal(nextStop([stop('Passed', 1_000), next], 5_000).name, 'Ipoh');
});

test('leaving at is the arrival plus the planned length; a meeting point has its meet time', () => {
  assert.equal(leavingAt(stop('a', 1, { arrivedAt: 1_000_000 })), 1_000_000 + 20 * 60_000);
  assert.equal(leavingAt(stop('a', 1)), null);
  assert.equal(leavingAt(stop('a', 1, { minutes: undefined, arrivedAt: 1 })), null);
  assert.equal(leavingAt({ kind: 'meet', routeOffset: 0, meetAt: { toMillis: () => 42 }, arrivedAt: 9 }), 42);
  assert.equal(leavingAt({ kind: 'meet', routeOffset: 0 }), null);
});
