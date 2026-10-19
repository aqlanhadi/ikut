#!/usr/bin/env node
// Two real phones in one convoy, plus two scripted cars:
//
//   node run-convoy2.mjs                 # build, then run (about 8 minutes)
//   node run-convoy2.mjs --skip-build    # reuse the build in --derived-data
//
// Phone A (organizer, car 1) is the shared iPhone 17 simulator, phone B (car 2) the `ikut-convoy-2` simulator.
// Both run XCUITests at the same time (ConvoyOrganizerUITests / ConvoyJoinerUITests in
// ios/ikutUITests/TwoPhoneConvoyUITests.swift). Cars 3 and 4 are Firebase clients in this process: they join
// through the joinTrip callable, publish positions with the app's pipeline (lib/tracking.mjs), report an
// accident and vote on the stop.
//
// The tests and this script take turns through marker files in a sync directory ($TMPDIR/ikut-qa/convoy2-sync):
// a side writes `<who>.<step>` when it has done a step and waits for the other side's file. This script:
//   a.code        -> reads the trip from Firestore, parks both simulators on the route (A 3.0 km along,
//                    B 1.4 km), writes `code` for B
//   b.lobby       -> joins cars 3 and 4 (2.2 km and 0.6 km along), writes `cars.joined`
//   a.map, b.map  -> go: drives all four along the route at --kmh (simctl location playback for the
//                    simulators, resynced every 20 s), writes `go`
//   b.alerted     -> car 3 reports an accident, writes `cars.reported`
//   b.stopRequested -> car 3 and car 4 vote (car 3 suggests a place when B's request has none), writes `cars.voted`
// and checks Firestore along the way (order, hazard, stop, pause, leave, end). Any failure writes `abort`.
//
// Options: --kmh N (default 90), --a-udid, --b-udid, --derived-data (default /tmp/ikut-dd-convoy2), --skip-build,
// --host (emulators, default 127.0.0.1), --ask-location (phone B starts without location permission and answers
// the system prompt in the UI). Screenshots: qa/screens/convoy2/. Logs: $TMPDIR/ikut-qa/convoy2-*.log.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { initializeApp, deleteApp } from 'firebase/app';
import { connectAuthEmulator, getAuth, signInAnonymously } from 'firebase/auth';
import {
  GeoPoint, Timestamp, collection, connectFirestoreEmulator, doc, getDoc, getDocs, initializeFirestore, serverTimestamp,
  setDoc, setLogLevel, terminate, updateDoc,
} from 'firebase/firestore';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { CarRouteLogic, Polyline, RouteLine, bearing } from './lib/route.mjs';
import { PositionBuilder, PositionPublisher } from './lib/tracking.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(here);
const PROJECT_ID = 'ikut-b1083';
const REGION = 'asia-southeast1';

const o = {
  aUdid: 'C0A40D2A-0607-4B95-A1BE-F8C9190D81C1', // iPhone 17 (shared)
  bName: 'ikut-convoy-2',
  bUdid: null,
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
  else if (a === '-h' || a === '--help') { console.log(spawnSync('sed', ['-n', '2,26p', process.argv[1]], { encoding: 'utf8' }).stdout); process.exit(0); }
  else { console.error(`unknown option ${a}`); process.exit(64); }
}

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
const say = (...a) => console.log(`[convoy2 ${((Date.now() - t0) / 1000).toFixed(0).padStart(4)}s]`, ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: 'utf8', ...opts });
const simctl = (...args) => run('xcrun', ['simctl', ...args]);
const results = [];
function check(name, pass, detail = '') {
  results.push({ name, pass, detail });
  say(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` (${detail})` : ''}`);
  return pass;
}

// ---------------------------------------------------------------- sync directory

const syncDir = path.join(o.logs, 'convoy2-sync');
fs.rmSync(syncDir, { recursive: true, force: true });
fs.mkdirSync(syncDir, { recursive: true });
fs.mkdirSync(o.screens, { recursive: true });
for (const f of fs.readdirSync(o.screens)) if (f.endsWith('.png')) fs.rmSync(path.join(o.screens, f));

const markPath = (name) => path.join(syncDir, name);
const mark = (name, content = '') => { fs.writeFileSync(markPath(name), content); say(`mark ${name}${content ? ` = ${content}` : ''}`); };
let aborted = null;
async function waitMark(name, timeoutS) {
  const deadline = Date.now() + timeoutS * 1000;
  while (Date.now() < deadline) {
    if (fs.existsSync(markPath(name))) return fs.readFileSync(markPath(name), 'utf8').trim();
    if (fs.existsSync(markPath('abort'))) throw new Error(`aborted: ${fs.readFileSync(markPath('abort'), 'utf8')}`);
    if (aborted) throw new Error(`aborted: ${aborted}`);
    await sleep(300);
  }
  throw new Error(`timed out after ${timeoutS} s waiting for ${name}`);
}
function abort(why) {
  if (fs.existsSync(markPath('abort'))) return;
  aborted = why;
  fs.writeFileSync(markPath('abort'), why);
  say(`ABORT: ${why}`);
}

// ---------------------------------------------------------------- simulators

function deviceLine(pred) {
  return simctl('list', 'devices').stdout.split('\n').find(pred);
}
if (!o.bUdid) {
  const line = deviceLine((l) => l.includes(`${o.bName} (`));
  if (!line) {
    say(`creating simulator ${o.bName} (iPhone 17 Pro, iOS 27.0)`);
    const r = simctl('create', o.bName, 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0');
    if (r.status !== 0) { console.error(r.stderr); process.exit(1); }
    o.bUdid = r.stdout.trim();
  } else {
    o.bUdid = /\(([0-9A-F-]{36})\)/.exec(line)[1];
  }
}
say(`phone A ${o.aUdid}, phone B ${o.bUdid}`);

// Another test run on the shared simulator (the map-centring check uses /tmp/ikut-dd-map) would collide.
while (run('pgrep', ['-f', 'ikut-dd-map']).stdout.trim()) { say('waiting for another UI test on the shared simulator to finish'); await sleep(15_000); }

for (const udid of [o.aUdid, o.bUdid]) {
  const line = deviceLine((l) => l.includes(udid));
  if (!line) { console.error(`simulator ${udid} not found`); process.exit(1); }
  if (!line.includes('(Booted)')) { say(`booting ${udid}`); simctl('boot', udid); }
  simctl('bootstatus', udid, '-b');
  // --ask-location: phone B answers the system location prompt in the UI instead (first-run path).
  if (o.askLocation && udid === o.bUdid) simctl('privacy', udid, 'reset', 'location', 'dev.aqlan.ikut');
  else simctl('privacy', udid, 'grant', 'location-always', 'dev.aqlan.ikut');
  simctl('location', udid, 'set', `${START.latitude},${START.longitude}`);
}

// ---------------------------------------------------------------- build

const ios = path.join(repo, 'ios');
const common = ['-project', path.join(ios, 'ikut.xcodeproj'), '-scheme', 'ikut', '-derivedDataPath', o.derivedData,
  '-clonedSourcePackagesDirPath', path.join(o.derivedData, 'SourcePackages')];
fs.mkdirSync(o.logs, { recursive: true });
if (!o.skipBuild) {
  say('building for testing');
  const r = run('xcodebuild', ['build-for-testing', ...common, '-destination', 'generic/platform=iOS Simulator'], { maxBuffer: 1 << 28 });
  fs.writeFileSync(path.join(o.logs, 'convoy2-build.log'), `${r.stdout}\n${r.stderr}`);
  if (r.status !== 0) { console.error(`build failed, see ${path.join(o.logs, 'convoy2-build.log')}`); process.exit(1); }
}

// ---------------------------------------------------------------- the two UI tests

function startTest(who, udid, only) {
  const logPath = path.join(o.logs, `convoy2-${who}.log`);
  const log = fs.createWriteStream(logPath);
  const bundle = path.join(o.logs, `convoy2-${who}.xcresult`);
  fs.rmSync(bundle, { recursive: true, force: true });
  const xc = spawn('xcodebuild', ['test-without-building', ...common, '-destination', `platform=iOS Simulator,id=${udid}`,
    `-only-testing:ikutUITests/${only}`, '-resultBundlePath', bundle], {
    env: { ...process.env, TEST_RUNNER_IKUT_SYNC_DIR: syncDir, TEST_RUNNER_IKUT_QA_SCREENS: o.screens },
  });
  const t = { who, logPath, checks: [], result: null };
  let buf = '';
  const onData = (d) => {
    log.write(d);
    buf += d.toString();
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const l = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      const c = /QA CHECK: (PASS|FAIL) (.*)$/.exec(l);
      if (c) t.checks.push({ pass: c[1] === 'PASS', name: c[2] });
      if (/Test Case .* failed/.test(l) || /error: -\[ikutUITests/.test(l)) abort(`phone ${who}: ${l.replace(/^.*error: /, '').slice(0, 200)}`);
      if (/QA (STEP|CHECK)|Test Case .*(passed|failed|skipped)|error:|\*\* TEST|XCTAssert|Timed out|Aborted/.test(l)) process.stdout.write(`  ${who} | ${l}\n`);
      if (/\*\* TEST (SUCCEEDED|FAILED) \*\*/.test(l)) t.result ??= l.trim();
      // xcodebuild on the second simulator sometimes never exits after the suite finishes; the suite line decides.
      const suite = /Test Suite 'Selected tests' (passed|failed)/.exec(l);
      if (suite && !t.suite) {
        t.suite = suite[1];
        setTimeout(() => { if (t.code === undefined) { say(`${who}'s xcodebuild still running 60 s after its suite ${t.suite}; killing it`); xc.kill('SIGKILL'); } }, 60_000);
      }
    }
  };
  xc.stdout.on('data', onData);
  xc.stderr.on('data', onData);
  t.exit = new Promise((r) => xc.on('exit', (code) => { t.code = code; t.ok = code === 0 || (code === null && t.suite === 'passed'); r(code); }));
  t.proc = xc;
  return t;
}

const tests = [startTest('A', o.aUdid, 'ConvoyOrganizerUITests'), startTest('B', o.bUdid, 'ConvoyJoinerUITests')];
for (const t of tests) {
  t.exit.then((code) => {
    say(`${t.who}'s test exited ${code} (${t.result ?? `suite ${t.suite ?? 'unfinished'}`})`);
    if (!t.ok) abort(`phone ${t.who}'s test failed`);
  });
}

// ---------------------------------------------------------------- scripted cars

const firestoreOwner = async (body) => {
  const res = await fetch(`http://${o.host}:8080/v1/projects/${PROJECT_ID}/databases/(default)/documents:runQuery`, {
    method: 'POST', headers: { Authorization: 'Bearer owner', 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Firestore emulator: ${res.status} ${await res.text()}`);
  return (await res.json()).filter((r) => r.document).map((r) => r.document);
};

let clockS = () => (Date.now() - t0) / 1000;

class ScriptedCar {
  constructor(spec) { Object.assign(this, spec); }

  async connect() {
    this.app = initializeApp({ apiKey: 'qa-fake-key', projectId: PROJECT_ID, appId: `qa2-${this.key}` }, `qa2-${this.key}`);
    const auth = getAuth(this.app);
    connectAuthEmulator(auth, `http://${o.host}:9099`, { disableWarnings: true });
    this.db = initializeFirestore(this.app, {});
    connectFirestoreEmulator(this.db, o.host, 8080);
    this.fns = getFunctions(this.app, REGION);
    connectFunctionsEmulator(this.fns, o.host, 5001);
    this.uid = (await signInAnonymously(auth)).user.uid;
  }

  // JoinService.join: callable joinTrip, a new car, tracker
  async join(code) {
    const res = await httpsCallable(this.fns, 'joinTrip')({ code, displayName: this.displayName, car: { newCar: { name: this.name, color: this.color } }, tracker: true });
    this.tripId = res.data.tripId;
    this.carId = res.data.carId;
  }

  // CarRouteService.ensureRoute for a car that starts on the main route
  async ensureRoute(route, fix) {
    const plan = CarRouteLogic.planIfOnMain(fix, route);
    if (!plan) throw new Error(`${this.key} start is off the route`);
    await updateDoc(doc(this.db, `trips/${this.tripId}/cars/${this.carId}`), { mergeOffset: plan.mergeOffset, state: plan.state });
    this.builder = new PositionBuilder(route, null);
    this.publisher = new PositionPublisher({ write: (p) => this.writePosition(p), now: clockS });
  }

  writePosition(p) {
    const data = { location: new GeoPoint(p.latitude, p.longitude), speed: p.speed, heading: p.heading, routeOffset: p.routeOffset, updatedAt: serverTimestamp() };
    if (p.convoyOffset !== undefined) data.convoyOffset = p.convoyOffset;
    if (p.battery !== null && p.battery !== undefined) data.battery = p.battery;
    return setDoc(doc(this.db, `trips/${this.tripId}/positions/${this.carId}`), data);
  }

  onFix(fix) {
    this.lastFix = fix;
    this.lastPosition = this.builder.build(fix, 0.8);
    this.publisher.submit(this.lastPosition);
  }

  // EventService.report: hazard, severity high, 45 minute expiry
  async report(type) {
    const createdAt = new Date();
    const ref = doc(collection(this.db, `trips/${this.tripId}/events`));
    await setDoc(ref, {
      type, category: 'hazard', severity: 'high', location: new GeoPoint(this.lastFix.latitude, this.lastFix.longitude),
      heading: Math.max(0, this.lastFix.course) % 360, routeOffset: this.lastPosition.routeOffset,
      authorId: this.uid, carId: this.carId, createdAt: Timestamp.fromDate(createdAt),
      expiresAt: Timestamp.fromMillis(createdAt.getTime() + 45 * 60 * 1000),
    });
    return ref.id;
  }

  // StopService.vote
  async vote(eventId, agree, suggestion = null) {
    const data = { userId: this.uid, agree, at: serverTimestamp() };
    if (suggestion) data.suggestion = suggestion;
    await setDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}/votes/${this.carId}`), data);
  }

  async close() {
    this.publisher?.stop();
    if (!this.app) return;
    await terminate(this.db).catch(() => {});
    await deleteApp(this.app).catch(() => {});
  }
}

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
  const p = route.coordinateAtOffset(m);
  const pts = [p, ...route.coordinates.slice(next)].map((c) => `${c.latitude.toFixed(6)},${c.longitude.toFixed(6)}`);
  players[who]?.kill();
  const loc = spawn('xcrun', ['simctl', 'location', udid, 'start', `--speed=${mps.toFixed(2)}`, '--interval=1', '-']);
  loc.stdin.end(`${pts.join('\n')}\n`);
  loc.stderr.on('data', (d) => process.stdout.write(`  loc ${who}! ${d}`));
  players[who] = loc;
}

const cars = SCRIPTED.map((s) => new ScriptedCar(s));
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
  code = await waitMark('a.code', 420);
  const trips = await firestoreOwner({ structuredQuery: { from: [{ collectionId: 'trips' }], where: { fieldFilter: { field: { fieldPath: 'code' }, op: 'EQUAL', value: { stringValue: code } } } } });
  check('trip created by phone A is in Firestore with a route', trips.length === 1 && (trips[0].fields.route?.stringValue ?? '').length > 0, `code ${code}`);
  tripId = trips[0].name.split('/').pop();
  route = new RouteLine(Polyline.decode(trips[0].fields.route.stringValue));
  check('route is long enough for the drive', route.length > 20_000, `${(route.length / 1000).toFixed(1)} km to ${trips[0].fields.destination?.mapValue?.fields?.name?.stringValue}`);
  for (const [who, udid] of [['A', o.aUdid], ['B', o.bUdid]]) {
    const p = route.coordinateAtOffset(OFFSETS[who]);
    simctl('location', udid, 'set', `${p.latitude.toFixed(6)},${p.longitude.toFixed(6)}`);
  }
  say(`trip ${tripId}: ${(route.length / 1000).toFixed(1)} km; A parked ${OFFSETS.A} m along, B ${OFFSETS.B} m`);
  mark('code', code);

  // 2. B joined; then cars 3 and 4 join and hold their start positions
  await waitMark('b.lobby', 300);
  for (const c of cars) {
    await c.connect();
    await c.join(code);
    const fix = fixAt(OFFSETS[c.key], false);
    await c.ensureRoute(route, fix);
    c.onFix(fix);
  }
  ticker = setInterval(() => {
    for (const c of cars) { c.onFix(fixAt(offsetOf(c.key), Boolean(goAt))); c.publisher.tick(); }
  }, 1000);
  const carDocs = await carsByNumber();
  const numbers = [...carDocs.values()].map((c) => `${c.number} ${c.name}`).sort();
  check('car numbers: A 1, B 2, car 3, car 4', JSON.stringify([...carDocs.values()].map((c) => c.number).sort()) === '[1,2,3,4]', numbers.join(', '));
  await sleep(3000);
  mark('cars.joined');

  // 3. both on the map: go
  await waitMark('a.map', 240);
  await waitMark('b.map', 240);
  goAt = Date.now();
  feed('A', o.aUdid);
  feed('B', o.bUdid);
  feeder = setInterval(() => { feed('A', o.aUdid); feed('B', o.bUdid); }, 20_000);
  say(`go: everyone at ${o.kmh} km/h`);
  mark('go');

  await waitMark('a.order', 240);
  await waitMark('b.order', 240);
  const order = await convoyOrderFromFirestore();
  check('Firestore convoy order 1 > 3 > 2 > 4', order.map((r) => r.n).join(',') === '1,3,2,4', order.map((r) => `${r.n}@${(r.off / 1000).toFixed(2)}k`).join(' > '));

  // 4. A's hazard
  await waitMark('a.reported', 240);
  await sleep(2000);
  const events = await getDocs(collection(reader(), `trips/${tripId}/events`));
  const carDocs2 = await carsByNumber();
  const aCarId = [...carDocs2.entries()].find(([, c]) => c.number === 1)?.[0];
  const debris = events.docs.map((d) => d.data()).find((e) => e.type === 'debris' && e.carId === aCarId);
  check('phone A\'s debris report stored (hazard, high, from car 1)', Boolean(debris) && debris.category === 'hazard' && debris.severity === 'high', debris ? `routeOffset ${debris.routeOffset?.toFixed(0)} m` : 'missing');

  // 5. car 3 reports an accident once B has been warned about the debris
  await waitMark('b.alerted', 240);
  const car3 = cars[0];
  const accidentId = await car3.report('accident');
  say(`car 3 reports an accident at ${car3.lastPosition.convoyOffset.toFixed(0)} m (event ${accidentId})`);
  mark('cars.reported');

  // 6. B's stop request: the scripted cars vote
  await waitMark('b.stopRequested', 300);
  const stop = (await getDocs(collection(reader(), `trips/${tripId}/events`))).docs
    .map((d) => ({ id: d.id, ...d.data() })).find((e) => e.category === 'stopRequest' && !e.expiresAt);
  if (!check('phone B\'s stop request is open in Firestore', Boolean(stop), stop ? `${stop.type}` : 'none')) throw new Error('no stop request');
  const bCarId = [...carDocs2.entries()].find(([, c]) => c.number === 2)?.[0];
  const bVote = (await getDoc(doc(reader(), `trips/${tripId}/events/${stop.id}/votes/${bCarId}`))).data();
  say(`B's vote: ${JSON.stringify({ agree: bVote?.agree, suggestion: bVote?.suggestion?.name ?? null })}`);
  if (bVote?.suggestion) {
    await car3.vote(stop.id, true);
  } else {
    // No place found ahead on B's phone: car 3 suggests one so the lead has something to pin.
    const off = Math.max(...cars.map((c) => c.lastPosition.convoyOffset)) + 8000;
    const c = route.coordinateAtOffset(off);
    await car3.vote(stop.id, false, { name: 'QA Rest Area', coordinate: new GeoPoint(c.latitude, c.longitude), routeOffset: off });
  }
  await cars[1].vote(stop.id, true);
  say(`car 3 ${bVote?.suggestion ? 'agrees' : 'suggests QA Rest Area'}, car 4 agrees`);
  mark('cars.voted');

  await waitMark('a.pinned', 300);
  const pinned = (await getDoc(doc(reader(), `trips/${tripId}/events/${stop.id}`))).data();
  check('stop pinned by phone A', Boolean(pinned.place?.name), pinned.place ? `${pinned.place.name}` : 'no place');
  await waitMark('a.resolved', 300);
  const resolved = (await getDoc(doc(reader(), `trips/${tripId}/events/${stop.id}`))).data();
  check('stop resolved (expiresAt set)', Boolean(resolved.expiresAt) && resolved.expiresAt.toMillis() <= Date.now() + 1000);

  // 7. pause / resume
  await waitMark('b.paused', 300);
  await sleep(1500);
  const paused = (await getDoc(doc(reader(), `trips/${tripId}/cars/${bCarId}`))).data();
  check('B\'s car doc has pausedAt while paused', Boolean(paused?.pausedAt));
  await waitMark('b.resumed', 300);
  await sleep(1500);
  const resumed = (await getDoc(doc(reader(), `trips/${tripId}/cars/${bCarId}`))).data();
  check('pausedAt cleared after resume', resumed && !resumed.pausedAt);

  // 8. leave, rejoin, end
  await waitMark('b.left', 300);
  await sleep(5000);
  const afterLeave = await carsByNumber();
  check('B\'s car removed after B leaves (memberCleanup)', !afterLeave.has(bCarId), [...afterLeave.values()].map((c) => c.number).sort().join(','));
  await waitMark('b.rejoined', 300);
  await waitMark('a.ended', 300);
  const trip = (await getDoc(doc(reader(), `trips/${tripId}`))).data();
  check('trip status ended', trip.status === 'ended', trip.status);
  await waitMark('b.done', 180);
}

let scenarioError = null;
await scenario().catch((e) => { scenarioError = e; abort(`script: ${e.message}`); });
const codes = await Promise.race([Promise.all(tests.map((t) => t.exit)), sleep(180_000).then(() => null)]);
if (!codes) for (const t of tests) if (t.code === undefined) { say(`killing ${t.who}'s test`); t.proc.kill('SIGKILL'); }
await Promise.all(tests.map((t) => t.exit));

clearInterval(ticker);
clearInterval(feeder);
for (const p of Object.values(players)) p.kill();
for (const udid of [o.aUdid, o.bUdid]) simctl('location', udid, 'clear');
setLogLevel('silent');
for (const c of cars) await c.close();

// ---------------------------------------------------------------- summary
console.log('\n---- checks');
for (const t of tests) for (const c of t.checks) console.log(`${c.pass ? 'PASS' : 'FAIL'}  phone ${c.name}`);
for (const r of results) console.log(`${r.pass ? 'PASS' : 'FAIL'}  script: ${r.name}${r.detail ? ` (${r.detail})` : ''}`);
if (scenarioError) console.log(`script stopped: ${scenarioError.message}`);
for (const t of tests) console.log(`phone ${t.who}: ${t.result ?? `suite ${t.suite ?? 'unfinished'}, exit ${t.code}`}, log ${t.logPath}`);
console.log(`screenshots ${o.screens}`);
const ok = !scenarioError && results.every((r) => r.pass) && tests.every((t) => t.ok);
console.log(ok ? '\nRESULT: PASS' : '\nRESULT: FAIL');
fs.writeFileSync(path.join(o.logs, 'convoy2-results.json'), JSON.stringify({ code, tripId, results, phones: tests.map((t) => ({ who: t.who, ok: t.ok, suite: t.suite, checks: t.checks })) }, null, 2));
process.exit(ok ? 0 : 1);
