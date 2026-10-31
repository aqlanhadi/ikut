import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PositionPublisher } from './tracking.mjs';

// The low-power cases of ios/ikutTests/StoppedBatteryTests.swift (LowPowerPublisherTests).

const flush = () => new Promise((resolve) => setImmediate(resolve));

function rig({ refresh = null } = {}) {
  let t = 1000;
  const written = [];
  const state = { fail: 0 };
  const p = new PositionPublisher({
    now: () => t,
    refresh,
    write: async (position) => {
      written.push(position);
      if (state.fail > 0) { state.fail -= 1; throw new Error('refused'); }
    },
  });
  const advance = async (seconds) => { t += seconds; p.tick(); await flush(); };
  return { p, written, advance, state };
}

test('low power heartbeat is 45 s whatever the speed', async () => {
  const { p, written, advance } = rig();
  p.submit({ lon: 1, speed: 20 });
  await flush();
  p.setLowPower(true);
  await advance(44);
  assert.equal(written.length, 1);
  await advance(1.5);
  assert.equal(written.length, 2);
  await advance(45);
  assert.equal(written.length, 3);
});

test('a fix that shows nothing new waits for the heartbeat; one that moved goes after the min interval', async () => {
  const { p, written, advance } = rig();
  p.submit({ lon: 1, speed: 0 });
  await flush();
  p.setLowPower(true);
  await advance(6);
  p.submit({ lon: 2, speed: 0 }, { urgent: false });
  await advance(30);
  assert.equal(written.length, 1);
  await advance(10);
  assert.equal(written.length, 2);
  assert.equal(written[1].lon, 2);
  await advance(6);
  p.submit({ lon: 3, speed: 0 }, { urgent: true });
  await flush();
  assert.equal(written.length, 3);
});

test('leaving low power re-plans the write at the moving interval', async () => {
  const { p, written, advance } = rig();
  p.submit({ lon: 1, speed: 20 });
  await flush();
  p.setLowPower(true);
  await advance(20);
  p.setLowPower(false);
  await advance(0.5);
  assert.equal(written.length, 2);
});

test('a failed heartbeat is retried after 5 s, not another heartbeat', async () => {
  const { p, written, advance, state } = rig();
  p.submit({ lon: 1, speed: 0 });
  await flush();
  p.setLowPower(true);
  state.fail = 1;
  await advance(46);
  assert.equal(written.length, 2);
  await advance(4);
  assert.equal(written.length, 2);
  await advance(1.5);
  assert.equal(written.length, 3);
});

test('a heartbeat carries the battery of the moment', async () => {
  let level = 0.8;
  const { p, written, advance } = rig({ refresh: (old) => ({ ...old, battery: level }) });
  p.submit({ lon: 1, speed: 0, battery: 0.8 });
  await flush();
  level = 0.5;
  await advance(31);
  assert.equal(written.length, 2);
  assert.equal(written[1].battery, 0.5);
});
