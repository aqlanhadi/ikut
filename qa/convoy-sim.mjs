#!/usr/bin/env node
// Multi-car convoy scenario driver for ikut, against the Firebase emulators (project ikut-b1083).
//
//   cd qa && npm install && node convoy-sim.mjs                 # fast (about 3 min), starts 5 s after setup
//   node convoy-sim.mjs --speed 1 --wait-app                    # real time, wait for a phone to join first
//
// What it does
//   1. Creates a trip the way TripService.createTrip does (organizer = car 1), then joins cars 2-4 through the
//      joinTrip callable the way JoinService does. Every car is its own anonymous Auth user with its own
//      Firestore client, so security rules apply exactly as they do to phones.
//   2. Prints the trip code (`TRIP CODE: ...`) so a simulator can join as the fifth car.
//   3. Plays qa/gpx/car{1..4}.gpx on a scenario clock (1 Hz fixes), turning each fix into a position document
//      with the app's own pipeline (PositionBuilder -> PositionPublisher -> Firestore setDoc).
//   4. At the scripted times (lib/scenario.mjs TIMELINE) posts a hazard, a stop request with a message, two OKs, We've stopped.
//   5. Car 2's GPX has a 3-minute gap. That is played as the network dropping (disableNetwork), which is what
//      makes a real phone go stale: the SDK keeps one write queued and flushes it on reconnect.
//   6. Sim cars listen to events like phones do and report when ApproachMonitor would announce the hazard.
//   7. Reads everything back as a member and prints PASS / FAIL per check.
//   8. With --scenario parked (D26), car 6 and the phone are parked on the route far ahead of the convoy and drive on
//      once it comes by. They are in the convoy all along. Car 6 plays that car's phone (lib/farahead.mjs): who the
//      arrival time comes from, which gaps would warn, the heads-up when the lead is about 2 minutes away, and how an
//      early stop request from car 3, 17 km behind, is spoken.
//
//   9. With --scenario stop (D25 piece 3b), the organizer writes a planned stop (R&R Tapah, 20 km along) and cars 1-4 pull in
//      and park at it. Car 1's phone reads the stop and everyone's positions (lib/stoparrival.mjs) and must count each
//      car as here when it is within 150 m, ending at "4 of 4 here". No phone car: no --wait-app.
//
//  10. With --scenario rebuild (D25 4d), the organizer skips a town stop off the highway for everyone and rebuilds the route
//      through the stops ahead in one batch; the cars follow it. See qa/README.md, *The drive*.
//
// Source of each piece of logic is cited in lib/route.mjs and lib/tracking.mjs.
//
// Speed: without a phone (no --wait-app) it plays at 10x by default, slowing to 2x for car 2's signal drop, the one
// stretch that has to last in real seconds (the server judges staleness after 60 s). With --wait-app it plays at one
// steady --speed (default 2), since the phone's playback can't follow a changing clock. 1x is for people watching.
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
  deleteDoc, getDoc, getDocs, initializeFirestore, onSnapshot, serverTimestamp, setDoc, terminate, updateDoc, writeBatch,
} from 'firebase/firestore';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { CarRouteLogic, Polyline, RouteLine, haversine } from './lib/route.mjs';
import { readGpx, withMotion } from './lib/gpx.mjs';
import { ApproachCore, PositionBuilder, PositionPublisher, distanceText } from './lib/tracking.mjs';
import { DURATION, FIX_HZ, REBUILD, SCENARIOS, STOP, STOP_NEXT, TRIP, appKey, scenarioCars, scenarioTimeline } from './lib/scenario.mjs';
import { ON_ROUTE_TOLERANCE, distinctValues, rebuildRoute, staleReads, syntheticTrack, townDetour } from './lib/rebuild.mjs';
import { CatchUpHeadsUp, LEAD_TIME, catchUpSpoken, driftedGaps, entries, referenceId, relativeDistance, spokenStopRequest, togetherPairs } from './lib/farahead.mjs';
import { tally as stopTally } from './lib/stoparrival.mjs';
import { isOpen, leavingAt, nextStop } from './lib/stopleave.mjs';
import { loadRoutes } from './generate-gpx.mjs';
import { endsWithResult } from './lib/shell.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ID = 'ikut-b1083';
const REGION = 'asia-southeast1';

// ---------------------------------------------------------------- CLI

function parseArgs(argv) {
  const o = { speed: null, host: '127.0.0.1', waitApp: false, startIn: 5, goDelay: 5, waitTimeout: 900, deadline: null, endTrip: false, setupOnly: false, scenario: 'drive', state: path.join(os.tmpdir(), 'ikut-qa', 'state.json'), results: path.join(os.tmpdir(), 'ikut-qa', 'results.json'), help: false };
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
    else if (a === '--expect-app-ok') o.expectAppOk = true;
    else if (a === '--setup-only') o.setupOnly = true;
    else if (a === '--scenario') o.scenario = next();
    else if (a === '--state-file') o.state = next();
    else if (a === '--results-file') o.results = next();
    else if (a === '-h' || a === '--help') o.help = true;
    else throw new Error(`unknown option ${a}`);
  }
  o.speed ??= o.waitApp ? 2 : 10;
  if (!(o.speed > 0)) throw new Error('--speed must be > 0');
  if (!SCENARIOS.includes(o.scenario)) throw new Error(`unknown scenario ${o.scenario} (${SCENARIOS.join(' or ')})`);
  return o;
}

const opts = parseArgs(process.argv.slice(2));
if (opts.help) {
  console.log(`Usage: node convoy-sim.mjs [options]
  --speed N         play N times faster than real time (default 10, or 2 with --wait-app). Above 2, car 2's
                    signal drop still plays at 2x so the stale check runs. 1 for real time, when a person watches
  --wait-app        after setup wait for a phone to join and start tracking (a position doc from an unknown car), then go
  --go-delay S      with --wait-app: seconds between the phone's first position and go (default 5)
  --start-in S      without --wait-app: seconds between setup and go (default 5)
  --wait-timeout S  with --wait-app: give up waiting after S seconds (default 900)
  --deadline S      stop with RESULT: ABORT after S seconds (default: the wait, the scenario at --speed, and 300)
  --expect-app-ok   check that the phone's car said OK to the stop request (the UI test taps OK)
  --end-trip        end the trip when the scenario finishes (default: leave it active)
  --scenario S      drive (default), parked (car 6 and the phone parked on the route far ahead, D26) stop (the cars pull in at a planned stop, D25) or rebuild (a skipped town stop rebuilds the route, D25 4d)
  --setup-only      create the trip and cars, print the code, write positions as a heartbeat and wait (Ctrl-C to stop)
  --host H          emulator host (default 127.0.0.1)
  --state-file F    JSON with code, tripId and phase, for scripts (default $TMPDIR/ikut-qa/state.json)
  --results-file F  JSON with the check results`);
  process.exit(0);
}
const CARS = scenarioCars(opts.scenario);
const APP_KEY = appKey(opts.scenario);
const STOPPING = opts.scenario === 'stop';
const REBUILDING = opts.scenario === 'rebuild';
if ((STOPPING || REBUILDING) && opts.waitApp) throw new Error(`the ${opts.scenario} scenario has no phone car: run it without --wait-app`);
// IKUT_QA_BREAK=<name> breaks the rebuild scenario on purpose, to see its check fail (qa/README.md, *What is checked*).
const BREAK = REBUILDING ? process.env.IKUT_QA_BREAK ?? '' : '';
/** Seconds of drive: the whole scripted drive, or the rebuild's. */
const RUN = REBUILDING ? REBUILD.duration : DURATION;
/** Cars parked on the route ahead of the convoy (the parked scenario). */
const PARKED = CARS.filter((c) => c.waitOffset !== undefined);

// The scenario clock. Without a phone, car 2's signal drop (and the checks just after it) plays at no more than 2x:
// staleness is judged on the server clock after 60 real seconds, which a 3-minute gap only reaches at <= 2.5x.
const dropGap = CARS.find((c) => c.key === 'car2')?.gap;
const speedAt = (T) => (!opts.waitApp && dropGap && T >= dropGap.from - 5 && T < dropGap.to + 15 ? Math.min(opts.speed, 2) : opts.speed);
/** Real seconds from go to scenario time T. */
function wallAt(T) {
  let w = 0;
  for (let t = 0; t < T; t++) w += Math.min(1, T - t) / speedAt(t);
  return w;
}

const end = endsWithResult({
  deadlineS: opts.setupOnly ? 0 : opts.deadline ?? (opts.waitApp ? opts.waitTimeout : opts.startIn) + wallAt(RUN) + 300,
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
// The rebuild scenario plans the trip through a town stop off the highway: the trip's route is the road with the loop
// (`tripLine`, which each phone follows, and changes when the organizer rebuilds), the highway itself stays the truth.
const detour = REBUILDING ? townDetour(mainRoute, { from: REBUILD.turnOff, to: REBUILD.rejoin, bulge: REBUILD.bulge }) : null;
const tripPolyline = detour ? Polyline.encode(detour.coordinates) : mainPolyline;
let tripLine = detour ? new RouteLine(Polyline.decode(tripPolyline)) : mainRoute;

function loadTrack(key, spec) {
  const pts = withMotion(spec.synthetic ? syntheticTrack(mainRoute, { startOffset: spec.startOffset, speed: spec.speed, seconds: RUN }) : readGpx(path.join(here, 'gpx', `${key}.gpx`)));
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
      name: TRIP.name, code, organizerId: this.uid, route: tripPolyline,
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
    let plan = CarRouteLogic.planIfOnMain(firstFix, tripLine);
    if (!plan) {
      // The app asks MapKit for a route to the destination; the snapshot of the OSRM route stands in for it.
      plan = CarRouteLogic.makePlan(car4Coords, mainRoute);
    }
    await this.writeCarPlan(plan);
    this.plan = plan;
    this.own = plan.route ? new RouteLine(Polyline.decode(plan.route)) : null;
    this.ownMergeOffset = this.own ? mainRoute.mergeOffset(this.own, CarRouteLogic.mergeTolerance)?.otherOffset ?? null : null;
    this.ownHint = null;
    this.builder = new PositionBuilder(tripLine, this.own);
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
    (this.writes ??= []).push({ T: clock.T, wall: Date.now(), convoyOffset: p.convoyOffset });
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

  // ---- Who is at the planned stop (D25 piece 3b): StopArrival.tally on the stop and everyone's positions.
  watchStops() {
    this.allStops = [];
    this.arrivals = new Map(); // carId -> first T it counted as here
    this.firstFull = null;
    this.lastTally = null;
    this.nextTrail = []; // {T, name}: what Next stop read, each time it changed
    this.stopsError = null;
    this.unsubStops = onSnapshot(collection(this.db, `trips/${this.tripId}/stops`), (snap) => {
      this.allStops = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
      const mine = this.allStops.find((s) => s.routeOffset === STOP.offset);
      if (mine?.leftAt && !this.leftSeen) this.leftSeen = { T: clock.T, wall: Date.now() };
    }, (err) => { this.stopsError = err; log(`${this.key}'s stops listener failed: ${err.code ?? err.message}`); });
  }

  /** The planned stop the cars pull in at (not the one after it). */
  get arrivalStop() { return this.allStops?.find((s) => s.routeOffset === STOP.offset && s.skipped !== true); }

  /** Every car as StopArrival.tally takes it: where it is, its offset, how old the fix is. */
  tallyCars(now) {
    return [...this.cars.entries()].map(([id, c]) => {
      const p = this.positions.get(id);
      return {
        id, number: c.number, location: p ? { latitude: p.location.latitude, longitude: p.location.longitude } : undefined,
        offset: typeof p?.convoyOffset === 'number' ? p.convoyOffset : null,
        age: p?.updatedAt ? Math.max(0, (now - p.updatedAt.toMillis()) / 1000) : null, speed: Math.max(5, p?.speed ?? 0),
      };
    });
  }

  // ---- The rebuilt route (D25 4d), as each phone sees it: the trip's route and every stop's offset as they change, and
  // the route a car follows from then on (the session restarts on the new route).
  watchRebuild() {
    this.routes = []; // what trips/{id}.route read, each time it changed
    this.stopDocs = new Map(); // id -> the stop as last read
    this.stopOffsets = new Map(); // id -> every routeOffset it read, in order
    this.unsubTrip = onSnapshot(doc(this.db, `trips/${this.tripId}`), (snap) => {
      const route = snap.data()?.route;
      if (!route || this.routes.at(-1)?.route === route) return;
      this.routes.push({ T: clock.T, route });
      if (this.routes.length < 2 || BREAK === 'nobody-swaps' || (BREAK === 'parked-stays-old' && this.key === 'car3')) return;
      let line = new RouteLine(Polyline.decode(route));
      // The line behind the organizer lost (the kept stretch not kept): car 2 reads offsets from the cut on.
      if (BREAK === 'car2-prefix-lost' && this.key === 'car2') line = new RouteLine(line.coordinates.filter((_, i) => line.cumulative[i] >= 8_300));
      const swap = () => { this.builder = new PositionBuilder(line); this.swapWall = Date.now(); };
      if (BREAK === 'parked-late' && this.key === 'car3') setTimeout(swap, 8_000); else swap();
    });
    this.unsubRebuildStops = onSnapshot(collection(this.db, `trips/${this.tripId}/stops`), (snap) => {
      for (const d of snap.docs) {
        this.stopDocs.set(d.id, { id: d.id, ...d.data(), coordinate: { latitude: d.data().coordinate.latitude, longitude: d.data().coordinate.longitude } });
        (this.stopOffsets.get(d.id) ?? this.stopOffsets.set(d.id, []).get(d.id)).push(d.data().routeOffset);
      }
    });
  }

  /** Car 1's phone, every tick: how the stop card would read the parked car at the stop ahead (StopArrival.status). */
  judgeNext(parkedCarId) {
    const stop = this.stopDocs?.get(rebuildPlan?.nextId);
    if (!stop || !this.positions?.size || !this.cars.size) return;
    const target = { latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude, routeOffset: stop.routeOffset, isMeeting: false };
    const row = stopTally(target, this.tallyCars(Date.now())).rows.find((r) => r.id === parkedCarId);
    (this.parkedReads ??= []).push({ T: clock.T, kind: row.status.kind });
  }

  judgeArrival() {
    const stop = this.arrivalStop;
    if (!stop || !this.positions?.size || !this.cars.size) return;
    const now = Date.now();
    const target = { latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude, routeOffset: stop.routeOffset, isMeeting: stop.kind === 'meet' };
    const t = stopTally(target, this.tallyCars(now));
    for (const r of t.rows) {
      if (r.status.kind === 'here' && !this.arrivals.has(r.id)) { this.arrivals.set(r.id, clock.T); log(`${this.key}'s phone: ${this.names.get(r.id)} is here, "${t.title}"`); }
      // The lead car's phone marks when it first counted itself here (TripMapModel.checkLeadArrival), once.
      if (r.id === this.carId && r.status.kind === 'here' && !this.arrivedWrite) {
        this.arrivedWrite = updateDoc(doc(this.db, `trips/${this.tripId}/stops/${stop.id}`), { arrivedAt: serverTimestamp() })
          .then(() => { this.arrivedWall = Date.now(); log(`${this.key}'s phone marks its arrival at ${STOP.name}`); }, (e) => { this.arrivedError = e; });
      }
    }
    if (!this.firstFull && t.total > 0 && t.here === t.total) this.firstFull = { T: clock.T, title: t.title, wall: now };
    this.lastTally = t;
    const mineOffset = this.positions.get(this.carId)?.convoyOffset;
    if (typeof mineOffset === 'number') {
      const name = nextStop(this.allStops, mineOffset)?.name ?? null;
      if (this.nextTrail.at(-1)?.name !== name) this.nextTrail.push({ T: clock.T, name });
    }
  }

  /** The lead car taps Leave once all four are here (StopLeaveService.leave): the stop is done for everyone. */
  async maybeLeave() {
    if (!this.firstFull || this.leaving || !this.arrivalStop) return;
    this.leaving = true;
    await this.arrivedWrite; // "Leaving at" counts from it; Leave is tapped after the lead car was counted
    // arrivedAt is written once: a second write, even by the lead car, is refused.
    setLogLevel('silent');
    try { await updateDoc(doc(this.db, `trips/${this.tripId}/stops/${this.arrivalStop.id}`), { arrivedAt: serverTimestamp() }); this.arrivedTwice = true; } catch (e) { this.arrivedTwice = false; this.arrivedTwiceCode = e.code; }
    setLogLevel('error');
    this.leaveT = clock.T;
    this.leaveWall = Date.now();
    await updateDoc(doc(this.db, `trips/${this.tripId}/stops/${this.arrivalStop.id}`), { leftAt: serverTimestamp(), leftBy: this.uid });
    log(`${this.key} (lead) taps Leave at ${STOP.name} with "${this.firstFull.title}"`);
  }

  // ---- A parked car's phone (D26): ConvoyModel / TripMapModel on every convoy update, from everyone's positions.
  watchConvoy(names) {
    this.positions = new Map();
    this.cars = new Map();
    this.names = names; // carId -> displayName
    this.together = new Set();
    this.headsUp = new CatchUpHeadsUp();
    this.headsUps = [];
    this.references = new Map(); // reference key -> ticks
    this.parkedWarnings = [];
    this.otherWarnings = new Set();
    this.stopWords = new Map(); // eventId -> {T, spoken, distance}
    this.unsubPositions = onSnapshot(collection(this.db, `trips/${this.tripId}/positions`), (snap) => {
      this.positions = new Map(snap.docs.map((d) => [d.id, d.data({ serverTimestamps: 'estimate' })]));
    });
    this.unsubCars = onSnapshot(collection(this.db, `trips/${this.tripId}/cars`), (snap) => {
      this.cars = new Map(snap.docs.map((d) => [d.id, d.data()]));
    });
  }

  /** After every tick, like the map's model. parkedIds: cars still parked ahead (for the warning check). */
  judgeConvoy(parkedIds, keyOf) {
    if (!this.positions?.size || !this.cars.size) return;
    const now = Date.now();
    const convoy = entries([...this.positions.entries()]
      .filter(([id, p]) => typeof p.convoyOffset === 'number' && this.cars.has(id))
      .map(([id, p]) => ({
        id, name: this.cars.get(id).name, isLead: Boolean(this.cars.get(id).isLead), offset: p.convoyOffset, speed: p.speed,
        age: p.updatedAt ? Math.max(0, (now - p.updatedAt.toMillis()) / 1000) : 0,
        // TripSessionLogic.isPaused (pausedAt younger than 30 min) and ConvoyArrival.hasArrived (within 150 m of the end):
        // the app leaves both out of the ETA reference, and a paused car is not fresh.
        paused: isPausedAt(this.cars.get(id).pausedAt, now),
        arrived: p.convoyOffset >= mainRoute.length - 150,
      })));
    this.together = new Set([...this.together, ...togetherPairs(convoy)]);
    const ref = referenceId(convoy);
    const refKey = ref ? keyOf(ref) : 'none';
    this.references.set(refKey, (this.references.get(refKey) ?? 0) + 1);
    const ids = convoy.map((e) => e.id);
    for (const id of driftedGaps(convoy, this.together)) {
      const i = ids.indexOf(id);
      const pair = `${keyOf(ids[i - 1])} | ${keyOf(id)}`;
      if (parkedIds.has(id) || parkedIds.has(ids[i - 1])) this.parkedWarnings.push({ T: clock.T, pair });
      else if (!this.otherWarnings.has(pair)) { this.otherWarnings.add(pair); (this.warningTrail ??= []).push({ T: clock.T, pair }); log(`${this.key}'s phone would warn about the gap ${pair}`); }
    }
    const due = this.headsUp.check(convoy, this.carId);
    if (due) {
      this.headsUps.push({ T: clock.T, ...due, spoken: catchUpSpoken(due), key: keyOf(due.carId) });
      log(`${this.key} heads-up: "${catchUpSpoken(due)}" (${due.distance.toFixed(0)} m, ${due.seconds.toFixed(0)} s away)`);
    }
    const mine = this.positions.get(this.carId)?.convoyOffset;
    for (const ev of this.events) {
      if (ev.category !== 'stopRequest' || this.stopWords.has(ev.id) || ev.carId === this.carId) continue;
      const theirs = this.positions.get(ev.carId)?.convoyOffset;
      if (typeof mine !== 'number' || typeof theirs !== 'number') continue;
      const distance = theirs - mine;
      const spoken = spokenStopRequest(ev.type, this.names.get(ev.carId), relativeDistance(distance));
      this.stopWords.set(ev.id, { T: clock.T, spoken, distance });
      log(`${this.key} hears the stop request: "${spoken}"`);
    }
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
  async reportEvent(type, category, severity, expirySeconds, message = null) {
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
    if (message) data.message = message;
    const ref = doc(collection(this.db, `trips/${this.tripId}/events`));
    await setDoc(ref, data);
    return { id: ref.id, data, here, routeOffset };
  }

  // ---- StopService.ok / close (ios/ikut/Stops/StopService.swift)
  async ok(eventId) {
    await setDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}/votes/${this.carId}`), { userId: this.uid, at: serverTimestamp() });
  }
  async markStopped(eventId) {
    await updateDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}`), {
      status: 'closed', closedReason: 'stopped', closedBy: this.uid, expiresAt: Timestamp.now(),
    });
  }

  async close() {
    this.unsubscribe?.();
    this.unsubPositions?.();
    this.unsubCars?.();
    this.unsubStops?.();
    this.unsubTrip?.();
    this.unsubRebuildStops?.();
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

  const slowed = dropGap && speedAt(dropGap.from) < opts.speed ? ` (${speedAt(dropGap.from)}x during car 2's signal drop)` : '';
  console.log(`ikut convoy simulator, project ${PROJECT_ID}, emulators on ${opts.host}, speed ${opts.speed}x${slowed}, about ${Math.round(wallAt(RUN) / 60)} min`);
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
    tracks[c.key] = loadTrack(c.gpx ?? c.key, c);
    truth[c.key] = truthOffsets(tracks[c.key].points);
  }

  // The planned stop, written by the organizer before the start (stops rules; PlannedStop in ios/ikut/Model).
  if (STOPPING) {
    const at = mainRoute.coordinateAtOffset(STOP.offset);
    await setDoc(doc(collection(organizer.db, `trips/${tripId}/stops`)), {
      name: STOP.name, coordinate: new GeoPoint(at.latitude, at.longitude), routeOffset: STOP.offset, kind: STOP.kind, minutes: STOP.minutes, order: 0,
    });
    log(`the organizer plans ${STOP.name} at ${STOP.offset} m`);
    const nextOffset = Math.min(STOP_NEXT.offset, Math.floor(mainRoute.length * 0.8));
    const after = mainRoute.coordinateAtOffset(nextOffset);
    await setDoc(doc(collection(organizer.db, `trips/${tripId}/stops`)), {
      name: STOP_NEXT.name, coordinate: new GeoPoint(after.latitude, after.longitude), routeOffset: nextOffset, kind: STOP_NEXT.kind, minutes: STOP_NEXT.minutes, order: 1,
    });
    log(`the organizer plans ${STOP_NEXT.name} at ${nextOffset} m`);
    // Leave and arrivedAt are for a started trip (TripService.markStarted).
    await updateDoc(doc(organizer.db, `trips/${tripId}`), { startedAt: serverTimestamp() });
  }

  // The rebuild scenario's plan, written before the start: the town stop on the loop, R&R Tapah on the highway past it.
  if (REBUILDING) {
    const plan = async (spec, coordinate, order) => {
      const ref = doc(collection(organizer.db, `trips/${tripId}/stops`));
      const routeOffset = tripLine.project(coordinate).offset;
      await setDoc(ref, { name: spec.name, coordinate: new GeoPoint(coordinate.latitude, coordinate.longitude), routeOffset, kind: spec.kind, minutes: spec.minutes, order });
      log(`the organizer plans ${spec.name} at ${routeOffset.toFixed(0)} m`);
      return { id: ref.id, routeOffset };
    };
    const town = await plan(REBUILD.town, detour.town, 0);
    const next = await plan(REBUILD.next, mainRoute.coordinateAtOffset(REBUILD.next.offset), 1);
    rebuildPlan = { townId: town.id, townOffset: town.routeOffset, nextId: next.id, nextOffset: next.routeOffset, extra: detour.extra };
    await updateDoc(doc(organizer.db, `trips/${tripId}`), { startedAt: serverTimestamp() });
  }

  // Tracker start-up: first fix, ensureRoute, then tracking (TripSession.runStartup).
  for (const p of phones.values()) {
    const first = tracks[p.key].points[0];
    const plan = await p.ensureRoute(first);
    log(`${p.key} (${p.spec.name}) ${p.carId}: ${plan.kind}, state ${plan.state}, mergeOffset ${plan.mergeOffset.toFixed(0)} m${plan.route ? `, own route ${plan.route.length} chars` : ''}`);
    p.startListening();
    if (REBUILDING) p.watchRebuild();
    if (p.spec.waitOffset !== undefined || (STOPPING && p.key === 'car1') || (REBUILDING && (p.key === 'car1' || p.key === 'car2'))) p.watchConvoy(new Map([...phones.values()].map((q) => [q.carId, q.spec.displayName])));
    if (STOPPING && p.key === 'car1') p.watchStops();
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
  const timeline = scenarioTimeline(opts.scenario).map((e) => ({ ...e, done: false }));
  const scheduled = REBUILDING ? scheduleRebuildChecks({ phones, tripId, organizer }) : STOPPING ? [] : scheduleChecks({ phones, tracks, truth, tripId, organizer, getAppCarId: () => appCarId });
  const ctx = { phones, tripId, organizer, tracks, truth, stopEvent: null, hazard: null, hazardAt: null };
  let stopProbed = false;
  const gapCar = phones.get('car2');
  const gap = gapCar.spec.gap;

  for (let sec = 0; sec <= RUN * FIX_HZ; sec++) {
    const T = sec / FIX_HZ;
    const wait = goWall + wallAt(T) * 1000 - Date.now();
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
    if (STOPPING) {
      phones.get('car1').judgeArrival();
      if (T >= 100 && !stopProbed) { stopProbed = true; await stopProbesBefore(phones, tripId).catch((e) => check('rules: stop probes before Leave', false, `threw: ${e.message}`)); }
      await phones.get('car1').maybeLeave().catch((e) => check('car 1 taps Leave', false, `threw: ${e.message}`));
    }
    if (REBUILDING) {
      phones.get('car1').judgeNext(phones.get('car3').carId);
      phones.get('car2').judgeConvoy(new Set(), keyOfCar(phones, null));
    }
    if (PARKED.length) {
      const keyOf = keyOfCar(phones, appCarId);
      const parkedIds = new Set(PARKED.filter((c) => T < departAt(c, truth)).map((c) => (c.kind === 'app' ? appCarId : phones.get(c.key).carId)));
      for (const p of phones.values()) if (p.spec.waitOffset !== undefined) p.judgeConvoy(parkedIds, keyOf);
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

/** The rebuild scenario's stops once planned: {townId, townOffset, nextId, nextOffset, extra (what the loop adds)}. */
let rebuildPlan = null;

const STOP_LIFETIME_SECONDS = 30 * 60; // EventCategory.stopRequest.defaultExpiry

async function runTimeline(ev, ctx) {
  const p = ctx.phones.get(ev.car);
  if (ev.do === 'hazard') {
    ctx.hazardWall = Date.now();
    const r = await p.reportEvent(ev.type, 'hazard', 'high', 45 * 60); // EventCategory.hazard: severity high, expires in 45 min
    ctx.hazard = r;
    ctx.hazardAt = clock.T;
    log(`${p.key} reports ${ev.type} at ${r.routeOffset.toFixed(0)} m (${r.here.latitude.toFixed(5)}, ${r.here.longitude.toFixed(5)}), event ${r.id}`);
  } else if (ev.do === 'stopRequest') {
    // EventCategory.stopRequest: severity medium, closes itself 30 minutes after it was asked.
    const r = await p.reportEvent(ev.type, 'stopRequest', 'medium', STOP_LIFETIME_SECONDS, ev.message);
    ctx.stopEvent = r;
    ctx.stopAt = clock.T;
    ctx.stopCar = ev.car;
    log(`${p.key} asks for a stop (${ev.type}) with the message "${ev.message}", event ${r.id}`);
  } else if (ev.do === 'ok') {
    await p.ok(ctx.stopEvent.id);
    log(`${p.key} says OK`);
  } else if (ev.do === 'markStopped') {
    await p.markStopped(ctx.stopEvent.id);
    ctx.stopResolvedAt = clock.T;
    log(`${p.key} (lead) says we've stopped`);
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

/** The planned stop's id by its offset (read by car 1's phone). */
const stopIdOf = (phones, offset) => phones.get('car1').allStops.find((s) => s.routeOffset === offset)?.id;

/** Before anyone has left (D25 4a rules, seen from the cars): a car that is not the lead car cannot Leave or mark an
 *  arrival; a car still short of the stop can say it will skip it, and take that back. */
async function stopProbesBefore(phones, tripId) {
  const car2 = phones.get('car2');
  const car4 = phones.get('car4');
  const id = stopIdOf(phones, STOP.offset);
  setLogLevel('silent');
  const refused = async (name, fn) => {
    try { await fn(); check(name, false, 'write was accepted'); } catch (e) { check(name, /permission|PERMISSION/.test(`${e.code} ${e.message}`), e.code); }
  };
  await refused('rules: car 2 is not the lead car and cannot Leave the stop', () => updateDoc(doc(car2.db, `trips/${tripId}/stops/${id}`), { leftAt: serverTimestamp(), leftBy: car2.uid }));
  await refused('rules: car 2 cannot mark the lead car as arrived', () => updateDoc(doc(car2.db, `trips/${tripId}/stops/${id}`), { arrivedAt: serverTimestamp() }));
  const answer = doc(car4.db, `trips/${tripId}/stops/${id}/answers/${car4.carId}`);
  try {
    await setDoc(answer, { answer: 'skip', userId: car4.uid, at: serverTimestamp() });
    await deleteDoc(answer);
    check('rules: car 4, still short of the stop, can say it will skip it and take it back', true);
  } catch (e) { check('rules: car 4, still short of the stop, can say it will skip it and take it back', false, e.code); }
  setLogLevel('error');
}

/** After car 1 left: nothing more can be said about the stop. */
async function stopProbesAfter(phones, tripId, organizer) {
  const car4 = phones.get('car4');
  const id = stopIdOf(phones, STOP.offset);
  setLogLevel('silent');
  const refused = async (name, fn) => {
    try { await fn(); check(name, false, 'write was accepted'); } catch (e) { check(name, /permission|PERMISSION/.test(`${e.code} ${e.message}`), e.code); }
  };
  await refused('rules: a stop that was left takes no skip answer', () => setDoc(doc(car4.db, `trips/${tripId}/stops/${id}/answers/${car4.carId}`), { answer: 'skip', userId: car4.uid, at: serverTimestamp() }));
  await refused('rules: a stop that was left cannot be skipped for everyone', () => updateDoc(doc(organizer.db, `trips/${tripId}/stops/${id}`), { skipped: true, skippedBy: organizer.uid, skippedAt: serverTimestamp() }));
  await refused('rules: a stop is left once', () => updateDoc(doc(organizer.db, `trips/${tripId}/stops/${id}`), { leftAt: serverTimestamp(), leftBy: organizer.uid }));
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

/**
 * The convoy list matches the GPX truth: the same cars, and every pair the truth has more than 300 m apart in the
 * same order (closer than that, the 5 s write throttle can swap them; the drive's own cars are 800 m or more apart,
 * a parked car pulling out behind the lead is not).
 */
function sameOrder(actual, expected) {
  const keys = (rows) => rows.map((r) => r.key).sort().join(',');
  if (keys(actual) !== keys(expected)) return false;
  const at = new Map(actual.map((r, i) => [r.key, i]));
  for (let i = 0; i < expected.length; i++) {
    for (let j = i + 1; j < expected.length; j++) {
      if (expected[i].offset - expected[j].offset > 300 && at.get(expected[i].key) > at.get(expected[j].key)) return false;
    }
  }
  return true;
}

/** Car id -> scenario key, the phone's car included. */
function keyOfCar(phones, appCarId) {
  const names = new Map([...phones.values()].map((p) => [p.carId, p.key]));
  if (appCarId) names.set(appCarId, APP_KEY);
  return (id) => names.get(id) ?? id;
}

/** When a parked car pulls out, from the GPX truth (the first second it has moved). */
function departAt(spec, truth) {
  const series = truth[spec.key];
  const start = series[0].offset;
  return series.find((p) => p.offset > start + 1)?.t ?? Infinity;
}

/** When the heads-up is due for a parked car, from the GPX truth: car 1 (the lead, nearest behind) LEAD_TIME away. */
function headsUpAt(spec, truth) {
  for (let t = 1; t <= DURATION; t++) {
    const lead = interpolate(truth.car1, t);
    const speed = lead - interpolate(truth.car1, t - 1);
    if ((spec.waitOffset - lead) / speed <= LEAD_TIME) return t;
  }
  return Infinity;
}

async function readPositions(organizer, tripId) {
  const snap = await getDocs(collection(organizer.db, `trips/${tripId}/positions`));
  return new Map(snap.docs.map((d) => [d.id, d.data({ serverTimestamps: 'estimate' })]));
}

/** TripSessionLogic.isPaused: pausedAt is set and younger than pauseExpiry (30 minutes). */
function isPausedAt(pausedAt, now) {
  const ms = pausedAt?.toMillis?.();
  return typeof ms === 'number' && now - ms < 30 * 60_000;
}

function scheduleChecks({ phones, tripId, organizer, getAppCarId }) {
  const keyByCar = () => new Map([...phones.values()].map((p) => [p.carId, p.key]));
  const gap = CARS.find((c) => c.key === 'car2').gap;
  const speedOk = speedAt(gap.to - 5) <= 2.5;

  const orderCheck = (at, label, extraWait = 0) => ({
    at: at + extraWait,
    name: label,
    async run(ctx) {
      const positions = await readPositions(organizer, tripId);
      const appCarId = getAppCarId() ?? null;
      const names = keyByCar();
      if (appCarId) names.set(appCarId, APP_KEY);
      const actual = [...positions.entries()]
        .filter(([, p]) => p.convoyOffset !== undefined && p.convoyOffset !== null)
        .map(([id, p]) => ({ key: names.get(id) ?? id, offset: p.convoyOffset }))
        .sort((a, b) => b.offset - a.offset);
      const joining = [...positions.entries()].filter(([, p]) => p.convoyOffset === undefined || p.convoyOffset === null).map(([id]) => names.get(id) ?? id);
      const expected = expectedConvoyOrder(clock.T, { truth: ctx.truth, phones, appPresent: Boolean(appCarId) });
      const fmt = (rows) => rows.map((r) => `${r.key}@${(r.offset / 1000).toFixed(1)}k`).join(' > ');
      const ok = sameOrder(actual, expected);
      check(label, ok, `convoy ${fmt(actual)}; joining [${joining.join(', ')}]; expected ${fmt(expected).replace(/@[\d.]+k/g, '')}`);
    },
  });

  // Every 30 scenario seconds: where the phone is relative to its GPX, to see how far simctl playback lags.
  const progress = [];
  for (let at = 30; at <= DURATION; at += 30) {
    progress.push({
      at, name: `progress at T=${at}`,
      async run(ctx) {
        const appCarId = getAppCarId() ?? null;
        if (!appCarId) return;
        const d = (await readPositions(organizer, tripId)).get(appCarId);
        if (!d) return log('phone has no position yet');
        const expected = interpolate(ctx.truth[APP_KEY], clock.T);
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
            check(`${p.key} position fresh and on track`, age < 20 / speedAt(clock.T) + 12 && d < tol, `age ${age.toFixed(0)} s, ${d.toFixed(0)} m from the GPX point, routeOffset ${doc_.routeOffset.toFixed(0)} of own-route merge at ${p.ownMergeOffset.toFixed(0)}`);
            continue;
          }
          const expected = interpolate(ctx.truth[p.key], clock.T);
          const off = doc_.convoyOffset ?? doc_.routeOffset;
          check(`${p.key} position fresh and on track`, age < 20 / speedAt(clock.T) + 12 && Math.abs(off - expected) < tol, `age ${age.toFixed(0)} s, convoyOffset ${off.toFixed(0)} vs truth ${expected.toFixed(0)}`);
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
        if (!speedOk) return skip('signal drop: car2 stale (server age > 60 s)', `needs speed <= 2.5, ran at ${speedAt(gap.to - 5)}x`);
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
        const life = ev.expiresAt ? ev.expiresAt.toMillis() - ev.createdAt.toMillis() : null;
        check('stop request open, with its message, no place, closing itself after 30 min', ev.category === 'stopRequest' && ev.message === 'Low on fuel, next R&R please' && ev.place === undefined && ev.status === undefined && life === STOP_LIFETIME_SECONDS * 1000, JSON.stringify({ message: ev.message, place: ev.place, status: ev.status, life }));
        const votes = await getDocs(collection(organizer.db, `trips/${tripId}/events/${se.id}/votes`));
        const byCar = new Map(votes.docs.map((v) => [v.id, v.data()]));
        const shape = (v) => v && Object.keys(v).sort().join(',') === 'at,userId';
        check('stop OKs: car 2 and car 4, one vote per car, nothing but userId and at', byCar.size >= 2 && shape(byCar.get(phones.get('car2').carId)) && shape(byCar.get(phones.get('car4').carId)), `${byCar.size} votes`);
      },
    },
    {
      at: 790, name: 'phone car says OK to the stop request',
      async run(ctx) {
        const appCarId = getAppCarId() ?? null;
        if (!opts.expectAppOk || !appCarId || !ctx.stopEvent) return skip('phone car said OK to the stop request', 'no phone, or --expect-app-ok not given');
        const v = await getDoc(doc(organizer.db, `trips/${tripId}/events/${ctx.stopEvent.id}/votes/${appCarId}`));
        check('phone car said OK to the stop request', v.exists(), v.exists() ? JSON.stringify({ userId: v.data().userId }) : 'no vote document');
      },
    },
  ];
}

// ---------------------------------------------------------------- the rebuilt route (D25 4d)

/** The organizer's phone skips the town stop for everyone, then rebuilds the route and writes it with the offsets of the
 *  stops ahead in one batch (StopService.skipForAll, then TripService.rebuildRoute with RouteRebuild.build). */
async function skipAndRebuild(ctx) {
  const phone = ctx.organizer;
  const car4 = ctx.phones.get('car4');
  ctx.rb = { T: clock.T, car4Off: tripLine.project(car4.lastFix).distance };
  await updateDoc(doc(phone.db, `trips/${ctx.tripId}/stops/${rebuildPlan.townId}`), { skipped: true, skippedBy: phone.uid, skippedAt: serverTimestamp() });
  log(`the organizer skips ${REBUILD.town.name} for everyone; the cars see ${rebuildPlan.townId} skipped`);
  const stops = [...phone.stopDocs.values()].map((s) => (s.id === rebuildPlan.townId && BREAK !== 'moves-skipped' ? { ...s, skipped: true } : { ...s, skipped: BREAK === 'moves-skipped' ? undefined : s.skipped }));
  const r = rebuildRoute({
    oldLine: tripLine, directLine: mainRoute, stops, organizer: phone.lastFix, organizerOffset: phone.lastPosition.convoyOffset,
    destination: { latitude: TRIP.destination.latitude, longitude: TRIP.destination.longitude },
  });
  const commitWall = Date.now();
  const batch = writeBatch(phone.db);
  batch.update(doc(phone.db, `trips/${ctx.tripId}`), { route: r.route, routeSeconds: r.routeSeconds });
  for (const [id, routeOffset] of Object.entries(r.offsets)) batch.update(doc(phone.db, `trips/${ctx.tripId}/stops/${id}`), { routeOffset });
  await batch.commit();
  Object.assign(ctx.rb, { cut: r.cut, offsets: r.offsets, line: new RouteLine(Polyline.decode(r.route)), batches: 1, commitWall });
  log(`the organizer's phone writes the rebuilt route (${r.route.length} chars, cut at ${r.cut.toFixed(0)} m) and ${Object.keys(r.offsets).length} stop offset(s) in one batch: ${JSON.stringify(r.offsets)}`);
  if (BREAK === 'batch-twice') {
    const again = writeBatch(phone.db);
    again.update(doc(phone.db, `trips/${ctx.tripId}`), { route: Polyline.encode(ctx.rb.line.coordinates.slice(0, -1)) });
    again.update(doc(phone.db, `trips/${ctx.tripId}/stops/${rebuildPlan.nextId}`), { routeOffset: r.offsets[rebuildPlan.nextId] + 10 });
    await again.commit();
    ctx.rb.batches = 2;
  }
}

function scheduleRebuildChecks({ phones, tripId, organizer }) {
  const orderAt = (at, label) => ({
    at, name: label,
    async run(ctx) {
      const names = new Map([...phones.values()].map((p) => [p.carId, p.key]));
      const actual = [...(await readPositions(organizer, tripId)).entries()]
        .filter(([, p]) => typeof p.convoyOffset === 'number')
        .map(([id, p]) => ({ key: names.get(id), offset: p.convoyOffset })).sort((a, b) => b.offset - a.offset);
      const expected = expectedConvoyOrder(clock.T, { truth: ctx.truth, phones, appPresent: false });
      const fmt = (rows) => rows.map((r) => `${r.key}@${(r.offset / 1000).toFixed(1)}k`).join(' > ');
      check(label, sameOrder(actual, expected), `convoy ${fmt(actual)}; expected ${fmt(expected).replace(/@[\d.]+k/g, '')}`);
    },
  });
  return [
    orderAt(60, 'order before the skip, on the road with the loop: 3 (parked) > 4 > 1 > 2'),
    { at: REBUILD.skipAt, name: 'skip for everyone and rebuild', run: skipAndRebuild },
    orderAt(REBUILD.skipAt + 10, 'order just after the rebuild, on the new route: 3 > 4 > 1 > 2'),
    orderAt(200, 'order on the new route: 3 > 4 > 1 > 2'),
    orderAt(330, 'order after car 4 passes the parked car on the new route: 4 > 3 > 1 > 2'),
    orderAt(410, 'order at the end: 4 > 3 > 1 > 2'),
    {
      at: RUN - 5, name: 'the rebuild, as every phone and the server read it',
      async run(ctx) {
        const rb = ctx.rb;
        if (!rb?.line) return check('the organizer rebuilt the route', false, 'no rebuild was written');
        const car3 = phones.get('car3');
        const car4 = phones.get('car4');
        const { townId, townOffset, nextId, nextOffset, extra } = rebuildPlan;
        const newNext = rb.offsets[nextId];

        // 5. The stop offsets move once, in one batch; the skipped stop's offset never moves.
        check('the rebuild is one batch: the route and the stop ahead moved together, once', rb.batches === 1 && Object.keys(rb.offsets).join() === nextId, JSON.stringify({ batches: rb.batches, moved: Object.keys(rb.offsets) }));
        for (const p of phones.values()) {
          const next = distinctValues(p.stopOffsets.get(nextId));
          const town = distinctValues(p.stopOffsets.get(townId));
          check(`${p.key} reads the stop ahead move once, from the old route to the new, and the skipped stop never`, next.length === 2 && next[0] === nextOffset && next[1] === newNext && town.length === 1 && town[0] === townOffset && p.stopDocs.get(townId).skipped === true, JSON.stringify({ next, town, skipped: p.stopDocs.get(townId).skipped }));
          check(`${p.key} reads the trip's route change once`, p.routes.length === 2 && p.routes[1].route === Polyline.encode(rb.line.coordinates), `${p.routes.length} routes`);
        }
        check(`R&R Tapah moves up by what the loop added (${extra.toFixed(0)} m) to its place on the highway`, Math.abs(nextOffset - newNext - extra) < 25 && Math.abs(newNext - REBUILD.next.offset) < 25, `${nextOffset.toFixed(0)} -> ${newNext.toFixed(0)} m, highway ${REBUILD.next.offset} m`);
        const server = (await getDoc(doc(organizer.db, `trips/${tripId}/stops/${nextId}`))).data();
        const serverTown = (await getDoc(doc(organizer.db, `trips/${tripId}/stops/${townId}`))).data();
        check('the server holds the same: R&R Tapah at its new offset, Lunch skipped at its old one', server.routeOffset === newNext && serverTown.routeOffset === townOffset && serverTown.skipped === true && serverTown.skippedBy === organizer.uid, JSON.stringify({ next: server.routeOffset, town: serverTown.routeOffset, skipped: serverTown.skipped }));
        check('the new route is the highway from the organizer on: the old line kept behind it, no loop', Math.abs(rb.line.length - mainRoute.length) < 40 && Math.abs(rb.cut - interpolate(ctx.truth.car1, rb.T)) < 400 && rb.cut < REBUILD.turnOff, `${rb.line.length.toFixed(0)} m long (highway ${mainRoute.length.toFixed(0)}), cut at ${rb.cut.toFixed(0)} m, car 1 is at ${interpolate(ctx.truth.car1, rb.T).toFixed(0)} m`);

        // 2. No separation warning from the rebuild.
        const warned = (phones.get('car2').warningTrail ?? []).filter((w) => w.T >= rb.T - 5 && w.T <= rb.T + 60);
        check('no separation warning from the rebuild (car 2 phone, 60 s after it)', warned.length === 0, warned.length ? JSON.stringify(warned) : `car 2's phone judged the convoy every second; later ones: ${JSON.stringify(phones.get('car2').warningTrail ?? [])}`);

        // 3. The parked car never reads Drove past for more than one republish.
        // At --speed N a second of real time is N of the drive's, so how many republishes fit before the phone has the
        // new route is counted in real time: one per 5 s of the app's own clock.
        const latency = car3.swapWall === undefined ? Infinity : Math.max(0, car3.swapWall - rb.commitWall);
        const allowed = 1 + Math.floor(latency / (5000 / opts.speed));
        const stale = staleReads(car3.writes.filter((w) => w.wall >= rb.commitWall), { from: 0, stopOffset: newNext });
        const reads = (phones.get('car1').parkedReads ?? []).filter((r) => r.T >= rb.T);
        const passed = reads.filter((r) => r.kind === 'passed').length;
        check('the parked car had the new route within 5 s and wrote at most one position on the old one in that time', latency < 5000 && stale <= allowed, `route after ${latency.toFixed(0)} ms, ${stale} stale of ${car3.writes.filter((w) => w.wall >= rb.commitWall).length} writes since, ${allowed} fit`);
        check('the parked car never reads "Drove past" at R&R Tapah on the organizer\'s phone', reads.length > 100 && passed <= 1, `${passed} of ${reads.length} reads (${[...new Set(reads.map((r) => r.kind))].join(', ')})`);

        // 4. The car on the direct road is on the new route and in the convoy.
        const last = car4.lastPosition;
        const carDoc = (await getDoc(doc(organizer.db, `trips/${tripId}/cars/${car4.carId}`))).data();
        const onNew = rb.line.project(car4.lastFix).distance;
        check('car 4 was off the old route when the stop was skipped, so the rebuild is what brings it back', rb.car4Off > ON_ROUTE_TOLERANCE, `${rb.car4Off.toFixed(0)} m from the old route`);
        check('car 4 (the highway) is on the new route within the on-route tolerance, in the convoy at its true place', onNew <= ON_ROUTE_TOLERANCE && carDoc.state === 'convoy' && typeof last.convoyOffset === 'number' && Math.abs(last.convoyOffset - interpolate(ctx.truth.car4, clock.T)) < 300, `${onNew.toFixed(0)} m from the new route, state ${carDoc.state}, convoyOffset ${last.convoyOffset?.toFixed(0)} vs truth ${interpolate(ctx.truth.car4, clock.T).toFixed(0)}`);
        log('car 4 joining the convoy again (OffRouteDetector) is not ported here: that step stays covered by the unit test');
      },
    },
  ];
}

async function finalChecks(ctx, appCarId) {
  const { phones, tripId, organizer, truth } = ctx;
  clock.label = 'final';
  const T = RUN;

  // A planned stop (D25 piece 3b): car 1's phone counts who is here, from positions alone.
  if (STOPPING) {
    const phone = phones.get('car1');
    const all = (await getDocs(collection(organizer.db, `trips/${tripId}/stops`))).docs.map((d) => d.data());
    const stops = all.filter((x) => x.name === STOP.name);
    check('planned stop stored: name, place on the route, kind, minutes, order', stops.length === 1 && stops[0].routeOffset === STOP.offset && stops[0].kind === STOP.kind && stops[0].minutes === STOP.minutes && stops[0].order === 0 && stops[0].skipped === undefined, JSON.stringify(stops.map((x) => ({ ...x, coordinate: undefined }))));
    let last = 0;
    for (const key of ['car1', 'car2', 'car3', 'car4']) {
      const predicted = truth[key].find((p) => p.offset >= STOP.offset - 150)?.t ?? Infinity;
      const got = phone.arrivals.get(phones.get(key).carId);
      last = Math.max(last, predicted);
      check(`${key} counts as here within 10 s of the GPX coming within 150 m of the stop, not before`, got !== undefined && got >= predicted - 2 && got - predicted <= 10, got !== undefined ? `at T=${got}, predicted T=${predicted}` : `never, predicted T=${predicted}`);
    }
    check('car 1 phone reads "4 of 4 here" when the last car pulls in', phone.firstFull?.title === '4 of 4 here' && phone.firstFull.T >= last - 2 && phone.firstFull.T - last <= 10, phone.firstFull ? `at T=${phone.firstFull.T}, predicted T=${last}` : `never, last tally "${phone.lastTally?.title}"`);
    check('it still reads "4 of 4 here" at the end', phone.lastTally?.title === '4 of 4 here', `"${phone.lastTally?.title}"`);
    check('car 1 phone: the stops listener ran without an error', !phone.stopsError, phone.stopsError ? String(phone.stopsError.code ?? phone.stopsError.message) : '');

    // Leave (D25 4a): arrivedAt once from the lead car's phone, "Leaving at" counts from it, Leave once all are here.
    const tapah = stops[0];
    const arrived = tapah.arrivedAt?.toMillis();
    check('Leaving at: car 1 phone wrote arrivedAt once, in server time, when it first counted itself here', typeof arrived === 'number' && phone.arrivedWall !== undefined && Math.abs(arrived - phone.arrivedWall) <= 15_000 && phone.arrivedTwice === false, `arrivedAt ${arrived}, written at ${phone.arrivedWall}, second write refused: ${phone.arrivedTwice === false} (${phone.arrivedTwiceCode})`);
    const leaving = leavingAt(tapah);
    check('Leaving at is arrivedAt plus the planned 20 minutes, one time for every phone', typeof arrived === 'number' && leaving === arrived + STOP.minutes * 60_000, `${leaving}`);
    check('Leave: car 1 left once all four were here, leftBy car 1', Boolean(phone.firstFull) && tapah.leftAt !== undefined && tapah.leftBy === phone.uid && tapah.leftAt.toMillis() >= phone.firstFull.wall - 2_000 && tapah.leftAt.toMillis() <= Date.now(), JSON.stringify({ leftBy: tapah.leftBy, leftAt: tapah.leftAt?.toMillis(), fullAt: phone.firstFull?.wall }));
    check('Leave: the next stop is untouched', all.filter((x) => x.name !== STOP.name).every((x) => x.leftAt === undefined && x.arrivedAt === undefined && x.skipped === undefined), '');
    check('Leave reaches car 1 phone within 10 s', Boolean(phone.leftSeen) && phone.leftSeen.wall - phone.leaveWall <= 10_000, phone.leftSeen ? `${phone.leftSeen.wall - phone.leaveWall} ms` : 'never');
    const trail = phone.nextTrail.map((x) => x.name);
    check(`Next stop reads ${STOP.name} until Leave and ${STOP_NEXT.name} after it`, trail[0] === STOP.name && trail.at(-1) === STOP_NEXT.name && phone.nextTrail.at(-1).T >= phone.leaveT, JSON.stringify(phone.nextTrail));
    await stopProbesAfter(phones, tripId, organizer);
  }

  // We've stopped: the lead car closed it.
  if (ctx.stopEvent) {
    const ev = (await getDoc(doc(organizer.db, `trips/${tripId}/events/${ctx.stopEvent.id}`))).data();
    check("stop request closed as stopped by the lead car (We've stopped)", ev.status === 'closed' && ev.closedReason === 'stopped' && ev.closedBy === phones.get('car1').uid && ev.expiresAt !== undefined && ev.expiresAt.toMillis() <= Date.now(), JSON.stringify({ status: ev.status, closedReason: ev.closedReason }));
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
    if (appCarId && opts.scenario === 'drive') {
      const off = (t) => interpolate(truth[APP_KEY], t);
      let predicted = null;
      for (let t = ctx.hazardAt; t <= T; t++) { const d = H - off(t); if (d > 0 && d <= 500) { predicted = t; break; } }
      log(`the phone (car5) should announce "Debris ahead in 500 meters" about T=${predicted} (assuming it follows car5-app.gpx without lag)`);
    }
  }

  // Cars parked far ahead (D26), as their phones see the convoy.
  for (const spec of PARKED) {
    const ready = headsUpAt(spec, truth);
    if (spec.kind === 'app') {
      if (appCarId) log(`the phone (${APP_KEY}) should show "Aisha’s car is behind you" about T=${ready}, and drives on about T=${departAt(spec, truth)}`);
      continue;
    }
    const p = phones.get(spec.key);
    const refs = [...p.references.entries()].map(([k, n]) => `${k}: ${n}`).join(', ');
    check(`${spec.key}'s phone: the arrival time comes from the lead (car1) all drive, never the car furthest ahead`, p.references.size === 1 && p.references.has('car1'), `reference by ticks: ${refs}`);
    const w = p.parkedWarnings;
    check(`${spec.key}'s phone: no separation warning about a car parked ahead while it is parked`, w.length === 0, w.length ? `${w.length} ticks, first at T=${w[0].T}: ${w[0].pair}` : `other gaps it would warn about: [${[...p.otherWarnings].join('; ')}]`);
    const h = p.headsUps;
    check(`${spec.key} hears once that the lead is about 2 minutes behind it`, h.length === 1 && h[0].key === 'car1' && Math.abs(h[0].T - ready) <= 20 && /^Aisha’s car is [\d.]+ km behind you\.$/.test(h[0].spoken), h.length ? `at T=${h[0].T}, predicted T=${ready}: "${h[0].spoken}"` : `never, predicted T=${ready}`);
    if (ctx.stopEvent) {
      const heard = p.stopWords.get(ctx.stopEvent.id);
      const truthKm = ctx.stopAt !== undefined ? (spec.waitOffset - interpolate(truth[ctx.stopCar], ctx.stopAt)) / 1000 : null;
      const km = heard?.spoken.match(/, (\d+) km behind\./)?.[1];
      check(`${spec.key} hears the far stop request with how far it is`, Boolean(km) && /^Hafiz needs fuel, \d+ km behind\. Tap OK\.$/.test(heard.spoken) && Math.abs(Number(km) - truthKm) <= 1.5, heard ? `"${heard.spoken}", the GPX has car 3 ${truthKm?.toFixed(1)} km behind` : 'never heard');
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
