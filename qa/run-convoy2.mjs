#!/usr/bin/env node
// Two real phones in one convoy, plus two scripted cars:
//
//   node run-convoy2.mjs                 # build, then run (about 8 minutes)
//   node run-convoy2.mjs --skip-build    # reuse the build in --derived-data
//
// Phone A (organizer, car 1) is the shared iPhone 17 #1 simulator, phone B (car 2) iPhone 17 #2.
// Both run XCUITests at the same time (ConvoyOrganizerUITests / ConvoyJoinerUITests in
// ios/ikutUITests/TwoPhoneConvoyUITests.swift). Cars 3 and 4 are Firebase clients in this process: they join
// through the joinTrip callable, publish positions with the app's pipeline (lib/tracking.mjs), report an
// accident and say OK to the stop.
//
// The tests and this script take turns through marker files in a sync directory ($TMPDIR/ikut-qa/convoy2-sync):
// a side writes `<who>.<step>` when it has done a step and waits for the other side's file. This script:
//   a.code        -> reads the trip from Firestore, parks both simulators on the route (A 3.0 km along,
//                    B 1.4 km), writes `code` for B
//   b.lobby       -> joins cars 3 and 4 (2.2 km and 0.6 km along), writes `cars.joined`
//   a.map, b.map  -> go: drives all four along the route at --kmh (simctl location playback for the
//                    simulators, resynced every 20 s), writes `go`
//   b.alerted     -> car 3 reports an accident, writes `cars.reported`
//   b.stopRequested -> car 3 and car 4 say OK, writes `cars.voted`
// and checks Firestore along the way (order, hazard, stop, pause, leave, end). Any failure writes `abort`.
//
// Options: --kmh N (default 90), --a-udid, --b-udid, --derived-data (default /tmp/ikut-dd-convoy2), --skip-build,
// --host (emulators, default 127.0.0.1), --ask-location (phone B starts without location permission and answers
// the system prompt in the UI), --deadline S (stop with RESULT: ABORT after S s; default 1800, plus 1800 for a
// build). Screenshots: qa/screens/convoy2/. Logs: $TMPDIR/ikut-qa/convoy2-*.log. It holds both simulators while it
// runs (qa/simlock.sh), and the log always ends in one `RESULT: PASS|FAIL|ABORT` line.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { collection, doc, getDoc, getDocs, onSnapshot, setLogLevel } from 'firebase/firestore';
import { Polyline, RouteLine, bearing } from './lib/route.mjs';
import { Car, Sync, buildForTesting, feedLocation, prepareSimulator, startUiTest } from './lib/demo-common.mjs';
import { ownerQuery } from './lib/playground.mjs';
import { endsWithResult, holdSimulators, makeSay, simctl, sleep } from './lib/shell.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(here);

const o = {
  aUdid: 'C0A40D2A-0607-4B95-A1BE-F8C9190D81C1', // iPhone 17 #1 (shared)
  bUdid: 'FD0ACD10-F3C4-4797-8DB8-A6F554585CC1', // iPhone 17 #2 (an iPhone 17 Pro), the second phone
  kmh: 90,
  derivedData: '/tmp/ikut-dd-convoy2',
  skipBuild: false,
  host: '127.0.0.1',
  screens: path.join(here, 'screens', 'convoy2'),
  logs: path.join(os.tmpdir(), 'ikut-qa'),
};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  const next = () => process.argv[++i];
  if (a === '--kmh') o.kmh = Number(next());
  else if (a === '--a-udid') o.aUdid = next();
  else if (a === '--b-udid') o.bUdid = next();
  else if (a === '--derived-data') o.derivedData = next();
  else if (a === '--skip-build') o.skipBuild = true;
  else if (a === '--host') o.host = next();
  else if (a === '--ask-location') o.askLocation = true;
  else if (a === '--deadline') o.deadline = Number(next());
  else if (a === '-h' || a === '--help') { console.log(spawnSync('sed', ['-n', '2,28p', process.argv[1]], { encoding: 'utf8' }).stdout); process.exit(0); }
  else { console.error(`unknown option ${a}`); process.exit(64); }
}
await holdSimulators([o.aUdid, o.bUdid]);
const end = endsWithResult({ deadlineS: o.deadline ?? (o.skipBuild ? 0 : 1800) + 1800, signals: true });
process.on('exit', () => { for (const udid of [o.aUdid, o.bUdid]) simctl('location', udid, 'clear'); });

// Where the trip starts (A's simulated location when it picks the destination): the E1 northbound just
// south of Bidor, the start of qa/data/osrm-main.json. Ipoh is about 65 km up the road.
const START = { latitude: 4.096585, longitude: 101.30326 };
// Meters along the trip's route at go. Order front to back: A (car 1), car 3, B (car 2), car 4.
const OFFSETS = { A: 3000, car3: 2200, B: 1400, car4: 600 };
const SCRIPTED = [
  { key: 'car3', displayName: 'Hafiz', name: 'Hafiz’s Hilux', color: '#0F766E' },
  { key: 'car4', displayName: 'Daniel', name: 'Daniel’s City', color: '#7C3AED' },
];

const t0 = Date.now();
const say = makeSay('convoy2', t0);
const results = [];
function check(name, pass, detail = '') {
  results.push({ name, pass, detail });
  say(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` (${detail})` : ''}`);
  return pass;
}

// ---------------------------------------------------------------- sync directory

const sync = new Sync(path.join(o.logs, 'convoy2-sync'), say);
fs.mkdirSync(o.screens, { recursive: true });
for (const f of fs.readdirSync(o.screens)) if (f.endsWith('.png')) fs.rmSync(path.join(o.screens, f));

// ---------------------------------------------------------------- simulators

// Never create or erase simulators here (CLAUDE.md): both phones must already exist (prepareSimulator checks).
say(`phone A ${o.aUdid}, phone B ${o.bUdid}`);

// Known starting state for both phones (Q9): the app is uninstalled so no earlier session, trip or setting
// survives (Backend.dropUserFromOtherBackend signs out the Keychain user once UserDefaults is gone), and the
// text size is the default (a leftover accessibility size from a screenshot session breaks taps).
// --ask-location: phone B answers the system location prompt in the UI instead (first-run path).
for (const udid of [o.aUdid, o.bUdid]) {
  prepareSimulator(udid, say, { start: START, textSize: 'large', askLocation: o.askLocation && udid === o.bUdid, bootText: `booting ${udid}` });
}

// ---------------------------------------------------------------- build

fs.mkdirSync(o.logs, { recursive: true });
if (!o.skipBuild) {
  say('building for testing');
  const build = buildForTesting(o, path.join(o.logs, 'convoy2-build.log'));
  if (!build.ok) { console.error(`build failed, see ${build.logPath}`); process.exit(1); }
}

// ---------------------------------------------------------------- the two UI tests

const startTest = (who, udid, only) => startUiTest(o, {
  udid, only, id: who, label: who, say, onFail: (why) => sync.abort(why === `${who}'s test failed` ? `phone ${why}` : why), // the abort text names the phone
  logPath: path.join(o.logs, `convoy2-${who}.log`),
  bundle: path.join(o.logs, `convoy2-${who}.xcresult`),
  env: { TEST_RUNNER_IKUT_SYNC_DIR: sync.dir, TEST_RUNNER_IKUT_QA_SCREENS: o.screens },
  track: (c) => end.track(c),
  echo: /QA (STEP|CHECK)|Test Case .*(passed|failed|skipped)|error:|\*\* TEST|XCTAssert|Timed out|Aborted/,
  abortOn: (l) => (/Test Case .* failed/.test(l) || /error: -\[ikutUITests/.test(l) ? `phone ${who}: ${l.replace(/^.*error: /, '').slice(0, 200)}` : null),
});

const tests = [startTest('A', o.aUdid, 'ConvoyOrganizerUITests'), startTest('B', o.bUdid, 'ConvoyJoinerUITests')];
// ---------------------------------------------------------------- scripted cars

const firestoreOwner = (structuredQuery) => ownerQuery(o.host, structuredQuery);

const clockS = () => (Date.now() - t0) / 1000;

// ---------------------------------------------------------------- the drive

const mps = o.kmh / 3.6;
let route = null;
let goAt = null;
const offsetOf = (key) => OFFSETS[key] + (goAt ? ((Date.now() - goAt) / 1000) * mps : 0);
const fixAt = (offset, moving) => {
  const p = route.coordinateAtOffset(offset);
  const ahead = route.coordinateAtOffset(offset + 25);
  return { latitude: p.latitude, longitude: p.longitude, speed: moving ? mps : 0, course: bearing(p, ahead) };
};

/** Restarts `simctl location start` from where the phone should be now (playback drifts, see qa/README.md). */
const players = {};
function feed(who, udid) {
  const m = offsetOf(who);
  const next = route.cumulative.findIndex((d) => d > m);
  if (next < 0) return;
  players[who]?.kill();
  players[who] = feedLocation({ udid, points: [route.coordinateAtOffset(m), ...route.coordinates.slice(next)], mps, label: who });
}

const cars = SCRIPTED.map((s) => new Car({ appPrefix: 'qa2', ...s }, { host: o.host, backend: 'emulators' }, say));
let ticker = null;
let feeder = null;
let tripId = null;
let code = null;
const reader = () => cars[0].db;

async function carsByNumber() {
  const snap = await getDocs(collection(reader(), `trips/${tripId}/cars`));
  return new Map(snap.docs.map((d) => [d.id, d.data()]));
}
async function convoyOrderFromFirestore() {
  const carDocs = await carsByNumber();
  const snap = await getDocs(collection(reader(), `trips/${tripId}/positions`));
  return snap.docs.map((d) => ({ n: carDocs.get(d.id)?.number, off: d.data().convoyOffset }))
    .filter((r) => typeof r.off === 'number' && r.n !== undefined).sort((a, b) => b.off - a.off);
}

async function scenario() {
  // 1. A created the trip
  code = await sync.wait('a.code', 420);
  const trips = await firestoreOwner({ from: [{ collectionId: 'trips' }], where: { fieldFilter: { field: { fieldPath: 'code' }, op: 'EQUAL', value: { stringValue: code } } } });
  check('trip created by phone A is in Firestore with a route', trips.length === 1 && (trips[0].fields.route?.stringValue ?? '').length > 0, `code ${code}`);
  tripId = trips[0].name.split('/').pop();
  route = new RouteLine(Polyline.decode(trips[0].fields.route.stringValue));
  check('route is long enough for the drive', route.length > 20_000, `${(route.length / 1000).toFixed(1)} km to ${trips[0].fields.destination?.mapValue?.fields?.name?.stringValue}`);
  for (const [who, udid] of [['A', o.aUdid], ['B', o.bUdid]]) {
    const p = route.coordinateAtOffset(OFFSETS[who]);
    simctl('location', udid, 'set', `${p.latitude.toFixed(6)},${p.longitude.toFixed(6)}`);
  }
  say(`trip ${tripId}: ${(route.length / 1000).toFixed(1)} km; A parked ${OFFSETS.A} m along, B ${OFFSETS.B} m`);
  sync.mark('code', code);

  // 2. B joined; then cars 3 and 4 join and hold their start positions
  await sync.wait('b.lobby', 300);
  for (const c of cars) {
    await c.connect();
    await c.join(code);
    const fix = fixAt(OFFSETS[c.key], false);
    await c.ensureRoute(route, fix, clockS);
    c.onFix(fix);
  }
  ticker = setInterval(() => {
    for (const c of cars) { c.onFix(fixAt(offsetOf(c.key), Boolean(goAt))); c.publisher.tick(); }
  }, 1000);
  const carDocs = await carsByNumber();
  const numbers = [...carDocs.values()].map((c) => `${c.number} ${c.name}`).sort();
  check('car numbers: A 1, B 2, car 3, car 4', JSON.stringify([...carDocs.values()].map((c) => c.number).sort()) === '[1,2,3,4]', numbers.join(', '));
  await sleep(3000);
  sync.mark('cars.joined');

  // 3. both on the map: go
  await sync.wait('a.map', 240);
  await sync.wait('b.map', 240);
  goAt = Date.now();
  feed('A', o.aUdid);
  feed('B', o.bUdid);
  feeder = setInterval(() => { feed('A', o.aUdid); feed('B', o.bUdid); }, 20_000);
  say(`go: everyone at ${o.kmh} km/h`);
  sync.mark('go');

  await sync.wait('a.order', 240);
  await sync.wait('b.order', 240);
  const order = await convoyOrderFromFirestore();
  check('Firestore convoy order 1 > 3 > 2 > 4', order.map((r) => r.n).join(',') === '1,3,2,4', order.map((r) => `${r.n}@${(r.off / 1000).toFixed(2)}k`).join(' > '));

  // 4. A's hazard
  await sync.wait('a.reported', 240);
  await sleep(2000);
  const events = await getDocs(collection(reader(), `trips/${tripId}/events`));
  const carDocs2 = await carsByNumber();
  const aCarId = [...carDocs2.entries()].find(([, c]) => c.number === 1)?.[0];
  const debris = events.docs.map((d) => d.data()).find((e) => e.type === 'debris' && e.carId === aCarId);
  check('phone A\'s debris report stored (hazard, high, from car 1)', Boolean(debris) && debris.category === 'hazard' && debris.severity === 'high', debris ? `routeOffset ${debris.routeOffset?.toFixed(0)} m` : 'missing');

  // 5. car 3 reports an accident once B has been warned about the debris
  await sync.wait('b.alerted', 240);
  const car3 = cars[0];
  const { id: accidentId } = await car3.reportEvent('accident', 'hazard', 'high', 45 * 60);
  say(`car 3 reports an accident at ${car3.lastPosition.convoyOffset.toFixed(0)} m (event ${accidentId})`);
  sync.mark('cars.reported');

  // 6. B's stop request (with a passenger message): the scripted cars say OK, A taps OK and We've stopped
  await sync.wait('b.stopRequested', 300);
  const stop = (await getDocs(collection(reader(), `trips/${tripId}/events`))).docs
    .map((d) => ({ id: d.id, ...d.data() })).find((e) => e.category === 'stopRequest' && e.status !== 'closed' && e.expiresAt?.toMillis() > Date.now());
  if (!check('phone B\'s stop request is open in Firestore', Boolean(stop), stop ? `${stop.type}` : 'none')) throw new Error('no stop request');
  check('B\'s request carries its passenger message, no place, and closes itself after 30 min', stop.message === 'Need fuel, next R and R please' && stop.place === undefined && stop.expiresAt.toMillis() - stop.createdAt.toMillis() === 30 * 60 * 1000, JSON.stringify({ message: stop.message, place: stop.place }));
  const bCarId = [...carDocs2.entries()].find(([, c]) => c.number === 2)?.[0];
  await car3.ok(stop.id);
  await cars[1].ok(stop.id);
  say('cars 3 and 4 say OK');
  sync.mark('cars.voted');

  await sync.wait('a.ok', 300);
  const aVote = (await getDoc(doc(reader(), `trips/${tripId}/events/${stop.id}/votes/${aCarId}`))).data();
  check('phone A said OK for its car', Boolean(aVote), JSON.stringify(aVote ? { userId: aVote.userId } : null));
  await sync.wait('a.stopped', 300);
  const closed = (await getDoc(doc(reader(), `trips/${tripId}/events/${stop.id}`))).data();
  check('stop closed as stopped by phone A (We\'ve stopped)', closed.status === 'closed' && closed.closedReason === 'stopped' && Boolean(closed.closedBy) && closed.expiresAt.toMillis() <= Date.now() + 1000, JSON.stringify({ status: closed.status, closedReason: closed.closedReason }));

  // 7. pause / resume. B resumes as soon as phone A has seen the pause, which can be before one read here
  // lands, so listen from before B pauses and keep whether pausedAt ever showed.
  let sawPausedAt = false;
  const stopListening = onSnapshot(doc(reader(), `trips/${tripId}/cars/${bCarId}`), (snap) => {
    if (snap.data()?.pausedAt) sawPausedAt = true;
  });
  await sync.wait('b.paused', 300);
  for (let i = 0; i < 20 && !sawPausedAt; i++) await sleep(500);
  check('B\'s car doc has pausedAt while paused', sawPausedAt);
  await sync.wait('b.resumed', 300);
  stopListening();
  await sleep(1500);
  const resumed = (await getDoc(doc(reader(), `trips/${tripId}/cars/${bCarId}`))).data();
  check('pausedAt cleared after resume', resumed && !resumed.pausedAt);

  // 8. leave, rejoin, end
  await sync.wait('b.left', 300);
  await sleep(5000);
  const afterLeave = await carsByNumber();
  check('B\'s car removed after B leaves (memberCleanup)', !afterLeave.has(bCarId), [...afterLeave.values()].map((c) => c.number).sort().join(','));
  await sync.wait('b.rejoined', 300);
  await sync.wait('a.ended', 300);
  const trip = (await getDoc(doc(reader(), `trips/${tripId}`))).data();
  check('trip status ended', trip.status === 'ended', trip.status);
  await sync.wait('b.done', 180);
}

let scenarioError = null;
await scenario().catch((e) => { scenarioError = e; sync.abort(`script: ${e.message}`); });
const codes = await Promise.race([Promise.all(tests.map((t) => t.exit)), sleep(180_000).then(() => null)]);
if (!codes) for (const t of tests) if (t.code === undefined) { say(`killing ${t.id}'s test`); t.xc.kill('SIGKILL'); }
await Promise.all(tests.map((t) => t.exit));

clearInterval(ticker);
clearInterval(feeder);
for (const p of Object.values(players)) p.kill();
for (const udid of [o.aUdid, o.bUdid]) simctl('location', udid, 'clear');
setLogLevel('silent');
for (const c of cars) await c.close();

// ---------------------------------------------------------------- summary
console.log('\n---- checks');
for (const t of tests) for (const c of t.checks.filter((c) => c.kind !== 'NOTE')) console.log(`${c.kind}  phone ${c.name}`);
for (const r of results) console.log(`${r.pass ? 'PASS' : 'FAIL'}  script: ${r.name}${r.detail ? ` (${r.detail})` : ''}`);
if (scenarioError) console.log(`script stopped: ${scenarioError.message}`);
for (const t of tests) console.log(`phone ${t.id}: ${t.result ?? `suite ${t.suite ?? 'unfinished'}, exit ${t.code}`}, log ${t.logPath}`);
console.log(`screenshots ${o.screens}`);
const ok = !scenarioError && results.every((r) => r.pass) && tests.every((t) => t.ok);
fs.writeFileSync(path.join(o.logs, 'convoy2-results.json'), JSON.stringify({ code, tripId, results, phones: tests.map((t) => ({ who: t.id, ok: t.ok, suite: t.suite, checks: t.checks.filter((c) => c.kind !== 'NOTE').map((c) => ({ pass: c.kind === 'PASS', name: c.name })) })) }, null, 2));
end.result(ok);
process.exit(ok ? 0 : 1);
