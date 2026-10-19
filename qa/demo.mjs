#!/usr/bin/env node
// Live demo for a human: about 10 minutes of real-time convoy driving to watch on the iPhone 17 simulator.
//
//   node demo.mjs                  # build + run: phone joins by UI test, then the demo plays at 1x
//   node demo.mjs --skip-build     # reuse the build in --derived-data
//   node demo.mjs --dry-run        # no Firebase, no simulator: print the timeline and sanity-check the geometry
//   node demo.mjs --no-app [--seconds 30]   # scripted cars only against the emulators, no simulator
//
// Cast (front to back at the start): Aisha (lead, scripted), Faiz (the phone, car on the simulator), Hafiz (scripted,
// slowest) and Daniel (scripted, joining from his own road and merging between the phone and Hafiz).
// The route is a ~16.3 km piece of the E1 (qa/data/osrm-main.json) cut to fit ten minutes at ~95 km/h; the trip
// destination is its end. Daniel's own route is qa/data/osrm-car4.json, which joins that road at the Tapah ramp.
//
// Reuse: lib/route.mjs (RouteLine, CarRouteLogic, Polyline), lib/tracking.mjs (PositionBuilder/Publisher, ApproachCore),
// the Firestore writes of convoy-sim.mjs (copied, that file runs on import), the UI-test join and the 20 s simctl
// location resync of run-ui.mjs.
//
// Options: --udid, --name (the phone's display name), --derived-data (default /tmp/ikut-dd-q1), --skip-build,
// --host, --speed N (dev only: faster clock; the signal-drop staleness needs <= 2.5), --wait-timeout S, --end-trip.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { initializeApp, deleteApp } from 'firebase/app';
import { connectAuthEmulator, getAuth, signInAnonymously } from 'firebase/auth';
import {
  GeoPoint, Timestamp, collection, connectFirestoreEmulator, deleteField, disableNetwork, doc, enableNetwork, getDocs,
  initializeFirestore, onSnapshot, serverTimestamp, setDoc, setLogLevel, terminate, updateDoc, writeBatch,
} from 'firebase/firestore';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { CarRouteLogic, Polyline, RouteLine, bearing } from './lib/route.mjs';
import { ApproachCore, PositionBuilder, PositionPublisher, distanceText } from './lib/tracking.mjs';
import { CARS } from './lib/scenario.mjs';
import { loadRoutes } from './generate-gpx.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(here);
const PROJECT_ID = 'ikut-b1083';
const REGION = 'asia-southeast1';

const o = {
  udid: 'C0A40D2A-0607-4B95-A1BE-F8C9190D81C1', // shared iPhone 17: never create or erase simulators
  name: 'Faiz', derivedData: '/tmp/ikut-dd-q1', skipBuild: false, host: '127.0.0.1', speed: 1,
  dryRun: false, noApp: false, seconds: null, waitTimeout: 900, endTrip: false,
  logs: path.join(os.tmpdir(), 'ikut-qa'),
};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  const next = () => process.argv[++i];
  if (a === '--udid') o.udid = next();
  else if (a === '--name') o.name = next();
  else if (a === '--derived-data') o.derivedData = next();
  else if (a === '--skip-build') o.skipBuild = true;
  else if (a === '--host') o.host = next();
  else if (a === '--speed') o.speed = Number(next());
  else if (a === '--dry-run') o.dryRun = true;
  else if (a === '--no-app') o.noApp = true;
  else if (a === '--seconds') o.seconds = Number(next());
  else if (a === '--wait-timeout') o.waitTimeout = Number(next());
  else if (a === '--end-trip') o.endTrip = true;
  else if (a === '-h' || a === '--help') { console.log(spawnSync('sed', ['-n', '2,20p', process.argv[1]], { encoding: 'utf8' }).stdout); process.exit(0); }
  else { console.error(`unknown option ${a}`); process.exit(64); }
}
if (!(o.speed > 0)) { console.error('--speed must be > 0'); process.exit(64); }

// ---------------------------------------------------------------- the world

const ROUTE_LENGTH = 16_300; // m, the trip: phone arrives at ~580 s at 26.4 m/s from 1000 m
const MERGE_AT_OFFSET = 8_900; // where Daniel's road meets the trip route (m along it), between the phone and Hafiz at merge time
const MERGE_TIME = 330; // s
const OWN_SPEED = 22; // m/s on Daniel's own road
const DEMO_END = 620; // s
const PHONE = { start: 1000, speed: 26.4, kmh: 95 };

const { mainCoords, car4Coords } = loadRoutes();
const fullMain = new RouteLine(mainCoords);
const fullOwn = new RouteLine(car4Coords);
const fullMerge = fullMain.mergeOffset(fullOwn, CarRouteLogic.mergeTolerance);
if (!fullMerge) throw new Error('osrm-car4 never joins osrm-main');

function slice(line, a, b) {
  const out = [line.coordinateAtOffset(a)];
  line.coordinates.forEach((c, i) => { if (line.cumulative[i] > a && line.cumulative[i] < b) out.push(c); });
  out.push(line.coordinateAtOffset(b));
  return out;
}
// Start of the piece so that Daniel's merge sits MERGE_AT_OFFSET along it.
const START_OFFSET = fullMerge.mainOffset - MERGE_AT_OFFSET;
if (START_OFFSET < 0 || START_OFFSET + ROUTE_LENGTH > fullMain.length) throw new Error('route piece does not fit osrm-main.json');
const tripCoords = slice(fullMain, START_OFFSET, START_OFFSET + ROUTE_LENGTH);
const main = new RouteLine(tripCoords);
const mainPolyline = Polyline.encode(tripCoords);
const destination = tripCoords[tripCoords.length - 1];
const TRIP_NAME = 'Live demo: Tapah to Ipoh';
const DEST_NAME = 'Demo destination';

// Daniel's plan exactly as the app computes it (CarRouteLogic.makePlan: cut 500 m past the merge).
// osrm-car4 runs on to Ipoh; cut it a few km past the merge so it does not outrun the shortened trip route.
const danielPlan = CarRouteLogic.makePlan(slice(fullOwn, 0, fullMerge.otherOffset + 3000), main);
if (danielPlan?.kind !== 'merges') throw new Error(`Daniel's route does not merge (${danielPlan?.kind})`);
const danielOwn = new RouteLine(Polyline.decode(danielPlan.route));
const danielMerge = main.mergeOffset(danielOwn, CarRouteLogic.mergeTolerance);
const DEPART = MERGE_TIME - danielMerge.otherOffset / OWN_SPEED;

const spec = Object.fromEntries(CARS.map((c) => [c.key, c]));
const CAST = {
  lead: { ...spec.car1, motion: { start: 2200, speed: 27.2, wobble: 25, period: 90, phase: 0 } },
  phone: { key: 'phone', displayName: o.name, motion: { start: PHONE.start, speed: PHONE.speed, wobble: 0, period: 1, phase: 0 } },
  hafiz: { ...spec.car3, motion: { start: 0, speed: 24.5, wobble: 25, period: 110, phase: 1.3 } },
  daniel: { ...spec.car4, motion: null },
};
const DROP = { from: 150, to: 270 };

/** Offset along the trip route of a main-route car at scenario time t. Stops at the destination. */
function offsetOf(who, t) {
  if (who === 'daniel') return Math.min(ROUTE_LENGTH, danielAt(t).main ?? danielMerge.mainOffset);
  const m = CAST[who].motion;
  const wob = m.wobble ? m.wobble * (Math.sin((2 * Math.PI * t) / m.period + m.phase) - Math.sin(m.phase)) : 0;
  return Math.min(ROUTE_LENGTH, Math.max(0, m.start + m.speed * Math.max(0, t) + wob));
}
/** Daniel: [own-road offset or null, trip offset or null] */
function danielAt(t) {
  const s = Math.max(0, t - DEPART) * OWN_SPEED;
  if (s <= danielMerge.otherOffset) return { own: s, main: null };
  const sinceMerge = t - MERGE_TIME;
  return { own: danielMerge.otherOffset + Math.max(0, sinceMerge) * 25.5, main: danielMerge.mainOffset + Math.max(0, sinceMerge) * 25.5, merged: true };
}
function fixAt(who, t) {
  const at = (tt) => {
    if (who === 'daniel') {
      const d = danielAt(tt);
      if (d.main === null) return danielOwn.coordinateAtOffset(d.own);
      return main.coordinateAtOffset(Math.min(ROUTE_LENGTH, d.main));
    }
    return main.coordinateAtOffset(offsetOf(who, tt));
  };
  const now = at(t);
  const prev = at(Math.max(0, t - 1));
  const next = at(t + 0.5);
  const dist = Math.hypot((next.latitude - prev.latitude) * 111_000, (next.longitude - prev.longitude) * 111_000 * Math.cos(now.latitude * Math.PI / 180));
  const speed = dist / (t === 0 ? 0.5 : 1.5);
  const moving = speed > 0.5;
  return { latitude: now.latitude, longitude: now.longitude, speed: moving ? speed : 0, course: moving ? bearing(prev.latitude === now.latitude && prev.longitude === now.longitude ? now : prev, next) : -1 };
}

// ---------------------------------------------------------------- the script

const km = (m) => (m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m / 10) * 10} m`);
const ahead = (who, t) => {
  const d = offsetOf(who, t) - offsetOf('phone', t);
  return d >= 0 ? `${km(d)} ahead of you` : `${km(-d)} behind you`;
};
const phoneAtT = (offset) => (offset - PHONE.start) / PHONE.speed;
const HAZARD_AT = 90;
const hazardOffset = offsetOf('lead', HAZARD_AT);
const ALERT_AT = Math.round(phoneAtT(hazardOffset - 500));
const STOP_AT = 390;
const stopPlaceOffset = () => offsetOf('lead', STOP_AT) + 3000;
const ARRIVE_AT = Math.round(phoneAtT(ROUTE_LENGTH));

const timeline = [
  { at: 0, text: () => `GO. Order: Aisha ${ahead('lead', 0)}, you (Faiz), Hafiz ${ahead('hafiz', 0)}; Daniel is still on his own road (dashed "joining")` },
  { at: 45, text: (t) => `convoy spread is ${km(offsetOf('lead', t) - offsetOf('hafiz', t))} and growing (Aisha fastest, Hafiz slowest)` },
  { at: HAZARD_AT, text: (t) => `Aisha reports debris ${ahead('lead', t)}`,
    run: async (c) => { c.hazard = await c.cars.lead.reportEvent('debris', 'hazard', 'high', 45 * 60); } },
  { at: ALERT_AT, text: () => 'EXPECTED ON PHONE: approach alert, "Debris ahead in 500 meters"', note: true },
  { at: Math.round(DEPART), text: () => 'Daniel leaves his own road and heads for the ramp (nothing visible changes yet)', note: true },
  { at: DROP.from, text: (t) => `Hafiz loses signal (${ahead('hafiz', t)}); he keeps driving but cannot report`, run: async (c) => { await disableNetwork(c.cars.hafiz.db); } },
  { at: DROP.from + 60, text: () => 'EXPECTED ON PHONE: Hafiz row goes stale, "Last seen ..."', note: true },
  { at: DROP.to, text: () => 'Hafiz gets signal back, his position jumps to where he is now', run: async (c) => { await enableNetwork(c.cars.hafiz.db); } },
  { at: MERGE_TIME, text: () => `Daniel reaches the merge point and joins the convoy between you and Hafiz (dashed to solid; he ends up ${ahead('daniel', MERGE_TIME)})`, note: true },
  { at: STOP_AT, text: () => `Hafiz requests a pit stop (fuel) and proposes "R&R Demo" ${km(stopPlaceOffset() - offsetOf('phone', STOP_AT))} ahead of you`,
    run: async (c) => {
      const r = await c.cars.hafiz.reportEvent('stopFuel', 'stopRequest', 'medium', null);
      const off = stopPlaceOffset();
      const co = main.coordinateAtOffset(off);
      c.stop = r;
      c.place = { name: 'R&R Demo', coordinate: new GeoPoint(co.latitude, co.longitude), routeOffset: off };
      await c.cars.hafiz.vote(r.id, true, c.place);
    } },
  { at: 400, text: () => 'Aisha votes yes', run: async (c) => { await c.cars.lead.vote(c.stop.id, true); } },
  { at: 410, text: () => 'Daniel votes yes', run: async (c) => { await c.cars.daniel.vote(c.stop.id, true); } },
  { at: 425, text: () => 'Aisha (lead) pins "R&R Demo" as the stop; the phone can vote too', run: async (c) => { await c.cars.lead.pin(c.stop.id, c.place); } },
  { at: 500, text: () => 'Aisha resolves the stop request, it disappears', run: async (c) => { await c.cars.lead.resolve(c.stop.id); } },
  { at: ARRIVE_AT, text: () => 'You reach the destination (arrival)', note: true },
  { at: DEMO_END, text: () => 'END of scripted demo' },
];
timeline.sort((a, b) => a.at - b.at);

const mmss = (t) => `${String(Math.floor(t / 60)).padStart(2, '0')}:${String(Math.round(t % 60)).padStart(2, '0')}`;
const lineFor = (e) => `T+${String(e.at).padStart(3, ' ')}s (${mmss(e.at)}): ${e.text(e.at)}`;

function printPlan() {
  console.log(`Route: ${(ROUTE_LENGTH / 1000).toFixed(1)} km piece of the E1 starting ${(START_OFFSET / 1000).toFixed(1)} km into osrm-main.json, ${tripCoords.length} points`);
  console.log(`Phone: starts ${PHONE.start} m along, ${PHONE.kmh} km/h (${PHONE.speed} m/s), at ${main.coordinateAtOffset(PHONE.start).latitude.toFixed(5)},${main.coordinateAtOffset(PHONE.start).longitude.toFixed(5)}`);
  console.log(`Daniel: own road ${(danielMerge.otherOffset / 1000).toFixed(1)} km, merges ${danielMerge.mainOffset.toFixed(0)} m along the trip (planned ${MERGE_AT_OFFSET}), leaves at T+${DEPART.toFixed(0)}s`);
  console.log('Timeline:');
  for (const e of timeline) console.log(`  ${lineFor(e)}${e.note ? '   [no action, a cue to watch for]' : ''}`);
}

function sanity() {
  const problems = [];
  if (Math.abs(danielMerge.mainOffset - MERGE_AT_OFFSET) > 150) problems.push(`merge at ${danielMerge.mainOffset.toFixed(0)} m, wanted ${MERGE_AT_OFFSET}`);
  if (DEPART < 5) problems.push(`Daniel would have to leave at T+${DEPART.toFixed(0)}s`);
  const p = offsetOf('phone', MERGE_TIME);
  const h = offsetOf('hafiz', DROP.to > MERGE_TIME ? MERGE_TIME : MERGE_TIME);
  const m = danielMerge.mainOffset;
  if (!(p > m && h < m)) problems.push(`at the merge the phone is at ${p.toFixed(0)} m and Hafiz at ${h.toFixed(0)} m, Daniel merges at ${m.toFixed(0)} m: not between`);
  if (offsetOf('lead', 400) < stopPlaceOffset() - 3000 || stopPlaceOffset() > ROUTE_LENGTH - 300) problems.push('stop place is not on the route');
  if (offsetOf('phone', 500) > stopPlaceOffset()) problems.push('phone passes the stop place before it is resolved');
  if (ARRIVE_AT > DEMO_END - 15) problems.push(`phone arrives at T+${ARRIVE_AT}s, too close to the end`);
  if (ALERT_AT < HAZARD_AT) problems.push('approach alert would fire before the hazard is reported');
  console.log(`Total ${mmss(DEMO_END)} min. Geometry: ${problems.length ? 'PROBLEMS\n  - ' + problems.join('\n  - ') : 'ok'}`);
  return problems.length === 0;
}

if (o.dryRun) {
  printPlan();
  process.exit(sanity() ? 0 : 1);
}

// ---------------------------------------------------------------- scripted cars (Firebase), as in convoy-sim.mjs

const wallStart = Date.now();
const clock = { T: -1e6 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(clock.T >= 0 ? `[T+${String(Math.round(clock.T)).padStart(3, ' ')}s]` : `[+${String(Math.round((Date.now() - wallStart) / 1000)).padStart(3, ' ')}s ]`, ...a);

class Car {
  constructor(who) { this.who = who; this.s = CAST[who]; this.state = 'joining'; this.events = []; this.approach = new ApproachCore(); }

  async connect() {
    this.app = initializeApp({ apiKey: 'qa-fake-key', projectId: PROJECT_ID, appId: `demo-${this.who}` }, `demo-${this.who}`);
    const auth = getAuth(this.app);
    connectAuthEmulator(auth, `http://${o.host}:9099`, { disableWarnings: true });
    this.db = initializeFirestore(this.app, {});
    connectFirestoreEmulator(this.db, o.host, 8080);
    this.fns = getFunctions(this.app, REGION);
    connectFunctionsEmulator(this.fns, o.host, 5001);
    this.uid = (await signInAnonymously(auth)).user.uid;
  }

  async createTrip(code) {
    const tripRef = doc(collection(this.db, 'trips'));
    this.tripId = tripRef.id;
    const carRef = doc(collection(this.db, `trips/${this.tripId}/cars`));
    const batch = writeBatch(this.db);
    batch.set(tripRef, {
      name: TRIP_NAME, code, organizerId: this.uid, route: mainPolyline,
      destination: { name: DEST_NAME, coordinate: new GeoPoint(destination.latitude, destination.longitude) },
      status: 'active', createdAt: serverTimestamp(),
    });
    batch.set(doc(this.db, `trips/${this.tripId}/members/${this.uid}`), { displayName: this.s.displayName, carId: carRef.id, role: 'organizer' });
    await batch.commit();
    await setDoc(carRef, { name: this.s.name, color: this.s.color, trackerUserId: this.uid, isLead: true, state: 'convoy', number: 1 });
    this.carId = carRef.id;
    this.state = 'convoy';
  }

  async join(code) {
    const res = await httpsCallable(this.fns, 'joinTrip')({ code, displayName: this.s.displayName, car: { newCar: { name: this.s.name, color: this.s.color } }, tracker: true });
    this.tripId = res.data.tripId;
    this.carId = res.data.carId;
    if (res.data.trackerTaken) throw new Error(`${this.who}: tracker already taken`);
  }

  async ensureRoute(firstFix) {
    let plan = CarRouteLogic.planIfOnMain(firstFix, main);
    if (!plan) plan = danielPlan; // the app asks MapKit; the OSRM snapshot stands in
    await this.writePlan(plan);
    this.plan = plan;
    this.own = plan.route ? new RouteLine(Polyline.decode(plan.route)) : null;
    this.ownMerge = this.own ? main.mergeOffset(this.own, CarRouteLogic.mergeTolerance)?.otherOffset ?? null : null;
    this.ownHint = null;
    this.builder = new PositionBuilder(main, this.own);
    this.publisher = new PositionPublisher({ write: (p) => this.writePosition(p), now: () => clock.T });
  }

  writePlan(plan) {
    this.state = plan.state;
    return updateDoc(doc(this.db, `trips/${this.tripId}/cars/${this.carId}`), {
      route: plan.route ?? deleteField(), mergeOffset: plan.mergeOffset ?? deleteField(), state: plan.state,
    });
  }

  writePosition(p) {
    const data = { location: new GeoPoint(p.latitude, p.longitude), speed: p.speed, heading: p.heading, routeOffset: p.routeOffset, updatedAt: serverTimestamp() };
    if (p.convoyOffset !== undefined) data.convoyOffset = p.convoyOffset;
    if (p.battery !== null && p.battery !== undefined) data.battery = p.battery;
    return setDoc(doc(this.db, `trips/${this.tripId}/positions/${this.carId}`), data);
  }

  startListening() {
    this.unsubscribe = onSnapshot(collection(this.db, `trips/${this.tripId}/events`), (snap) => { this.events = snap.docs.map((d) => ({ id: d.id, ...d.data() })); });
  }

  onFix(fix, battery) {
    this.lastFix = fix;
    this.lastPosition = this.builder.build(fix, battery);
    this.publisher.submit(this.lastPosition);
    // CarRouteService.handle, merge part: mark the car convoy at the merge point.
    if (this.state === 'joining' && this.own && this.ownMerge !== null && !this.merging) {
      const p = this.own.project(fix, { hint: this.ownHint });
      this.ownHint = p ? p.segmentIndex : null;
      if (p && p.offset >= this.ownMerge) {
        this.merging = true;
        log('Daniel reached his merge point, marking his car convoy (dashed to solid on the phone)');
        this.writePlan({ route: Polyline.encode(this.own.coordinates), mergeOffset: this.plan.mergeOffset, state: 'convoy' }).catch((e) => log(`markMerged failed: ${e.message}`));
      }
    }
  }

  async reportEvent(type, category, severity, expirySeconds) {
    const fix = this.lastFix;
    const here = { latitude: fix.latitude, longitude: fix.longitude };
    const prev = this.lastPosition.routeOffset;
    const routeOffset = main.project(here, { hint: segmentIndexAt(prev) })?.offset ?? prev;
    const createdAt = new Date();
    const data = {
      type, category, severity, location: new GeoPoint(here.latitude, here.longitude), heading: fix.course >= 0 ? fix.course % 360 : 0,
      routeOffset, authorId: this.uid, carId: this.carId, createdAt: Timestamp.fromDate(createdAt),
    };
    if (expirySeconds) data.expiresAt = Timestamp.fromMillis(createdAt.getTime() + expirySeconds * 1000);
    const ref = doc(collection(this.db, `trips/${this.tripId}/events`));
    await setDoc(ref, data);
    return { id: ref.id, routeOffset };
  }

  async vote(eventId, agree, suggestion = null) {
    const data = { userId: this.uid, agree, at: serverTimestamp() };
    if (suggestion) data.suggestion = suggestion;
    await setDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}/votes/${this.carId}`), data);
  }
  pin(eventId, place) { return updateDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}`), { place: { ...place, pinnedBy: this.uid } }); }
  resolve(eventId) { return updateDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}`), { expiresAt: Timestamp.now() }); }

  async close() {
    this.unsubscribe?.();
    this.publisher?.stop();
    await terminate(this.db).catch(() => {});
    await deleteApp(this.app).catch(() => {});
  }
}

function segmentIndexAt(offset) {
  let lo = 0;
  let hi = Math.max(0, main.segmentCount - 1);
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (main.cumulative[mid] <= offset) lo = mid; else hi = mid - 1; }
  return lo;
}

function generateCode() {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  return Array.from({ length: 6 }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join('');
}

// ---------------------------------------------------------------- simulator and app

const simctl = (...args) => spawnSync('xcrun', ['simctl', ...args], { encoding: 'utf8' });
let xc = null;
let feeder = null;
let cars = null;

async function cleanup() {
  clearInterval(feeder);
  if (!o.noApp) simctl('location', o.udid, 'clear');
  if (xc && xc.exitCode === null) xc.kill('SIGTERM');
  if (cars) for (const c of Object.values(cars)) await c.close();
}
process.on('SIGINT', async () => { console.log('\ninterrupted'); await cleanup(); process.exit(130); });

function startApp(code) {
  fs.mkdirSync(o.logs, { recursive: true });
  const line = simctl('list', 'devices').stdout.split('\n').find((l) => l.includes(o.udid));
  if (!line) { console.error(`simulator ${o.udid} not found`); process.exit(1); }
  if (!line.includes('(Booted)')) { log('booting simulator'); simctl('boot', o.udid); simctl('bootstatus', o.udid, '-b'); }
  simctl('privacy', o.udid, 'grant', 'location', 'dev.aqlan.ikut');
  const s = main.coordinateAtOffset(PHONE.start);
  simctl('location', o.udid, 'set', `${s.latitude.toFixed(6)},${s.longitude.toFixed(6)}`);

  const ios = path.join(repo, 'ios');
  const args = ['test', '-project', path.join(ios, 'ikut.xcodeproj'), '-scheme', 'ikut', '-destination', `platform=iOS Simulator,id=${o.udid}`,
    '-derivedDataPath', o.derivedData, '-clonedSourcePackagesDirPath', path.join(o.derivedData, 'SourcePackages'),
    '-only-testing:ikutUITests/JoinAsSecondMemberUITests'];
  if (o.skipBuild) args[0] = 'test-without-building';
  const xcLog = fs.createWriteStream(path.join(o.logs, 'demo-xcodebuild.log'));
  xc = spawn('xcodebuild', args, {
    env: { ...process.env, TEST_RUNNER_IKUT_JOIN_CODE: code, TEST_RUNNER_IKUT_JOIN_NAME: o.name, TEST_RUNNER_IKUT_HOLD_SECONDS: String(Math.round(DEMO_END / o.speed + 240)) },
  });
  let buf = '';
  const on = (d) => {
    xcLog.write(d);
    buf += d.toString();
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const l = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (/Test Case .*(passed|failed)|error:|\*\* TEST|Timed out|XCTAssert/.test(l)) console.log(`  xc | ${l}`);
    }
  };
  xc.stdout.on('data', on);
  xc.stderr.on('data', on);
  log(`xcodebuild ${args[0]} started (log ${path.join(o.logs, 'demo-xcodebuild.log')}); the phone joins as "${o.name}" and stays on the map`);
}

/** `simctl location start` drifts, so restart it every 20 s from where the phone should be (see qa/README.md). */
function startPhoneDrive(goWall) {
  const mps = PHONE.speed * o.speed;
  const feed = () => {
    const T = ((Date.now() - goWall) / 1000) * o.speed;
    const from = offsetOf('phone', T);
    const pts = [];
    for (let off = from; off < ROUTE_LENGTH; off += 80) pts.push(main.coordinateAtOffset(off));
    pts.push(main.coordinateAtOffset(ROUTE_LENGTH));
    if (pts.length < 2 || from >= ROUTE_LENGTH - 1) return;
    const loc = spawn('xcrun', ['simctl', 'location', o.udid, 'start', `--speed=${mps.toFixed(2)}`, '--interval=1', '-']);
    loc.stdin.end(`${pts.map((p) => `${p.latitude.toFixed(6)},${p.longitude.toFixed(6)}`).join('\n')}\n`);
    loc.stderr.on('data', (d) => console.log(`  loc! ${d}`));
  };
  log(`simctl location playback at ${mps.toFixed(1)} m/s (${PHONE.kmh} km/h), resynced every 20 s`);
  feed();
  feeder = setInterval(feed, 20_000);
}

// ---------------------------------------------------------------- main

async function runMain() {
  setLogLevel('error');
  console.log(`ikut live demo, project ${PROJECT_ID}, emulators on ${o.host}${o.noApp ? ', NO APP' : `, simulator ${o.udid}`}, clock ${o.speed}x`);
  printPlan();
  console.log('');
  cars = { lead: new Car('lead'), hafiz: new Car('hafiz'), daniel: new Car('daniel') };
  const code = generateCode();
  await cars.lead.connect();
  await cars.lead.createTrip(code);
  for (const c of [cars.hafiz, cars.daniel]) { await c.connect(); await c.join(code); }
  for (const c of Object.values(cars)) { c.tripId = cars.lead.tripId; }
  console.log(`\nTRIP CODE: ${code}\n`);
  for (const [who, c] of Object.entries(cars)) {
    await c.ensureRoute(fixAt(who, 0));
    c.startListening();
    log(`${c.s.displayName} (${c.s.name}) ready: ${c.plan.kind}, state ${c.plan.state}`);
  }

  // Hold: heartbeat positions at the start until the phone is tracking.
  let k = 0;
  const hold = () => {
    clock.T = -1e5 + k++;
    for (const [who, c] of Object.entries(cars)) { c.onFix({ ...fixAt(who, 0), speed: 0 }, 0.8); c.publisher.tick(); }
  };
  hold();
  if (!o.noApp) {
    startApp(code);
    const known = new Set(Object.values(cars).map((c) => c.carId));
    const deadline = Date.now() + o.waitTimeout * 1000;
    let phoneCar = null;
    log('waiting for the phone to join and start tracking...');
    while (!phoneCar) {
      if (Date.now() > deadline) throw new Error('the phone did not start tracking in time');
      if (xc.exitCode !== null) throw new Error(`xcodebuild exited ${xc.exitCode} before the phone started tracking, see ${path.join(o.logs, 'demo-xcodebuild.log')}`);
      await sleep(1000);
      hold();
      const snap = await getDocs(collection(cars.lead.db, `trips/${cars.lead.tripId}/positions`));
      phoneCar = snap.docs.map((d) => d.id).find((id) => !known.has(id)) ?? null;
    }
    log('the phone is tracking and sitting on the map; starting in 6 s');
    for (let i = 0; i < 6; i++) { await sleep(1000); hold(); }
  } else {
    for (let i = 0; i < 3; i++) { await sleep(1000); hold(); }
  }

  // ---- go
  console.log('\n================ DEMO START ================');
  const goWall = Date.now();
  clock.T = 0;
  if (!o.noApp) startPhoneDrive(goWall);
  const end = o.seconds ?? DEMO_END;
  const ctx = { cars };
  const pending = timeline.filter((e) => e.at <= end).map((e) => ({ ...e, done: false }));
  for (let sec = 0; sec <= end; sec++) {
    const wait = goWall + (sec * 1000) / o.speed - Date.now();
    if (wait > 0) await sleep(wait);
    clock.T = sec;
    for (const [who, c] of Object.entries(cars)) {
      c.onFix(fixAt(who, sec), Math.max(0.2, 0.8 - sec / 6000));
      c.publisher.tick();
    }
    for (const e of pending) {
      if (e.done || sec < e.at) continue;
      e.done = true;
      console.log(`${lineFor(e)}${e.note ? '   [watch]' : ''}`);
      if (e.run) await e.run(ctx).catch((err) => console.log(`  !! ${e.text(e.at)} failed: ${err.message}`));
    }
  }
  console.log('================ DEMO END ================');
  if (o.endTrip) {
    await updateDoc(doc(cars.lead.db, `trips/${cars.lead.tripId}`), { status: 'ended', endedAt: serverTimestamp() });
    log('trip ended');
  }
  if (!o.noApp && xc && xc.exitCode === null) console.log('The app stays open on the map until the UI test hold runs out (about 4 min) or Ctrl-C.');
  await sleep(1500);
  if (!o.noApp && xc && xc.exitCode === null) {
    await new Promise((r) => { xc.on('exit', r); process.once('SIGINT', r); });
  }
  await cleanup();
  process.exit(0);
}

runMain().catch(async (e) => { console.error(`demo failed: ${e.stack ?? e}`); await cleanup().catch(() => {}); process.exit(1); });
