#!/usr/bin/env node
// Multi-car convoy scenario driver for ikut, against the Firebase emulators (project ikut-b1083).
//
//   cd qa && npm install && node convoy-sim.mjs                 # real time, starts 5 s after setup
//   node convoy-sim.mjs --speed 2 --wait-app                    # 2x, wait for a phone to join first
//
// What it does
//   1. Creates a trip the way TripService.createTrip does (organizer = car 1), then joins cars 2-4 through the
//      joinTrip callable the way JoinService does. Every car is its own anonymous Auth user with its own
//      Firestore client, so security rules apply exactly as they do to phones.
//   2. Prints the trip code (`TRIP CODE: ...`) so a simulator can join as the fifth car.
//   3. Plays qa/gpx/car{1..4}.gpx on a scenario clock (1 Hz fixes), turning each fix into a position document
//      with the app's own pipeline (PositionBuilder -> PositionPublisher -> Firestore setDoc).
//   4. At the scripted times (lib/scenario.mjs TIMELINE) posts a hazard, a stop request, votes, a pin, a resolve.
//   5. Car 2's GPX has a 3-minute gap. That is played as the network dropping (disableNetwork), which is what
//      makes a real phone go stale: the SDK keeps one write queued and flushes it on reconnect.
//   6. Sim cars listen to events like phones do and report when ApproachMonitor would announce the hazard.
//   7. Reads everything back as a member and prints PASS / FAIL per check.
//
// Source of each piece of logic is cited in lib/route.mjs and lib/tracking.mjs.
//
// The output always ends in one `RESULT: PASS|FAIL|ABORT` line, also when it stops early or runs past --deadline
// (default: the wait for the phone, the scenario and 300 s; none with --setup-only).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { initializeApp, deleteApp } from 'firebase/app';
import { connectAuthEmulator, getAuth, signInAnonymously } from 'firebase/auth';
import {
  GeoPoint, Timestamp, collection, connectFirestoreEmulator, deleteField, disableNetwork, doc, enableNetwork, setLogLevel,
  getDoc, getDocs, initializeFirestore, onSnapshot, serverTimestamp, setDoc, terminate, updateDoc, writeBatch,
} from 'firebase/firestore';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { CarRouteLogic, Polyline, RouteLine, haversine } from './lib/route.mjs';
import { readGpx, withMotion } from './lib/gpx.mjs';
import { ApproachCore, PositionBuilder, PositionPublisher, distanceText } from './lib/tracking.mjs';
import { CARS, DURATION, FIX_HZ, TIMELINE, TRIP } from './lib/scenario.mjs';
import { loadRoutes } from './generate-gpx.mjs';
import { endsWithResult } from './lib/shell.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ID = 'ikut-b1083';
const REGION = 'asia-southeast1';

// ---------------------------------------------------------------- CLI

function parseArgs(argv) {
  const o = { speed: 1, host: '127.0.0.1', waitApp: false, startIn: 5, goDelay: 5, waitTimeout: 900, deadline: null, endTrip: false, setupOnly: false, state: path.join(os.tmpdir(), 'ikut-qa', 'state.json'), results: path.join(os.tmpdir(), 'ikut-qa', 'results.json'), help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === '--speed') o.speed = Number(next());
    else if (a === '--host') o.host = next();
    else if (a === '--wait-app') o.waitApp = true;
    else if (a === '--start-in') o.startIn = Number(next());
    else if (a === '--go-delay') o.goDelay = Number(next());
    else if (a === '--wait-timeout') o.waitTimeout = Number(next());
    else if (a === '--deadline') o.deadline = Number(next());
    else if (a === '--end-trip') o.endTrip = true;
    else if (a === '--expect-app-vote') o.expectAppVote = true;
    else if (a === '--setup-only') o.setupOnly = true;
    else if (a === '--state-file') o.state = next();
    else if (a === '--results-file') o.results = next();
    else if (a === '-h' || a === '--help') o.help = true;
    else throw new Error(`unknown option ${a}`);
  }
  if (!(o.speed > 0)) throw new Error('--speed must be > 0');
  return o;
}

const opts = parseArgs(process.argv.slice(2));
if (opts.help) {
  console.log(`Usage: node convoy-sim.mjs [options]
  --speed N         play N times faster than real time (default 1). Stale-car checks need N <= 2.5
  --wait-app        after setup wait for a phone to join and start tracking (a position doc from an unknown car), then go
  --go-delay S      with --wait-app: seconds between the phone's first position and go (default 5)
  --start-in S      without --wait-app: seconds between setup and go (default 5)
  --wait-timeout S  with --wait-app: give up waiting after S seconds (default 900)
  --deadline S      stop with RESULT: ABORT after S seconds (default: the wait, the scenario at --speed, and 300)
  --expect-app-vote check that the phone's car voted on the stop request (the UI test taps Agree)
  --end-trip        end the trip when the scenario finishes (default: leave it active)
  --setup-only      create the trip and cars, print the code, write positions as a heartbeat and wait (Ctrl-C to stop)
  --host H          emulator host (default 127.0.0.1)
  --state-file F    JSON with code, tripId and phase, for scripts (default $TMPDIR/ikut-qa/state.json)
  --results-file F  JSON with the check results`);
  process.exit(0);
}
const end = endsWithResult({
  deadlineS: opts.setupOnly ? 0 : opts.deadline ?? (opts.waitApp ? opts.waitTimeout : opts.startIn) + DURATION / opts.speed + 300,
  signals: true,
});

// ---------------------------------------------------------------- logging, clock, checks

const wallStart = Date.now();
const clock = { T: -1e6, label: 'setup' };
const stamp = () => (clock.T < 0 ? `[${clock.label.padEnd(7)}]` : `[T ${clock.T.toFixed(0).padStart(4, '0')}s]`);
const log = (...a) => console.log(stamp(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];

function check(name, pass, detail = '') {
  results.push({ name, pass, detail });
  console.log(`${stamp()} ${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` (${detail})` : ''}`);
}
function skip(name, why) {
  results.push({ name, pass: null, detail: why });
  console.log(`${stamp()} SKIP  ${name} (${why})`);
}

function writeState(patch) {
  fs.mkdirSync(path.dirname(opts.state), { recursive: true });
  const prev = fs.existsSync(opts.state) ? JSON.parse(fs.readFileSync(opts.state, 'utf8')) : {};
  fs.writeFileSync(opts.state, JSON.stringify({ ...prev, ...patch }, null, 2));
}

// ---------------------------------------------------------------- routes and tracks

const { mainCoords, car4Coords } = loadRoutes();
const mainRoute = new RouteLine(mainCoords);
const mainPolyline = Polyline.encode(mainCoords); // Trip.route: precision-5 polyline of the main route

function loadTrack(key) {
  const pts = withMotion(readGpx(path.join(here, 'gpx', `${key}.gpx`)));
  // Fixes by second; a gap (car 2) simply has no entry.
  const bySecond = new Map();
  for (const p of pts) bySecond.set(Math.round(p.t * FIX_HZ), p);
  return { points: pts, bySecond };
}

/** Offset along the main route of each GPX point, to know where a car "really" is at a scenario time. */
function truthOffsets(points) {
  let hint = null;
  return points.map((p) => {
    const pr = mainRoute.project(p, { hint });
    hint = pr.segmentIndex;
    return { t: p.t, offset: pr.offset, distance: pr.distance };
  });
}
function interpolate(series, t) {
  if (t <= series[0].t) return series[0].offset;
  for (let i = 1; i < series.length; i++) {
    if (series[i].t >= t) {
      const a = series[i - 1];
      const b = series[i];
      return a.offset + ((b.offset - a.offset) * (t - a.t)) / (b.t - a.t);
    }
  }
  return series[series.length - 1].offset;
}

// ---------------------------------------------------------------- Firebase phones

class Phone {
  constructor(spec) {
    this.spec = spec;
    this.key = spec.key;
    this.events = [];
    this.alerts = [];
    this.approach = new ApproachCore();
    this.lastPosition = null;
    this.lastFix = null;
    this.state = 'joining';
  }

  async connect(tripId = null) {
    this.app = initializeApp({ apiKey: 'qa-fake-key', projectId: PROJECT_ID, appId: `qa-${this.key}` }, `qa-${this.key}`);
    const auth = getAuth(this.app);
    connectAuthEmulator(auth, `http://${opts.host}:9099`, { disableWarnings: true });
    this.db = initializeFirestore(this.app, {});
    connectFirestoreEmulator(this.db, opts.host, 8080);
    this.fns = getFunctions(this.app, REGION);
    connectFunctionsEmulator(this.fns, opts.host, 5001);
    const cred = await signInAnonymously(auth);
    this.uid = cred.user.uid;
    this.tripId = tripId;
  }

  // ---- TripService.createTrip (ios/ikut/Trip/TripService.swift)
  async createTrip(code) {
    const tripRef = doc(collection(this.db, 'trips'));
    this.tripId = tripRef.id;
    const carRef = doc(collection(this.db, `trips/${this.tripId}/cars`));
    const batch = writeBatch(this.db);
    batch.set(tripRef, {
      name: TRIP.name, code, organizerId: this.uid, route: mainPolyline,
      destination: { name: TRIP.destination.name, coordinate: new GeoPoint(TRIP.destination.latitude, TRIP.destination.longitude) },
      status: 'active', createdAt: serverTimestamp(),
    });
    batch.set(doc(this.db, `trips/${this.tripId}/members/${this.uid}`), { displayName: this.spec.displayName, carId: carRef.id, role: 'organizer' });
    await batch.commit();
    // The car goes in a second write: rules only let existing members create cars (see TripService).
    await setDoc(carRef, { name: this.spec.name, color: this.spec.color, trackerUserId: this.uid, isLead: true, state: 'convoy', number: 1 });
    this.carId = carRef.id;
    this.state = 'convoy';
  }

  // ---- JoinService.join (ios/ikut/Join/JoinService.swift): callable joinTrip, new car, tracker true
  async join(code) {
    const call = httpsCallable(this.fns, 'joinTrip');
    const res = await call({ code, displayName: this.spec.displayName, car: { newCar: { name: this.spec.name, color: this.spec.color } }, tracker: true });
    this.tripId = res.data.tripId;
    this.carId = res.data.carId;
    if (res.data.trackerTaken) throw new Error(`${this.key}: tracker already taken`);
  }

  // ---- CarRouteService.ensureRoute / FirestoreCarRouteWriter (ios/ikut/CarRoute/CarRouteService.swift)
  async writeCarPlan(plan) {
    await updateDoc(doc(this.db, `trips/${this.tripId}/cars/${this.carId}`), {
      route: plan.route ?? deleteField(),
      mergeOffset: plan.mergeOffset ?? deleteField(),
      state: plan.state,
    });
    this.state = plan.state;
  }

  async ensureRoute(firstFix) {
    let plan = CarRouteLogic.planIfOnMain(firstFix, mainRoute);
    if (!plan) {
      // The app asks MapKit for a route to the destination; the snapshot of the OSRM route stands in for it.
      plan = CarRouteLogic.makePlan(car4Coords, mainRoute);
    }
    await this.writeCarPlan(plan);
    this.plan = plan;
    this.own = plan.route ? new RouteLine(Polyline.decode(plan.route)) : null;
    this.ownMergeOffset = this.own ? mainRoute.mergeOffset(this.own, CarRouteLogic.mergeTolerance)?.otherOffset ?? null : null;
    this.ownHint = null;
    this.builder = new PositionBuilder(mainRoute, this.own);
    this.publisher = new PositionPublisher({ write: (p) => this.writePosition(p), now: () => clock.T });
    return plan;
  }

  // ---- FirestorePositionWriter (ios/ikut/Tracking/TrackingTypes.swift): setData, updatedAt = server timestamp
  writePosition(p) {
    const data = {
      location: new GeoPoint(p.latitude, p.longitude), speed: p.speed, heading: p.heading, routeOffset: p.routeOffset,
      updatedAt: serverTimestamp(),
    };
    if (p.convoyOffset !== undefined) data.convoyOffset = p.convoyOffset;
    if (p.battery !== null && p.battery !== undefined) data.battery = p.battery;
    return setDoc(doc(this.db, `trips/${this.tripId}/positions/${this.carId}`), data);
  }

  startListening() {
    // AlertCenter / ApproachMonitor read the same events collection.
    this.unsubscribe = onSnapshot(collection(this.db, `trips/${this.tripId}/events`), (snap) => {
      this.events = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
      for (const c of snap.docChanges()) {
        if (c.type === 'added') (this.firstSeen ??= {})[c.doc.id] ??= { T: clock.T, wall: Date.now() };
      }
    });
  }

  /** One GPS fix: TrackingService.handle -> PositionBuilder -> PositionPublisher, then CarRouteService.handle. */
  onFix(fix, battery) {
    this.lastFix = fix;
    const position = this.builder.build(fix, battery);
    this.lastPosition = position;
    this.publisher.submit(position);
    this.#carRouteHandle(fix);
    this.#approach(position);
  }

  // CarRouteService.handle, merge part only: the off-route detector is not exercised (tracks stay on their roads).
  #carRouteHandle(fix) {
    if (this.state !== 'joining' || !this.own || this.ownMergeOffset === null || this.merging) return;
    const p = this.own.project(fix, { hint: this.ownHint });
    this.ownHint = p ? p.segmentIndex : null;
    if (p && p.offset >= this.ownMergeOffset) {
      this.merging = true;
      this.mergedAt = clock.T;
      log(`${this.key} reached its merge point, marking the car convoy`);
      // markMerged: route re-encoded, mergeOffset kept, state convoy.
      this.writeCarPlan({ route: Polyline.encode(this.own.coordinates), mergeOffset: this.plan.mergeOffset, state: 'convoy' })
        .catch((e) => log(`${this.key} markMerged failed: ${e.message}`));
    }
  }

  // ApproachMonitor.update (ios/ikut/Hazards/ApproachMonitor.swift)
  #approach(position) {
    const onMain = position.convoyOffset !== undefined;
    const route = onMain ? mainRoute : this.own;
    if (!route) return;
    const myOffset = position.convoyOffset ?? position.routeOffset;
    const candidates = [];
    const byId = new Map();
    for (const ev of this.events) {
      if (!(ev.category === 'hazard' || ev.category === 'condition')) continue;
      if (ev.expiresAt && ev.expiresAt.toMillis() <= Date.now()) continue;
      if (ev.carId === this.carId || ev.authorId === this.uid) continue;
      const pr = route.project({ latitude: ev.location.latitude, longitude: ev.location.longitude });
      if (!pr || pr.distance > 50) continue;
      candidates.push({ id: ev.id, offset: pr.offset });
      byId.set(ev.id, ev);
    }
    for (const fire of this.approach.evaluate(candidates, myOffset)) {
      const ev = byId.get(fire.id);
      const label = { debris: 'Debris', accident: 'Accident' }[ev.type] ?? ev.type;
      const alert = { T: clock.T, eventId: fire.id, distance: fire.distance, title: `${label} ahead in ${distanceText(fire.distance)}` };
      this.alerts.push(alert);
      log(`${this.key} approach alert: "${alert.title}" (${fire.distance.toFixed(0)} m ahead)`);
    }
  }

  // ---- EventService.report (ios/ikut/Events/EventService.swift)
  async reportEvent(type, category, severity, expirySeconds) {
    const fix = this.lastFix;
    const here = { latitude: fix.latitude, longitude: fix.longitude };
    const prev = this.lastPosition.routeOffset;
    const hint = segmentIndexAtOffset(mainRoute, prev);
    const routeOffset = mainRoute.project(here, { hint })?.offset ?? prev;
    const createdAt = new Date();
    const data = {
      type, category, severity, location: new GeoPoint(here.latitude, here.longitude),
      heading: fix.course >= 0 ? fix.course % 360 : 0, routeOffset,
      authorId: this.uid, carId: this.carId, createdAt: Timestamp.fromDate(createdAt),
    };
    if (expirySeconds) data.expiresAt = Timestamp.fromMillis(createdAt.getTime() + expirySeconds * 1000);
    const ref = doc(collection(this.db, `trips/${this.tripId}/events`));
    await setDoc(ref, data);
    return { id: ref.id, data, here, routeOffset };
  }

  // ---- StopService.vote / pin / resolve (ios/ikut/Stops/StopService.swift)
  async vote(eventId, agree, suggestion = null) {
    const data = { userId: this.uid, agree, at: serverTimestamp() };
    if (suggestion) data.suggestion = suggestion;
    await setDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}/votes/${this.carId}`), data);
  }
  async pin(eventId, place) {
    await updateDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}`), { place: { ...place, pinnedBy: this.uid } });
  }
  async resolve(eventId) {
    await updateDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}`), { expiresAt: Timestamp.now() });
  }

  async close() {
    this.unsubscribe?.();
    this.publisher?.stop();
    await terminate(this.db).catch(() => {});
    await deleteApp(this.app).catch(() => {});
  }
}

// EventService.segmentIndex(in:atOffset:)
function segmentIndexAtOffset(route, offset) {
  if (route.segmentCount === 0) return 0;
  let lo = 0;
  let hi = route.segmentCount - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (route.cumulative[mid] <= offset) lo = mid; else hi = mid - 1;
  }
  return lo;
}

// TripService.codeAlphabet: A-Z and 2-9 without O, I, L.
function generateCode() {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  return Array.from({ length: 6 }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join('');
}

// ---------------------------------------------------------------- main

async function main() {
  const specs = CARS.filter((c) => c.kind !== 'app');
  const phones = new Map(specs.map((s) => [s.key, new Phone(s)]));
  const organizer = phones.get('car1');
  const code = generateCode();

  console.log(`ikut convoy simulator, project ${PROJECT_ID}, emulators on ${opts.host}, speed ${opts.speed}x`);
  console.log(`main route ${(mainRoute.length / 1000).toFixed(1)} km, ${mainCoords.length} points, polyline ${mainPolyline.length} chars`);

  // ---- setup
  await organizer.connect();
  await organizer.createTrip(code);
  for (const spec of specs.slice(1)) {
    const p = phones.get(spec.key);
    await p.connect();
    await p.join(code);
  }
  const tripId = organizer.tripId;
  for (const p of phones.values()) p.tripId = tripId;
  console.log(`\nTRIP CODE: ${code}\n`);
  console.log(`@@CODE ${code}`);
  writeState({ code, tripId, phase: 'setup', speed: opts.speed, cars: Object.fromEntries([...phones.values()].map((p) => [p.key, { carId: p.carId, uid: p.uid }])) });

  // Tracks and truth.
  const tracks = {};
  const truth = {};
  for (const c of CARS) {
    tracks[c.key] = loadTrack(c.key);
    truth[c.key] = truthOffsets(tracks[c.key].points);
  }

  // Tracker start-up: first fix, ensureRoute, then tracking (TripSession.runStartup).
  for (const p of phones.values()) {
    const first = tracks[p.key].points[0];
    const plan = await p.ensureRoute(first);
    log(`${p.key} (${p.spec.name}) ${p.carId}: ${plan.kind}, state ${plan.state}, mergeOffset ${plan.mergeOffset.toFixed(0)} m${plan.route ? `, own route ${plan.route.length} chars` : ''}`);
    p.startListening();
  }

  // Rules probes: things a client must not be able to do.
  await rulesProbes(phones, tripId);

  // ---- hold: heartbeat positions at the first fix until go
  const prerollFix = (key) => ({ ...tracks[key].points[0], speed: 0 });
  let k = 0;
  const hold = async () => {
    clock.T = -1e5 + k++;
    for (const p of phones.values()) {
      p.onFix(prerollFix(p.key), 0.8);
      p.publisher.tick();
    }
  };
  await hold();

  let appCarId = null;
  clock.label = 'hold';
  if (opts.setupOnly) {
    console.log('setup only: holding positions. Ctrl-C to stop.');
    writeState({ phase: 'hold' });
    for (;;) { await sleep(1000); await hold(); }
  }
  if (opts.waitApp) {
    console.log('@@READY');
    console.log(`waiting for a phone to join trip ${code} and start tracking (up to ${opts.waitTimeout} s)...`);
    writeState({ phase: 'waiting-for-app' });
    const known = new Set([...phones.values()].map((p) => p.carId));
    const deadline = Date.now() + opts.waitTimeout * 1000;
    while (!appCarId) {
      if (Date.now() > deadline) throw new Error('no phone started tracking in time');
      await sleep(1000);
      await hold();
      const snap = await getDocs(collection(organizer.db, `trips/${tripId}/positions`));
      appCarId = snap.docs.map((d) => d.id).find((id) => !known.has(id)) ?? null;
    }
    log(`phone car ${appCarId} is tracking; go in ${opts.goDelay} s`);
    for (let i = 0; i < opts.goDelay; i++) { await sleep(1000); await hold(); }
  } else {
    console.log('@@READY');
    for (let i = 0; i < opts.startIn; i++) { await sleep(1000); await hold(); }
  }

  // ---- go
  console.log('@@GO');
  writeState({ phase: 'running', goAt: new Date().toISOString(), appCarId });
  clock.T = 0;
  clock.label = 'drive';
  const goWall = Date.now();
  const timeline = TIMELINE.map((e) => ({ ...e, done: false }));
  const scheduled = scheduleChecks({ phones, tracks, truth, tripId, organizer, getAppCarId: () => appCarId });
  const ctx = { phones, tripId, organizer, tracks, truth, stopEvent: null, hazard: null, hazardAt: null };
  const gapCar = phones.get('car2');
  const gap = gapCar.spec.gap;

  for (let sec = 0; sec <= DURATION * FIX_HZ; sec++) {
    const T = sec / FIX_HZ;
    const wait = goWall + (T * 1000) / opts.speed - Date.now();
    if (wait > 0) await sleep(wait);
    clock.T = T;

    // Network drop: the last fix before the gap has been written; the next write never completes until we reconnect.
    if (gap && T === gap.from + 1) { await disableNetwork(gapCar.db); log(`car2 loses signal (no fixes until T=${gap.to})`); }
    if (gap && T === gap.to) { await enableNetwork(gapCar.db); log('car2 regains signal, queued write flushes'); }

    for (const p of phones.values()) {
      const fix = tracks[p.key].bySecond.get(sec);
      if (fix) p.onFix(fix, Math.max(0.2, 0.8 - T / 6000));
      p.publisher.tick();
    }
    for (const ev of timeline) {
      if (!ev.done && T >= ev.at) { ev.done = true; await runTimeline(ev, ctx).catch((e) => check(`timeline ${ev.do} by ${ev.car}`, false, e.message)); }
    }
    for (const s of scheduled) {
      if (!s.done && T >= s.at) { s.done = true; await s.run(ctx).catch((e) => check(s.name, false, `threw: ${e.message}`)); }
    }
  }

  // ---- wrap up
  await sleep(1500);
  await finalChecks(ctx, appCarId);

  if (opts.endTrip) {
    await updateDoc(doc(organizer.db, `trips/${tripId}`), { status: 'ended', endedAt: serverTimestamp() });
    log('trip ended');
  }
  const failed = results.filter((r) => r.pass === false);
  const passed = results.filter((r) => r.pass === true);
  const skipped = results.filter((r) => r.pass === null);
  console.log(`\n${passed.length} passed, ${failed.length} failed, ${skipped.length} skipped`);
  console.log(`@@DONE pass=${passed.length} fail=${failed.length} skip=${skipped.length}`);
  fs.mkdirSync(path.dirname(opts.results), { recursive: true });
  fs.writeFileSync(opts.results, JSON.stringify({ code, tripId, speed: opts.speed, results }, null, 2));
  writeState({ phase: 'done' });
  for (const p of phones.values()) await p.close();
  end.result(!failed.length);
  process.exit(failed.length ? 1 : 0);
}

// ---------------------------------------------------------------- timeline actions

async function runTimeline(ev, ctx) {
  const p = ctx.phones.get(ev.car);
  if (ev.do === 'hazard') {
    ctx.hazardWall = Date.now();
    const r = await p.reportEvent(ev.type, 'hazard', 'high', 45 * 60); // EventCategory.hazard: severity high, expires in 45 min
    ctx.hazard = r;
    ctx.hazardAt = clock.T;
    log(`${p.key} reports ${ev.type} at ${r.routeOffset.toFixed(0)} m (${r.here.latitude.toFixed(5)}, ${r.here.longitude.toFixed(5)}), event ${r.id}`);
  } else if (ev.do === 'stopRequest') {
    const r = await p.reportEvent(ev.type, 'stopRequest', 'medium', null); // stop requests have no expiry
    ctx.stopEvent = r;
    const front = Math.max(...[...ctx.phones.values()].map((x) => x.lastPosition?.convoyOffset ?? 0));
    const offset = front + ev.placeAheadOfFront;
    const c = mainRoute.coordinateAtOffset(offset);
    ctx.place = { name: ev.placeName, coordinate: new GeoPoint(c.latitude, c.longitude), routeOffset: offset };
    // StopService.request: the requester's proposal goes in as an agreeing vote carrying the place.
    await p.vote(r.id, true, ctx.place);
    log(`${p.key} requests a stop (${ev.type}) and proposes "${ev.placeName}" at ${offset.toFixed(0)} m, event ${r.id}`);
  } else if (ev.do === 'pinStop') {
    await p.pin(ctx.stopEvent.id, ctx.place);
    log(`${p.key} (lead) pins "${ctx.place.name}"`);
  } else if (ev.do === 'vote') {
    await p.vote(ctx.stopEvent.id, ev.agree);
    log(`${p.key} votes ${ev.agree ? 'yes' : 'no'}`);
  } else if (ev.do === 'resolveStop') {
    await p.resolve(ctx.stopEvent.id);
    ctx.stopResolvedAt = clock.T;
    log(`${p.key} (lead) resolves the stop request`);
  }
}

// ---------------------------------------------------------------- rules probes

async function rulesProbes(phones, tripId) {
  const car2 = phones.get('car2');
  const car1 = phones.get('car1');
  setLogLevel('silent'); // the SDK logs every denied write; they are expected here
  const rejected = async (name, fn) => {
    try { await fn(); check(name, false, 'write was accepted'); } catch (e) { check(name, /permission|PERMISSION/.test(`${e.code} ${e.message}`), e.code); }
  };
  const base = { location: new GeoPoint(4.1, 101.3), speed: 1, heading: 10, routeOffset: 0, updatedAt: serverTimestamp() };
  await rejected('rules: a car cannot write another car\'s position', () => setDoc(doc(car2.db, `trips/${tripId}/positions/${car1.carId}`), base));
  await rejected('rules: heading 360 is rejected', () => setDoc(doc(car2.db, `trips/${tripId}/positions/${car2.carId}`), { ...base, heading: 360 }));
  await rejected('rules: a position with a client timestamp is rejected', () => setDoc(doc(car2.db, `trips/${tripId}/positions/${car2.carId}`), { ...base, updatedAt: Timestamp.now() }));
  setLogLevel('error');
}

// ---------------------------------------------------------------- scheduled checks

/** What the convoy list should read at scenario time T, from the GPX truth (ConvoyOrdering rules). */
function expectedConvoyOrder(T, { truth, phones, appPresent }) {
  const rows = [];
  for (const spec of CARS) {
    if (spec.kind === 'app' && !appPresent) continue;
    let at = T;
    if (spec.gap && T > spec.gap.from + 6 && T < spec.gap.to) at = spec.gap.from; // offline: the list shows the last position that reached the server
    if (spec.kind === 'merge') {
      const p = phones.get(spec.key);
      if (!p.mergedAt || T < p.mergedAt + 2) continue; // joining: not in the convoy list
    }
    rows.push({ key: spec.key, offset: interpolate(truth[spec.key], at) });
  }
  return rows.sort((a, b) => b.offset - a.offset);
}

async function readPositions(organizer, tripId) {
  const snap = await getDocs(collection(organizer.db, `trips/${tripId}/positions`));
  return new Map(snap.docs.map((d) => [d.id, d.data({ serverTimestamps: 'estimate' })]));
}

function scheduleChecks({ phones, tripId, organizer }) {
  const keyByCar = () => new Map([...phones.values()].map((p) => [p.carId, p.key]));
  const gap = CARS.find((c) => c.key === 'car2').gap;
  const speedOk = opts.speed <= 2.5;

  const orderCheck = (at, label, extraWait = 0) => ({
    at: at + extraWait,
    name: label,
    async run(ctx) {
      const positions = await readPositions(organizer, tripId);
      const appCarId = readAppCarId();
      const names = keyByCar();
      if (appCarId) names.set(appCarId, 'car5-app');
      const actual = [...positions.entries()]
        .filter(([, p]) => p.convoyOffset !== undefined && p.convoyOffset !== null)
        .map(([id, p]) => ({ key: names.get(id) ?? id, offset: p.convoyOffset }))
        .sort((a, b) => b.offset - a.offset);
      const joining = [...positions.entries()].filter(([, p]) => p.convoyOffset === undefined || p.convoyOffset === null).map(([id]) => names.get(id) ?? id);
      const expected = expectedConvoyOrder(clock.T, { truth: ctx.truth, phones, appPresent: Boolean(appCarId) });
      const fmt = (rows) => rows.map((r) => `${r.key}@${(r.offset / 1000).toFixed(1)}k`).join(' > ');
      const ok = fmt(actual.map((r) => ({ ...r }))).replace(/@[\d.]+k/g, '') === fmt(expected).replace(/@[\d.]+k/g, '');
      check(label, ok, `convoy ${fmt(actual)}; joining [${joining.join(', ')}]; expected ${fmt(expected).replace(/@[\d.]+k/g, '')}`);
    },
  });
  const readAppCarId = () => {
    try { return JSON.parse(fs.readFileSync(opts.state, 'utf8')).appCarId ?? null; } catch { return null; }
  };

  // Every 30 scenario seconds: where the phone is relative to its GPX, to see how far simctl playback lags.
  const progress = [];
  for (let at = 30; at <= DURATION; at += 30) {
    progress.push({
      at, name: `progress at T=${at}`,
      async run(ctx) {
        const appCarId = readAppCarId();
        if (!appCarId) return;
        const d = (await readPositions(organizer, tripId)).get(appCarId);
        if (!d) return log('phone has no position yet');
        const expected = interpolate(ctx.truth['car5-app'], clock.T);
        const off = d.convoyOffset ?? d.routeOffset;
        log(`phone at ${off.toFixed(0)} m, GPX says ${expected.toFixed(0)} m (${((expected - off) / 27.4).toFixed(0)} s behind), ${(d.speed * 3.6).toFixed(0)} km/h`);
      },
    });
  }

  return [
    ...progress,
    {
      at: 20, name: 'positions arrive for every sim car and match the GPX',
      async run(ctx) {
        const positions = await readPositions(organizer, tripId);
        for (const p of phones.values()) {
          const doc_ = positions.get(p.carId);
          if (!doc_) { check(`position doc exists: ${p.key}`, false, 'missing'); continue; }
          const age = (Date.now() - doc_.updatedAt.toMillis()) / 1000;
          const tol = 250; // throttled to 5 s: up to ~150 m behind
          if (p.spec.kind === 'merge') {
            // Off the main route: compare the stored location with the GPX point instead of a main-route offset.
            const pt = ctx.tracks[p.key].points.find((q) => q.t >= clock.T);
            const d = haversine({ latitude: doc_.location.latitude, longitude: doc_.location.longitude }, pt);
            check(`${p.key} position fresh and on track`, age < 20 / opts.speed + 12 && d < tol, `age ${age.toFixed(0)} s, ${d.toFixed(0)} m from the GPX point, routeOffset ${doc_.routeOffset.toFixed(0)} of own-route merge at ${p.ownMergeOffset.toFixed(0)}`);
            continue;
          }
          const expected = interpolate(ctx.truth[p.key], clock.T);
          const off = doc_.convoyOffset ?? doc_.routeOffset;
          check(`${p.key} position fresh and on track`, age < 20 / opts.speed + 12 && Math.abs(off - expected) < tol, `age ${age.toFixed(0)} s, convoyOffset ${off.toFixed(0)} vs truth ${expected.toFixed(0)}`);
        }
        const c4 = positions.get(phones.get('car4').carId);
        check('car4 starts joining: position has no convoyOffset', c4 && c4.convoyOffset === undefined, JSON.stringify(c4 && Object.keys(c4)));
        const car4Doc = (await getDoc(doc(organizer.db, `trips/${tripId}/cars/${phones.get('car4').carId}`))).data();
        check('car4 doc: state joining with route and mergeOffset', car4Doc.state === 'joining' && typeof car4Doc.route === 'string' && Math.abs(car4Doc.mergeOffset - 14666) < 100, `mergeOffset ${car4Doc.mergeOffset?.toFixed(0)}, route ${car4Doc.route?.length} chars`);
        const car3Doc = (await getDoc(doc(organizer.db, `trips/${tripId}/cars/${phones.get('car3').carId}`))).data();
        check('car3 doc: state convoy after ensureRoute, no own route', car3Doc.state === 'convoy' && car3Doc.route === undefined, `state ${car3Doc.state}`);
      },
    },
    orderCheck(60, 'order at T=60: 1 > 2 > 3 (> app), car4 joining'),
    {
      at: gap.to - 5, name: 'signal drop: car2 is stale before it recovers',
      async run() {
        if (!speedOk) return skip('signal drop: car2 stale (server age > 60 s)', `needs speed <= 2.5, ran at ${opts.speed}x`);
        const positions = await readPositions(organizer, tripId);
        const d = positions.get(phones.get('car2').carId);
        const age = (Date.now() - d.updatedAt.toMillis()) / 1000;
        check('signal drop: car2 position older than 60 s while offline', age > 60, `age ${age.toFixed(0)} s, frozen at convoyOffset ${d.convoyOffset.toFixed(0)}`);
      },
    },
    orderCheck(gap.to - 5, 'order during the drop: car2 frozen at its last position'),
    {
      at: gap.to + 12, name: 'signal drop: car2 recovers',
      async run(ctx) {
        const positions = await readPositions(organizer, tripId);
        const d = positions.get(phones.get('car2').carId);
        const age = (Date.now() - d.updatedAt.toMillis()) / 1000;
        const expected = interpolate(ctx.truth.car2, clock.T);
        check('signal drop: car2 fresh again and back at its real position', age < 15 / Math.min(1, opts.speed) && Math.abs(d.convoyOffset - expected) < 300, `age ${age.toFixed(0)} s, convoyOffset ${d.convoyOffset.toFixed(0)} vs truth ${expected.toFixed(0)}`);
      },
    },
    orderCheck(425, 'order after car4 merges: 1 > 2 > 4 > 3 (> app)', 25),
    {
      at: 440, name: 'car4 merged',
      async run(ctx) {
        const car4 = phones.get('car4');
        const doc_ = (await getDoc(doc(organizer.db, `trips/${tripId}/cars/${car4.carId}`))).data();
        const pos = (await readPositions(organizer, tripId)).get(car4.carId);
        check('car4 merge: car doc state convoy', doc_.state === 'convoy', `state ${doc_.state}`);
        check('car4 merge: position now carries convoyOffset', pos.convoyOffset !== undefined, `convoyOffset ${pos.convoyOffset?.toFixed(0)}`);
        check('car4 merged at the scripted time', car4.mergedAt !== undefined && Math.abs(car4.mergedAt - 408) < 6, `merged at T=${car4.mergedAt}`);
      },
    },
    {
      at: 540, name: 'hazard posted and received',
      async run(ctx) {
        if (!ctx.hazard) return check('hazard posted', false, 'not posted');
        const snap = await getDoc(doc(organizer.db, `trips/${tripId}/events/${ctx.hazard.id}`));
        const d = snap.data();
        check('hazard event stored with the app\'s shape', d.category === 'hazard' && d.severity === 'high' && d.type === 'debris' && d.expiresAt.toMillis() - d.createdAt.toMillis() === 45 * 60 * 1000 && d.carId === phones.get('car1').carId, JSON.stringify(Object.keys(d)));
        for (const key of ['car2', 'car3', 'car4']) {
          const seen = phones.get(key).firstSeen?.[ctx.hazard.id];
          const latency = seen ? (seen.wall - ctx.hazardWall) / 1000 : null;
          check(`hazard reaches ${key}'s listener within 5 s`, latency !== null && latency < 5, latency === null ? 'never' : `${latency.toFixed(1)} s`);
        }
      },
    },
    orderCheck(560, 'order at T=560'),
    {
      at: 780, name: 'stop request lifecycle (open)',
      async run(ctx) {
        const se = ctx.stopEvent;
        if (!se) return check('stop request posted', false, 'not posted');
        const ev = (await getDoc(doc(organizer.db, `trips/${tripId}/events/${se.id}`))).data();
        check('stop request open with pinned place', ev.category === 'stopRequest' && ev.expiresAt === undefined && ev.place?.name === ctx.place.name && ev.place?.pinnedBy === phones.get('car1').uid, JSON.stringify(ev.place));
        const votes = await getDocs(collection(organizer.db, `trips/${tripId}/events/${se.id}/votes`));
        const byCar = new Map(votes.docs.map((v) => [v.id, v.data()]));
        check('stop votes: requester (with suggestion), car2, car4', byCar.size >= 3 && byCar.get(phones.get('car3').carId)?.suggestion?.name === ctx.place.name && byCar.get(phones.get('car2').carId)?.agree === true && byCar.get(phones.get('car4').carId)?.agree === true, `${byCar.size} votes`);
      },
    },
    {
      at: 790, name: 'phone car votes on the stop request',
      async run(ctx) {
        const appCarId = readAppCarId();
        if (!opts.expectAppVote || !appCarId || !ctx.stopEvent) return skip('phone car voted on the stop request', 'no phone, or --expect-app-vote not given');
        const v = await getDoc(doc(organizer.db, `trips/${tripId}/events/${ctx.stopEvent.id}/votes/${appCarId}`));
        check('phone car voted yes on the stop request', v.exists() && v.data().agree === true, v.exists() ? JSON.stringify({ agree: v.data().agree, userId: v.data().userId }) : 'no vote document');
      },
    },
  ];
}

async function finalChecks(ctx, appCarId) {
  const { phones, tripId, organizer, truth } = ctx;
  clock.label = 'final';
  const T = DURATION;

  // Stop resolved.
  if (ctx.stopEvent) {
    const ev = (await getDoc(doc(organizer.db, `trips/${tripId}/events/${ctx.stopEvent.id}`))).data();
    check('stop request resolved (expiresAt set by the lead)', ev.expiresAt !== undefined && ev.expiresAt.toMillis() <= Date.now(), '');
  }

  // Approach alerts: who should hear about the hazard, and when.
  if (ctx.hazard) {
    const H = ctx.hazard.routeOffset;
    for (const key of ['car2', 'car3', 'car4']) {
      const p = phones.get(key);
      let predicted = null;
      for (let t = 0; t <= T; t++) {
        const off = interpolate(truth[key], t);
        const d = H - off;
        if (t >= ctx.hazardAt && d > 0 && d <= 500) { predicted = t; break; }
      }
      const got = p.alerts.filter((a) => a.eventId === ctx.hazard.id);
      const ok = got.length === 1 && predicted !== null && Math.abs(got[0].T - predicted) <= 4 && got[0].distance <= 500 && got[0].distance > 380;
      check(`approach alert: ${key} warned once, ~500 m before the hazard`, ok, got.length ? `at T=${got[0].T}, ${got[0].distance.toFixed(0)} m, predicted T=${predicted}; "${got[0].title}"` : `no alert, predicted T=${predicted}`);
    }
    check('approach alert: the reporter (car1) is not warned about its own hazard', phones.get('car1').alerts.length === 0, '');
    if (appCarId) {
      const off = (t) => interpolate(truth['car5-app'], t);
      let predicted = null;
      for (let t = ctx.hazardAt; t <= T; t++) { const d = H - off(t); if (d > 0 && d <= 500) { predicted = t; break; } }
      log(`the phone (car5) should announce "Debris ahead in 500 meters" about T=${predicted} (assuming it follows car5-app.gpx without lag)`);
    }
  }

  // The phone's own car.
  if (appCarId) {
    const positions = await readPositions(organizer, tripId);
    const mine = positions.get(appCarId);
    const carDoc = (await getDoc(doc(organizer.db, `trips/${tripId}/cars/${appCarId}`))).data();
    check('phone car: position document written by the app', Boolean(mine), mine ? `routeOffset ${mine.routeOffset.toFixed(0)}, convoyOffset ${mine.convoyOffset?.toFixed(0)}, speed ${(mine.speed * 3.6).toFixed(0)} km/h` : 'missing');
    if (mine) check('phone car: convoyOffset set, so it is in the convoy list', typeof mine.convoyOffset === 'number', '');
    check('phone car: car doc state convoy, tracker set', carDoc.state === 'convoy' && Boolean(carDoc.trackerUserId), `state ${carDoc.state}, number ${carDoc.number}`);
  }
}

main().catch((e) => {
  console.error(`${stamp()} FATAL ${e.stack ?? e}`);
  process.exit(2);
});
