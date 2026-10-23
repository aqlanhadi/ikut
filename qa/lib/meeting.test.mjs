import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CarRouteLogic, RouteLine } from './route.mjs';
import { PositionBuilder } from './tracking.mjs';

// The same case as CarRouteServiceTests.aCarComingInOnTheOtherCarriagewayJoinsOnlyAtTheMeetingPoint (ios/ikutTests/CarRouteTests.swift).
const R = 6_371_008.8;
const origin = { latitude: 3.0, longitude: 101.0 };
const move = (c, north = 0, east = 0) => ({
  latitude: c.latitude + (north / R) * (180 / Math.PI),
  longitude: c.longitude + (east / (R * Math.cos((c.latitude * Math.PI) / 180))) * (180 / Math.PI),
});
const main = new RouteLine(Array.from({ length: 201 }, (_, i) => move(origin, 0, i * 500)));
const road = [move(origin, 5000, 20000)];
for (let i = 1; i <= 10; i++) { const t = i / 10; road.push(move(origin, 5000 * (1 - t) - 35 * t, 20000 - 5000 * t)); }
for (let e = 14500; e >= 0; e -= 500) road.push(move(origin, -35, e));
const own = new RouteLine(road);

test('a road to the meeting point joins at its end, not where it first runs beside the route', () => {
  const meet = main.meetingMerge(own);
  assert.ok(Math.abs(meet.otherOffset - own.length) < 1);
  assert.equal(meet.mainOffset, 0);
  assert.ok(main.mergeOffset(own).otherOffset < own.length - 10_000);
  const plan = CarRouteLogic.makePlan(road, main, true);
  assert.equal(plan.state, 'joining');
  assert.equal(plan.mergeOffset, 0);
});

test('without a meeting point makePlan is what it was', () => {
  const plan = CarRouteLogic.makePlan(road, main);
  assert.ok(plan.mergeOffset > 14_000 && plan.mergeOffset < 16_000);
});

test('PositionBuilder has no convoy offset on that road until the car is at the meeting point', () => {
  const b = new PositionBuilder(main, own);
  for (let off = 0; off < own.length - 100; off += 500) {
    const c = own.coordinateAtOffset(off);
    const pos = b.build({ latitude: c.latitude, longitude: c.longitude, speed: 20, course: 270 });
    assert.equal(pos.convoyOffset ?? null, null, `convoyOffset at ${off}`);
  }
  const end = b.build({ latitude: origin.latitude, longitude: origin.longitude, speed: 20, course: 270 });
  assert.notEqual(end.convoyOffset ?? null, null);
});
