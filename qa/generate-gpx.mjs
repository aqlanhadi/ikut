#!/usr/bin/env node
// Generates the GPX tracks in qa/gpx/ from the main route.
//
//   node generate-gpx.mjs            offline: uses data/osrm-*.json (committed snapshots)
//   node generate-gpx.mjs --fetch    refreshes the snapshots from the public OSRM demo server first
//
// The main route is the real E1 (North-South Expressway) from just south of Bidor to Ipoh, as OSRM
// routes it; Car 4's own route is Tapah town to Ipoh, which leaves the old road and joins the E1 at
// the Tapah ramp. Both are stored the way the app stores them (precision-5 polyline) by convoy-sim.mjs.
// Output is deterministic: noise comes from a seeded generator.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { RouteLine, haversine } from './lib/route.mjs';
import { writeGpx } from './lib/gpx.mjs';
import { CARS, CAR4_START, loadRoutes, toLine, DURATION, FIX_HZ, GPX_EPOCH, SPEED_WOBBLE, TRIP, PARKED_CARS, STOP_CARS, WOBBLE_PERIOD } from './lib/scenario.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const dataDir = path.join(here, 'data');
const gpxDir = path.join(here, 'gpx');
const OSRM = 'https://router.project-osrm.org/route/v1/driving';


async function osrm(from, to) {
  const url = `${OSRM}/${from.longitude},${from.latitude};${to.longitude},${to.latitude}?overview=full&geometries=geojson`;
  const res = await fetch(url);
  const json = await res.json();
  if (json.code !== 'Ok') throw new Error(`OSRM ${json.code} for ${url}`);
  const r = json.routes[0];
  return { source: url, fetchedAt: new Date().toISOString(), distance: r.distance, coordinates: r.geometry.coordinates };
}

async function fetchSnapshots() {
  const dest = TRIP.destination;
  // Sungkai E1 entry -> Ipoh, to get the expressway geometry, then keep it from 12 km on (just south of Bidor).
  const sungkai = { latitude: 3.9918, longitude: 101.3189 };
  const long = await osrm(sungkai, dest);
  const longLine = new RouteLine(toLine(long.coordinates));
  const start = longLine.coordinateAtOffset(12_000);
  const main = await osrm(start, dest);
  fs.writeFileSync(path.join(dataDir, 'osrm-main.json'), JSON.stringify(main));
  const car4 = await osrm(CAR4_START, dest);
  fs.writeFileSync(path.join(dataDir, 'osrm-car4.json'), JSON.stringify(car4));
  console.log(`fetched main ${(main.distance / 1000).toFixed(1)} km, car4 ${(car4.distance / 1000).toFixed(1)} km`);
}

// ---------------------------------------------------------------- deterministic noise

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function gaussian(rand) {
  return Math.sqrt(-2 * Math.log(1 - rand())) * Math.cos(2 * Math.PI * rand());
}

/** Smooth lateral error, about 2 m standard deviation (GPS noise on an open road). */
function noiseSource(seed) {
  const rand = mulberry32(seed);
  let e = 0;
  let n = 0;
  return () => {
    e = 0.9 * e + 0.44 * gaussian(rand) * 2;
    n = 0.9 * n + 0.44 * gaussian(rand) * 2;
    return { e, n };
  };
}

function jitter(coord, { e, n }) {
  const dLat = (n / 6_371_008.8) * (180 / Math.PI);
  const dLng = (e / (6_371_008.8 * Math.cos((coord.latitude * Math.PI) / 180))) * (180 / Math.PI);
  return { latitude: coord.latitude + dLat, longitude: coord.longitude + dLng };
}

// ---------------------------------------------------------------- motion models

const wobble = (car, t) => SPEED_WOBBLE * Math.sin((2 * Math.PI * t) / WOBBLE_PERIOD + (car.phase ?? 0));

/** Offset along the main route at time t for a car that holds `speed`. Integrates the wobble in closed form. */
function mainOffsetAt(car, t) {
  const w = (2 * Math.PI) / WOBBLE_PERIOD;
  const phase = car.phase ?? 0;
  const integral = (SPEED_WOBBLE / w) * (Math.cos(phase) - Math.cos(w * t + phase));
  return car.startOffset + car.speed * t + integral;
}

/**
 * A car parked on the main route ahead of the convoy (D26): parked at car.waitOffset until car 1 (the front) has passed it by
 * car.departAfter, then pulling out behind it at 1.5 m/s² up to car.speed. Returns {offsetAt(t), departAt}.
 */
function waitMotion(car) {
  const front = CARS.find((c) => c.key === 'car1');
  let departAt = DURATION + 1;
  for (let t = 0; t <= DURATION; t += 0.05) {
    if (mainOffsetAt(front, t) >= car.waitOffset + car.departAfter) { departAt = t; break; }
  }
  const accel = 1.5;
  const rampTime = car.speed / accel;
  const offsetAt = (t) => {
    const tau = Math.max(0, t - departAt);
    const run = tau < rampTime ? 0.5 * accel * tau * tau : 0.5 * accel * rampTime * rampTime + car.speed * (tau - rampTime);
    return car.waitOffset + run;
  };
  return { offsetAt, departAt };
}

/**
 * Car 4: distance along [own route up to the merge point] then the main route.
 * Returns {distanceAt(t), mergeTime, departAt}. Departure is solved so the car reaches the merge at car.mergeAt.
 */
function car4Motion(car, ownToMerge) {
  const run = (departAt) => {
    const dt = 0.05;
    const samples = [];
    let s = 0;
    let v = 0;
    let mergeTime = null;
    for (let t = 0; t <= DURATION + 1; t += dt) {
      samples.push(s);
      if (t >= departAt) {
        const remaining = ownToMerge - s;
        let target = car.ownCruise;
        if (s >= ownToMerge) target = car.mainSpeed;
        else if (remaining <= 400) target = car.mainSpeed;
        const a = v < target ? (s < ownToMerge && remaining <= 400 ? 0.65 : 1.5) : -2;
        v = a > 0 ? Math.min(target, v + a * dt) : Math.max(target, v + a * dt);
        s += v * dt;
        if (mergeTime === null && s >= ownToMerge) mergeTime = t;
      }
    }
    return { samples, mergeTime, dt };
  };
  let lo = 0;
  let hi = car.mergeAt;
  for (let i = 0; i < 40; i++) {
    const mid = (lo + hi) / 2;
    const r = run(mid);
    if (r.mergeTime === null || r.mergeTime > car.mergeAt) hi = mid; else lo = mid;
  }
  const departAt = (lo + hi) / 2;
  const r = run(departAt);
  return { departAt, mergeTime: r.mergeTime, distanceAt: (t) => r.samples[Math.min(r.samples.length - 1, Math.round(t / r.dt))] };
}

// ---------------------------------------------------------------- main

function isoAt(t) {
  return new Date(Date.parse(GPX_EPOCH) + t * 1000).toISOString().replace('.000Z', 'Z');
}

async function main() {
  if (process.argv.includes('--fetch')) await fetchSnapshots();
  fs.mkdirSync(gpxDir, { recursive: true });
  const { mainCoords, car4Coords } = loadRoutes();
  const main = new RouteLine(mainCoords);
  const own = new RouteLine(car4Coords);
  const merge = main.mergeOffset(own);
  if (!merge) throw new Error('car 4 route never joins the main route');
  console.log(`main route ${(main.length / 1000).toFixed(1)} km; car 4 own route ${(own.length / 1000).toFixed(1)} km, joins main at ${merge.mainOffset.toFixed(0)} m (own offset ${merge.otherOffset.toFixed(0)} m)`);

  const truth = {}; // key -> [{t, coord}] true (noise-free) positions, for the gap report
  const summary = [];

  for (const car of [...CARS, ...PARKED_CARS, ...STOP_CARS]) {
    const rand = noiseSource(car.key.length * 7919 + car.key.charCodeAt(car.key.length - 1));
    const points = [];
    const trueAt = [];
    let motion = null;
    if (car.kind === 'merge') motion = car4Motion(car, merge.otherOffset);
    const waiting = car.waitOffset !== undefined ? waitMotion(car) : null;

    for (let t = 0; t <= DURATION; t += 1 / FIX_HZ) {
      let coord;
      if (car.kind === 'merge') {
        const s = motion.distanceAt(t);
        coord = s <= merge.otherOffset
          ? own.coordinateAtOffset(s)
          : main.coordinateAtOffset(Math.min(merge.mainOffset + (s - merge.otherOffset), car.stopAt ?? Infinity));
      } else if (waiting) {
        coord = main.coordinateAtOffset(waiting.offsetAt(t));
      } else {
        coord = main.coordinateAtOffset(Math.min(mainOffsetAt(car, t), car.stopAt ?? Infinity));
      }
      trueAt.push({ t, coord });
      if (car.gap && t > car.gap.from && t < car.gap.to) continue;
      // The app car is a simulated GPS fed by simctl: no noise, so its offsets are exactly reproducible.
      // A parked car is noise-free too: parked, GPS jitter alone would read as creeping along.
      const atStop = car.stopAt !== undefined && t > 0 && trueAt.length > 1 && haversine(coord, trueAt[trueAt.length - 2].coord) < 0.01;
      const noisy = car.kind === 'app' || waiting || atStop ? coord : jitter(coord, rand());
      points.push({ ...noisy, ele: 60, time: isoAt(t) });
    }
    truth[car.gpx ?? car.key] = trueAt;
    const desc = [
      `ikut QA scenario, ${car.key}.`,
      waiting ? `Parked on the main route at ${car.waitOffset} m, drives on at t=${waiting.departAt.toFixed(0)} s at about ${(car.speed * 3.6).toFixed(0)} km/h.` : '',
      !waiting && (car.kind === 'main' || car.kind === 'app') ? `Main route from ${car.startOffset} m at about ${(car.speed * 3.6).toFixed(0)} km/h.` : '',
      car.kind === 'merge' ? `Starts in Tapah town, departs at t=${motion.departAt.toFixed(0)} s, reaches the Tapah ramp merge at t=${motion.mergeTime.toFixed(0)} s.` : '',
      car.stopAt !== undefined ? `Pulls in at the planned stop ${car.stopAt} m along the main route and parks.` : '',
      car.gap ? `Signal drop: no fixes between t=${car.gap.from} s and t=${car.gap.to} s (${car.gap.to - car.gap.from} s).` : '',
      `1 Hz, ${DURATION} s, start ${GPX_EPOCH}.`,
    ].filter(Boolean).join(' ');
    writeGpx(path.join(gpxDir, `${car.gpx ?? car.key}.gpx`), { name: `${car.gpx ?? car.key} ${car.name}`, desc, points });
    summary.push(`${car.key}: ${points.length} points${car.gap ? `, gap ${car.gap.from}-${car.gap.to} s` : ''}${motion ? `, departs ${motion.departAt.toFixed(0)} s, merges ${motion.mergeTime.toFixed(0)} s` : ''}${waiting ? `, waits at ${waiting.offsetAt(0)} m, drives on at ${waiting.departAt.toFixed(0)} s` : ''}`);
  }

  // Reference tracks: the routes themselves.
  const routePoint = (c, i) => ({ ...c, ele: 60, time: isoAt(i) });
  writeGpx(path.join(gpxDir, 'route-main.gpx'), { name: 'Main route (E1, Bidor to Ipoh)', desc: 'Reference polyline, one point per vertex; the time stamps are not meaningful.', points: mainCoords.map(routePoint) });
  writeGpx(path.join(gpxDir, 'route-car4-own.gpx'), { name: 'Car 4 own route (Tapah town to Ipoh)', desc: 'Reference polyline as routed; the app stores it only up to 500 m past the merge.', points: car4Coords.map(routePoint) });

  console.log(summary.join('\n'));

  // Gap report: true gaps between neighbours in the convoy, on the main route, to prove the 500-1500 m spacing.
  const mainCars = CARS.filter((c) => c.kind === 'main');
  let min = Infinity;
  let max = 0;
  for (let t = 0; t <= DURATION; t += 10) {
    const offs = mainCars.map((c) => mainOffsetAt(c, t)).sort((a, b) => b - a);
    for (let i = 1; i < offs.length; i++) { min = Math.min(min, offs[i - 1] - offs[i]); max = Math.max(max, offs[i - 1] - offs[i]); }
  }
  console.log(`cars 1-3 spacing over the drive: ${min.toFixed(0)} to ${max.toFixed(0)} m`);
  if (min < 500 || max > 1500) throw new Error('cars 1-3 spacing left the 500-1500 m band');
  void haversine;
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
