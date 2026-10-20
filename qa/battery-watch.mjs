// Records a tracker phone's battery and position writes during a real trip (L5, Q2), from the Mac.
// Joins the trip as a passenger in the tracked car (no new car, no tracking), listens to that
// car's position doc, and writes every update to a CSV. Ctrl-C or ending the trip prints the
// drain per hour and any gaps over 60 s, then leaves the trip.
//
//   node battery-watch.mjs <TRIP CODE> [--car "<car name>"] [--out <file.csv>]
//
// Keeps the Mac awake with caffeinate while it runs. Reads the real Firebase project
// (ios/ikut/Resources/GoogleService-Info.plist), like prod-smoke.mjs.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { initializeApp } from 'firebase/app';
import { deleteUser, getAuth, signInAnonymously } from 'firebase/auth';
import { deleteDoc, doc, initializeFirestore, onSnapshot, terminate } from 'firebase/firestore';
import { getFunctions, httpsCallable } from 'firebase/functions';
import { productionFirebaseConfig } from './lib/firebase-config.mjs';
import { GAP_SECONDS, formatSummary, summarize } from './lib/battery.mjs';

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: { car: { type: 'string' }, out: { type: 'string' } },
});
const code = positionals[0]?.toUpperCase();
if (!code) {
  console.error('usage: node battery-watch.mjs <TRIP CODE> [--car "<car name>"] [--out <file.csv>]');
  process.exit(2);
}

const config = productionFirebaseConfig();

// Stops the Mac idle-sleeping until this process exits. Closing the lid on battery still sleeps it.
spawn('caffeinate', ['-i', '-w', String(process.pid)], { stdio: 'ignore', detached: true }).on('error', () => {}).unref();

const app = initializeApp(config);
const auth = getAuth(app);
const { user } = await signInAnonymously(auth);
const db = initializeFirestore(app, {});
const fns = getFunctions(app, 'asia-southeast1');

const preview = (await httpsCallable(fns, 'previewTrip')({ code })).data;
const tracked = preview.cars.filter((c) => c.hasTracker);
const car = opts.car
  ? preview.cars.find((c) => c.name.toLowerCase().includes(opts.car.toLowerCase()))
  : tracked.length === 1 ? tracked[0] : null;
if (!car) {
  const list = preview.cars.map((c) => `"${c.name}"${c.hasTracker ? '' : ' (no tracker)'}`).join(', ');
  console.error(opts.car ? `No car matching "${opts.car}". Cars: ${list}` : `Pick a car with --car. Cars: ${list}`);
  process.exit(2);
}
const { tripId } = (await httpsCallable(fns, 'joinTrip')({
  code, displayName: 'Battery watch', car: { existingCarId: car.id }, tracker: false,
})).data;

const stamp = new Date().toISOString().slice(0, 16).replace(/[-:T]/g, '');
const out = opts.out ?? fileURLToPath(new URL(`battery/${code}-${stamp}.csv`, import.meta.url));
fs.mkdirSync(new URL('battery/', import.meta.url), { recursive: true });
const csv = fs.createWriteStream(out, { flags: 'a' });
csv.write('updated_at,gap_s,battery_pct,speed_kmh,lat,lon\n');

console.log(`Watching "${car.name}" in "${preview.name}" (${code}) → ${out}`);
console.log(`Ctrl-C to stop. Gaps over ${GAP_SECONDS} s are flagged as they happen.\n`);

const updates = [];
const clock = (ms) => new Date(ms).toLocaleTimeString('en-GB', { hour12: false });
const pct = (b) => (b == null ? '' : Math.round(b * 100));

const stopPosition = onSnapshot(doc(db, `trips/${tripId}/positions/${car.id}`), (snap) => {
  const p = snap.data({ serverTimestamps: 'none' });
  if (!p?.updatedAt) return;
  const t = p.updatedAt.toMillis();
  const prev = updates.at(-1);
  if (prev && t <= prev.t) return; // Same write seen again after a reconnect.
  // iOS reports -1 when it doesn't know; PositionBuilder sends that as no value.
  const battery = typeof p.battery === 'number' ? p.battery : null;
  updates.push({ t, battery });
  const gap = prev ? (t - prev.t) / 1000 : 0;
  csv.write(`${new Date(t).toISOString()},${gap.toFixed(1)},${pct(battery)},${(p.speed * 3.6).toFixed(1)},${p.location.latitude},${p.location.longitude}\n`);
  if (gap > GAP_SECONDS) console.log(`${clock(t)}  back after ${Math.round(gap)} s of silence`);
}, (err) => console.error(`position listener: ${err.message}`));

const stopTrip = onSnapshot(doc(db, `trips/${tripId}`), (snap) => {
  if (snap.data()?.status === 'ended') finish('trip ended');
}, () => {});

// Every 30 s: flag ongoing silence once, and print a status line every 5 minutes.
let warnedFor = null;
let ticks = 0;
const ticker = setInterval(() => {
  const last = updates.at(-1);
  const now = Date.now();
  if (last && (now - last.t) / 1000 > GAP_SECONDS && warnedFor !== last.t) {
    warnedFor = last.t;
    console.log(`${clock(now)}  no update since ${clock(last.t)}`);
  }
  if (++ticks % 10 === 0) {
    const s = summarize(updates, now);
    const rate = s.drainPerHour == null ? '' : `, ${s.drainPerHour.toFixed(1)}%/h`;
    console.log(`${clock(now)}  ${s.writes} writes, battery ${s.endPct ?? '?'}%${rate}, ${s.gaps.length} gap(s)`);
  }
}, 30_000);

let finishing = false;
async function finish(reason) {
  if (finishing) return;
  finishing = true;
  clearInterval(ticker);
  stopPosition();
  stopTrip();
  console.log(`\nStopped (${reason}).\n\n${formatSummary(summarize(updates, Date.now()))}\n\nCSV: ${out}`);
  csv.end();
  // Leaving releases nothing: this member never tracks. Rules refuse it once the trip has ended.
  if (reason !== 'trip ended') await deleteDoc(doc(db, `trips/${tripId}/members/${user.uid}`)).catch(() => {});
  await terminate(db);
  await deleteUser(user).catch(() => {});
  process.exit(0);
}
process.on('SIGINT', () => finish('Ctrl-C'));
