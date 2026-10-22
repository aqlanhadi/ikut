#!/usr/bin/env node
// Drives a simulator along a real trip's main route, so one app can go from the lobby to the destination:
//
//   node drive-trip.mjs                  # newest active trip in the emulators, 90 km/h, simulator C0A40D2A
//   node drive-trip.mjs Y5REFN --kmh 110 --speed 4
//   node drive-trip.mjs Y5REFN --gpx out.gpx   # write a timed GPX instead (Xcode > Debug > Simulate Location on a phone)
//
// Reads the trip from the Firestore emulator as the owner (no sign-in, rules bypassed). Options: --kmh N (default 90),
// --speed N (time multiplier), --from N (start N km along), --udid, --host (emulator host, default 127.0.0.1),
// --route <encoded polyline> (skip Firestore, e.g. for a production trip).
// Ctrl-C stops and clears the simulated location.

import { spawn, spawnSync } from 'node:child_process';
import { writeGpx } from './lib/gpx.mjs';
import { holdSimulators, simctl } from './lib/shell.mjs';
import { Polyline, haversine } from './lib/route.mjs';

const o = { udid: 'C0A40D2A-0607-4B95-A1BE-F8C9190D81C1', kmh: 90, speed: 1, from: 0, host: '127.0.0.1', code: null, gpx: null, route: null };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  const next = () => process.argv[++i];
  if (a === '--kmh') o.kmh = Number(next());
  else if (a === '--speed') o.speed = Number(next());
  else if (a === '--from') o.from = Number(next()) * 1000;
  else if (a === '--udid') o.udid = next();
  else if (a === '--host') o.host = next();
  else if (a === '--gpx') o.gpx = next();
  else if (a === '--route') o.route = next();
  else if (a === '--help' || a === '-h') { console.log(spawnSync('sed', ['-n', '2,11p', process.argv[1]], { encoding: 'utf8' }).stdout); process.exit(0); }
  else if (!a.startsWith('-') && !o.code) o.code = a.toUpperCase();
  else { console.error(`unknown option ${a}`); process.exit(64); }
}

// ---- the route
async function findTrip() {
  const where = o.code
    ? { fieldFilter: { field: { fieldPath: 'code' }, op: 'EQUAL', value: { stringValue: o.code } } }
    : { fieldFilter: { field: { fieldPath: 'status' }, op: 'EQUAL', value: { stringValue: 'active' } } };
  const url = `http://${o.host}:8080/v1/projects/ikut-b1083/databases/(default)/documents:runQuery`;
  let res;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { Authorization: 'Bearer owner', 'Content-Type': 'application/json' },
      body: JSON.stringify({ structuredQuery: { from: [{ collectionId: 'trips' }], where } }),
    });
  } catch {
    throw new Error(`no Firestore emulator at ${o.host}:8080 (cd firebase && firebase emulators:start), or pass --route`);
  }
  if (!res.ok) throw new Error(`Firestore emulator: ${res.status} ${await res.text()}`);
  const trips = (await res.json()).filter((r) => r.document).map((r) => r.document)
    .sort((a, b) => (b.fields.createdAt?.timestampValue ?? '').localeCompare(a.fields.createdAt?.timestampValue ?? ''));
  if (!trips.length) throw new Error(o.code ? `no trip with code ${o.code}` : 'no active trip; create one in the app first');
  const f = trips[0].fields;
  return { name: f.name?.stringValue, code: f.code?.stringValue, route: f.route?.stringValue ?? '' };
}

const trip = o.route ? { name: 'Route', code: '-', route: o.route } : await findTrip().catch((e) => { console.error(e.message); process.exit(1); });
const line = Polyline.decode(trip.route);
if (line.length < 2) { console.error(`trip ${trip.code} has no route`); process.exit(1); }
const along = [0];
for (let i = 1; i < line.length; i++) along.push(along[i - 1] + haversine(line[i - 1], line[i]));
const total = along.at(-1);
const mps = o.kmh / 3.6;
console.log(`${trip.name} (${trip.code}): ${(total / 1000).toFixed(1)} km, ${line.length} points, ${o.kmh} km/h` +
  `${o.speed === 1 ? '' : ` x${o.speed}`}, about ${Math.ceil((total - o.from) / mps / o.speed / 60)} min`);

/** The point `m` meters along the route, and the index of the first vertex after it. */
function pointAt(m) {
  const found = along.findIndex((d) => d >= m);
  if (found === -1) return { p: line.at(-1), next: line.length };
  const i = Math.max(1, found);
  const a = line[i - 1];
  const b = line[i];
  const f = along[i] === along[i - 1] ? 0 : (m - along[i - 1]) / (along[i] - along[i - 1]);
  return { p: { latitude: a.latitude + (b.latitude - a.latitude) * f, longitude: a.longitude + (b.longitude - a.longitude) * f }, next: i };
}

// ---- GPX for Xcode: one point a second, timed at --kmh
if (o.gpx) {
  const start = Date.parse('2026-01-01T00:00:00Z');
  const points = [];
  for (let m = o.from, t = 0; ; m += mps, t++) {
    const { p } = pointAt(Math.min(m, total));
    points.push({ ...p, time: new Date(start + t * 1000).toISOString().replace('.000', '') });
    if (m >= total) break;
  }
  writeGpx(o.gpx, { name: trip.name, desc: `${trip.code} main route at ${o.kmh} km/h`, points });
  console.log(`wrote ${o.gpx} (${points.length} points)`);
  process.exit(0);
}

// ---- play it on the simulator
// Held while it plays (qa/simlock.sh), so a UI test or demo doesn't drive the same simulator meanwhile.
await holdSimulators([o.udid]);
// `simctl location start` drifts and can stall (qa/README.md), so restart it every RESYNC s from where the car
// should be by now, as run-ui.mjs does.
if (!simctl('list', 'devices').stdout.split('\n').some((l) => l.includes(o.udid) && l.includes('(Booted)'))) {
  console.error(`simulator ${o.udid} is not booted (xcrun simctl boot ${o.udid})`);
  process.exit(1);
}
const RESYNC = 20;
const t0 = Date.now();
const metersNow = () => Math.min(total, o.from + ((Date.now() - t0) / 1000) * mps * o.speed);
let player = null;
const feed = () => {
  const { p, next } = pointAt(metersNow());
  const pts = [p, ...line.slice(next)].map((c) => `${c.latitude.toFixed(6)},${c.longitude.toFixed(6)}`);
  if (pts.length < 2) pts.push(pts[0]);
  player?.kill();
  player = spawn('xcrun', ['simctl', 'location', o.udid, 'start', `--speed=${(mps * o.speed).toFixed(2)}`, '--interval=1', '-']);
  player.stdin.end(`${pts.join('\n')}\n`);
  player.stderr.on('data', (d) => process.stderr.write(`simctl: ${d}`));
};
const stop = (code) => {
  clearInterval(timer);
  player?.kill();
  console.log('');
  process.exit(code);
};
feed();
const timer = setInterval(() => {
  const m = metersNow();
  process.stdout.write(`\r${(m / 1000).toFixed(1)} / ${(total / 1000).toFixed(1)} km  `);
  if (m >= total) {
    console.log('\narrived; the simulator stays at the destination (xcrun simctl location <udid> clear to reset)');
    stop(0);
  }
  if (Math.floor((Date.now() - t0) / 1000) % RESYNC === 0) feed();
}, 1000);
process.on('SIGINT', () => { simctl('location', o.udid, 'clear'); stop(130); });
