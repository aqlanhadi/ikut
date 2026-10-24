// Shared machinery of the two live demos (demo.mjs, demo-two-cars.mjs): a PHONE is the organizer.
//
// The pieces, each small enough to read on its own:
//   parseArgs      the common command-line options
//   Car            a scripted car: a Firebase client that joins, publishes positions with the app's pipeline
//                  (lib/tracking.mjs), logs approach alerts, reports and OKs
//   Sync           marker files shared with the UI tests (ios/ikutUITests/DemoUITests.swift)
//   Car.readTrip   the trip the phone created, read back through the client SDK as a member (works under the real rules)
//   xcodebuild     build once, then one `test-without-building` per phone, QA CHECK lines collected
//   runDemo        dry run, or the whole show: handshake with the phones, drive everyone along the trip's
//                  route at 1x, run the timeline, summarize
//   stopStory      the highlight both demos share: Faiz informs the convoy with a message, Hafiz and Daniel
//                  tap OK, it stays open for a while, the organizer taps "We've stopped"
//
// Handshake with the tests (marker files, $TMPDIR/ikut-qa/<tag>-sync). Test to script: a.code (the trip code),
// b.lobby, a.map, b.map, b.stopRequested, a.ok, a.stopped, b.sawStopped. Script to tests: code, cars.joined,
// report.a / report.b (report debris from the Report sheet), stop.b (Pit stop > Fuel > Add a message > Inform the
// convoy), agree (the organizer taps OK if her car is asked and opens the card), arrive (the organizer taps
// We've stopped), end (leave the map and finish), abort.
//
// Reuse: lib/route.mjs, lib/tracking.mjs, and the 20 s simctl location resync of run-ui.mjs. The marker handshake
// below is the one run-convoy2.mjs uses too.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { initializeApp, deleteApp } from 'firebase/app';
import { connectAuthEmulator, deleteUser, getAuth, signInAnonymously } from 'firebase/auth';
import {
  GeoPoint, Timestamp, collection, connectFirestoreEmulator, disableNetwork, doc, enableNetwork, getDoc, getDocs,
  initializeFirestore, onSnapshot, serverTimestamp, setDoc, setLogLevel, terminate, updateDoc,
} from 'firebase/firestore';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { CarRouteLogic, Polyline, RouteLine, bearing } from './route.mjs';
import { ApproachCore, PositionBuilder, PositionPublisher } from './tracking.mjs';
import { PROJECT_ID, REGION, productionFirebaseConfig } from './firebase-config.mjs';
import { endsWithResult, run, simctl, sleep } from './shell.mjs';
import { loadRoutes } from './scenario.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
export const repo = path.dirname(path.dirname(here));
export { PROJECT_ID, REGION, sleep };
export const km = (m) => (m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m / 10) * 10} m`);
/** One line for a program watching the run (the dashboard): `DEMO {json}`. */
export const emit = (obj) => console.log(`DEMO ${JSON.stringify(obj)}`);
export const mmss = (t) => `${String(Math.floor(t / 60)).padStart(2, '0')}:${String(Math.round(t % 60)).padStart(2, '0')}`;

// ---------------------------------------------------------------- options

/** Common options. `usage` is the header comment lines printed for --help. */
export function parseArgs(argv, usage = '') {
  const o = {
    udid: 'C0A40D2A-0607-4B95-A1BE-F8C9190D81C1', // "iPhone 17 #1": phone 1, the organizer. Never create or erase simulators
    udid2: 'FD0ACD10-F3C4-4797-8DB8-A6F554585CC1', // "iPhone 17 #2": phone 2
    derivedData: '/tmp/ikut-dd-q4', skipBuild: false, dryRun: false, host: '127.0.0.1',
    backend: 'emulators', // or 'production': the real Firebase project, config from the app's GoogleService-Info.plist
    endTrip: false, // the trip stays active afterwards so it can be looked at; --end-trip ends it
    deadline: null, // --deadline S: stop with RESULT: ABORT after S s (default: the build, the show and 900 s)
    logs: path.join(os.tmpdir(), 'ikut-qa'),
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === '--udid') o.udid = next();
    else if (a === '--udid2') o.udid2 = next();
    else if (a === '--derived-data') o.derivedData = next();
    else if (a === '--skip-build') o.skipBuild = true;
    else if (a === '--dry-run') o.dryRun = true;
    else if (a === '--host') o.host = next();
    else if (a === '--end-trip') o.endTrip = true;
    else if (a === '--backend') o.backend = next();
    else if (a === '--describe') o.describe = true;
    else if (a === '--deadline') o.deadline = Number(next());
    else if (a === '-h' || a === '--help') { console.log(usage); process.exit(0); }
    else { console.error(`unknown option ${a}`); process.exit(64); }
  }
  if (!['emulators', 'production'].includes(o.backend)) { console.error('--backend is emulators or production'); process.exit(64); }
  return o;
}

/** Firebase client config: fake for the emulators, the app's own for production (as qa/prod-smoke.mjs does). */
export function firebaseConfig(o, appId) {
  if (o.backend !== 'production') return { apiKey: 'qa-fake-key', projectId: PROJECT_ID, appId };
  return productionFirebaseConfig();
}

// ---------------------------------------------------------------- scripted cars

/**
 * One Firebase client as an anonymous user: the emulators on `o.host` (the default ports), or production when
 * `o.backend` is 'production'. Returns { app, db, fns, uid }. Every runner's scripted car or phone connects through it.
 */
export async function connectEmulators(o, appId) {
  const app = initializeApp(firebaseConfig(o, appId), appId);
  const auth = getAuth(app);
  const db = initializeFirestore(app, {});
  const fns = getFunctions(app, REGION);
  if (o.backend !== 'production') {
    connectAuthEmulator(auth, `http://${o.host}:9099`, { disableWarnings: true });
    connectFirestoreEmulator(db, o.host, 8080);
    connectFunctionsEmulator(fns, o.host, 5001);
  }
  return { app, db, fns, uid: (await signInAnonymously(auth)).user.uid };
}

/** FirestorePositionWriter (ios/ikut/Tracking/TrackingTypes.swift): setData, updatedAt = the server's time. */
export function writePosition(db, tripId, carId, p) {
  const data = { location: new GeoPoint(p.latitude, p.longitude), speed: p.speed, heading: p.heading, routeOffset: p.routeOffset, updatedAt: serverTimestamp() };
  if (p.convoyOffset !== undefined) data.convoyOffset = p.convoyOffset;
  if (p.battery !== null && p.battery !== undefined) data.battery = p.battery;
  return setDoc(doc(db, `trips/${tripId}/positions/${carId}`), data);
}

/** A scripted car: joins through the joinTrip callable like a phone does. */
export class Car {
  constructor(spec, o, say) {
    Object.assign(this, spec); // key, displayName, name, color
    this.o = o;
    this.say = say;
    this.events = [];
    this.approach = new ApproachCore();
  }

  /** The Firebase app is named `<appPrefix>-<key>` (spec.appPrefix, default demo). */
  async connect() {
    Object.assign(this, await connectEmulators(this.o, `${this.appPrefix ?? 'demo'}-${this.key}`));
  }

  async join(code) {
    const res = await httpsCallable(this.fns, 'joinTrip')({ code, displayName: this.displayName, car: { newCar: { name: this.name, color: this.color } }, tracker: true });
    this.tripId = res.data.tripId;
    this.carId = res.data.carId;
    this.events = [];
    this.unsubscribe = onSnapshot(collection(this.db, `trips/${this.tripId}/events`), (snap) => { this.events = snap.docs.map((d) => ({ id: d.id, ...d.data() })); });
  }

  /** The trip this car joined: { route (RouteLine), destination }. Members can read it under the real rules. */
  async readTrip() {
    const f = (await getDoc(doc(this.db, `trips/${this.tripId}`))).data();
    if (!f?.route) throw new Error('the trip has no route');
    return { route: new RouteLine(Polyline.decode(f.route)), destination: f.destination?.name ?? '?' };
  }

  /** The car starts on the trip's route (CarRouteService: planIfOnMain). */
  async ensureRoute(route, fix, now) {
    const plan = CarRouteLogic.planIfOnMain(fix, route);
    if (!plan) throw new Error(`${this.key}'s start is off the trip's route`);
    await updateDoc(doc(this.db, `trips/${this.tripId}/cars/${this.carId}`), { mergeOffset: plan.mergeOffset, state: plan.state });
    this.route = route;
    this.builder = new PositionBuilder(route, null);
    this.publisher = new PositionPublisher({ write: (p) => this.writePosition(p), now });
  }

  writePosition(p) { return writePosition(this.db, this.tripId, this.carId, p); }

  /** A fix: publish it, and log the approach alert a car behind a hazard would get (ApproachMonitor). */
  onFix(fix, battery = 0.8) {
    this.lastFix = fix;
    this.lastPosition = this.builder.build(fix, battery);
    this.publisher.submit(this.lastPosition);
    const now = Date.now();
    const hazards = this.events
      .filter((e) => e.category === 'hazard' && e.carId !== this.carId && typeof e.routeOffset === 'number' && !(e.expiresAt && e.expiresAt.toMillis() <= now))
      .map((e) => ({ id: e.id, offset: e.routeOffset, type: e.type }));
    for (const a of this.approach.evaluate(hazards, this.lastPosition.routeOffset)) {
      this.say(`${this.displayName}'s approach alert: ${hazards.find((h) => h.id === a.id).type} ahead in ${Math.round(a.distance / 10) * 10} m`);
    }
  }

  async reportEvent(type, category, severity, expirySeconds, message = null) {
    const { lastFix: fix } = this;
    const here = { latitude: fix.latitude, longitude: fix.longitude };
    const routeOffset = this.route.project(here)?.offset ?? this.lastPosition.routeOffset;
    const createdAt = new Date();
    const data = {
      type, category, severity, location: new GeoPoint(here.latitude, here.longitude), heading: fix.course >= 0 ? fix.course % 360 : 0,
      routeOffset, authorId: this.uid, carId: this.carId, createdAt: Timestamp.fromDate(createdAt),
    };
    if (expirySeconds) data.expiresAt = Timestamp.fromMillis(createdAt.getTime() + expirySeconds * 1000);
    if (message) data.message = message;
    const ref = doc(collection(this.db, `trips/${this.tripId}/events`));
    await setDoc(ref, data);
    return { id: ref.id, routeOffset };
  }

  /** A stop OK, as the app writes it: this car's vote document with the user and the time. */
  async ok(eventId) {
    await setDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}/votes/${this.carId}`), { userId: this.uid, at: serverTimestamp() });
  }

  /** We've stopped, by the car that asked (the author may close as stopped): status, who and why, expiresAt now. */
  async markStopped(eventId) {
    await updateDoc(doc(this.db, `trips/${this.tripId}/events/${eventId}`), { status: 'closed', closedReason: 'stopped', closedBy: this.uid, expiresAt: Timestamp.now() });
  }

  goOffline() { return disableNetwork(this.db); }
  goOnline() { return enableNetwork(this.db); }

  async close() {
    this.unsubscribe?.();
    this.publisher?.stop();
    if (!this.app) return;
    // Production: don't leave the scripted cars' anonymous users behind (prod-smoke.mjs does the same).
    if (this.o.backend === 'production') await deleteUser(getAuth(this.app).currentUser).catch(() => {});
    await terminate(this.db).catch(() => {});
    await deleteApp(this.app).catch(() => {});
  }
}

// ---------------------------------------------------------------- marker files

export class Sync {
  constructor(dir, say) {
    this.dir = dir;
    this.say = say;
    this.aborted = null;
    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(dir, { recursive: true });
  }
  path(name) { return path.join(this.dir, name); }
  mark(name, content = '') { fs.writeFileSync(this.path(name), content); this.say(`mark ${name}${content ? ` = ${content}` : ''}`); }
  has(name) { return fs.existsSync(this.path(name)); }
  abort(why) {
    if (this.has('abort')) return;
    this.aborted = why;
    fs.writeFileSync(this.path('abort'), why);
    this.say(`ABORT: ${why}`);
  }
  /** Content of the marker once it exists; throws on abort or timeout. */
  async wait(name, timeoutS) {
    const deadline = Date.now() + timeoutS * 1000;
    while (Date.now() < deadline) {
      if (this.has(name)) return fs.readFileSync(this.path(name), 'utf8').trim();
      if (this.aborted || this.has('abort')) throw new Error(`aborted: ${this.aborted ?? fs.readFileSync(this.path('abort'), 'utf8')}`);
      await sleep(300);
    }
    throw new Error(`timed out after ${timeoutS} s waiting for ${name}`);
  }
}

// ---------------------------------------------------------------- the route

const { mainCoords } = loadRoutes();

/** Stand-in for the trip's route in a dry run: the E1 snapshot (the real route comes from the phone's trip). */
export function standInRoute() {
  return new RouteLine(mainCoords);
}
/** Where the phones are when the organizer picks the destination: the start of that snapshot (E1 just south of Bidor). */
export const START = mainCoords[0];

// ---------------------------------------------------------------- the world: who is where, when

/**
 * cast: { key: { displayName, name?, color?, motion: { start, speed, wobble?, period?, phase? }, scripted?: true } }.
 * Offsets are meters along the trip's route, T seconds after go. Stops at the end of the route.
 */
export class World {
  constructor(cast) {
    this.cast = cast;
    this.route = null;
  }
  offsetOf(who, t) {
    const m = this.cast[who].motion;
    const wob = m.wobble ? m.wobble * (Math.sin((2 * Math.PI * t) / m.period + (m.phase ?? 0)) - Math.sin(m.phase ?? 0)) : 0;
    const off = m.start + m.speed * Math.max(0, t) + (t > 0 ? wob : 0);
    return Math.min(this.route.length, Math.max(0, off));
  }
  fixAt(who, t) {
    const off = this.offsetOf(who, t);
    const p = this.route.coordinateAtOffset(off);
    const ahead = this.route.coordinateAtOffset(off + 25);
    const speed = t <= 0 ? 0 : Math.max(0, (this.offsetOf(who, t + 0.5) - this.offsetOf(who, t - 1)) / 1.5);
    return { latitude: p.latitude, longitude: p.longitude, speed, course: bearing(p, ahead) };
  }
  /** "1.2 km ahead of Aisha" style text; `of` defaults to the lead car. */
  gap(who, t, of = 'lead') {
    const d = this.offsetOf(who, t) - this.offsetOf(of, t);
    const name = this.cast[of].displayName;
    return d >= 0 ? `${km(d)} ahead of ${name}` : `${km(-d)} behind ${name}`;
  }
}

// ---------------------------------------------------------------- simulators, xcodebuild

export const locStr = (c) => `${c.latitude.toFixed(6)},${c.longitude.toFixed(6)}`;

/**
 * Boots the simulator if needed and puts it in a known state: the app uninstalled (a fresh install every run: the app keeps
 * its anonymous user in the Keychain, and one left over from an earlier emulator session can't refresh its token, so every
 * write would hang), location permission granted, the location set.
 * Options: start (default START), uninstall (default true: terminate and uninstall the app), textSize (a `simctl ui
 * content_size`, e.g. 'large': a leftover accessibility size breaks taps), askLocation (reset the permission so the app
 * asks, instead of granting it), privacy (the service granted, default 'location-always'), bootText (the log line).
 */
export function prepareSimulator(udid, say, { start = START, uninstall = true, textSize = null, askLocation = false, privacy = 'location-always', bootText = `booting simulator ${udid}` } = {}) {
  const line = simctl('list', 'devices').stdout.split('\n').find((l) => l.includes(udid));
  if (!line) { console.error(`simulator ${udid} not found`); process.exit(1); }
  if (!line.includes('(Booted)')) { say(bootText); simctl('boot', udid); }
  simctl('bootstatus', udid, '-b');
  if (uninstall) {
    simctl('terminate', udid, 'dev.aqlan.ikut');
    simctl('uninstall', udid, 'dev.aqlan.ikut');
  }
  if (textSize) simctl('ui', udid, 'content_size', textSize);
  if (askLocation) simctl('privacy', udid, 'reset', 'location', 'dev.aqlan.ikut');
  else simctl('privacy', udid, 'grant', privacy, 'dev.aqlan.ikut');
  simctl('location', udid, 'set', locStr(start));
}

/**
 * Plays `points` on a simulator at `mps` with `simctl location start`; returns the child (kill it to stop). The caller
 * restarts it every 20 s from where the car should be now: the playback drifts and once stalled for minutes (qa/README.md).
 * `label` tags the stderr lines (`  loc <label>! …`; simctl's "Parsed N waypoints" notes are dropped), `onStderr`
 * replaces them.
 */
export function feedLocation({ udid, points, mps, label = '', onStderr = null }) {
  const loc = spawn('xcrun', ['simctl', 'location', udid, 'start', `--speed=${mps.toFixed(2)}`, '--interval=1', '-']);
  loc.stdin.end(`${points.map(locStr).join('\n')}\n`);
  loc.stderr.on('data', (x) => {
    if (/Parsed \d+ waypoints/.test(String(x))) return;
    if (onStderr) onStderr(x); else console.log(`  loc${label ? ` ${label}` : ''}! ${x}`);
  });
  return loc;
}

export function xcodeArgs(o) {
  return ['-project', path.join(repo, 'ios', 'ikut.xcodeproj'), '-scheme', 'ikut', '-derivedDataPath', o.derivedData,
    '-clonedSourcePackagesDirPath', path.join(o.derivedData, 'SourcePackages')];
}

/** `xcodebuild build-for-testing` for the app (all simulators); the whole output goes to `logPath`. Returns { ok, logPath }. */
export function buildForTesting(o, logPath) {
  const r = run('xcodebuild', ['build-for-testing', ...xcodeArgs(o), '-destination', 'generic/platform=iOS Simulator'], { maxBuffer: 1 << 28 });
  fs.writeFileSync(logPath, `${r.stdout ?? ''}\n${r.stderr ?? ''}`);
  return { ok: r.status === 0, logPath };
}

/**
 * One UI test on one simulator (`test-without-building`). Collects the QA CHECK lines as { kind: PASS|FAIL|NOTE, name };
 * `exit` resolves with xcodebuild's exit code, `ok` says whether the test passed (also when xcodebuild never exits after
 * its suite passed: the suite line decides, and it is killed 60 s later).
 * spec: { udid, only (the test class), id, label, logPath, bundle (.xcresult), env, say, onFail(why) }, and optionally
 *   onLine(line, t)    every output line (the demos emit a dashboard event per check)
 *   abortOn(line)      a reason (string) when the line means the test has failed: onFail is called with it
 *   echo               the lines worth printing (a regex), prefixed `  <id> | `
 *   track(child)       registers the child (run-convoy2: killed when the script exits); returns it
 */
export function startUiTest(o, spec) {
  const { udid, only, id, label, logPath, bundle, env, say, onFail, onLine, abortOn, track = (c) => c,
    echo = /QA (STEP|CHECK)|Test Case .*(passed|failed|skipped)|error:|\*\* TEST|Timed out/ } = spec;
  const log = fs.createWriteStream(logPath);
  fs.rmSync(bundle, { recursive: true, force: true });
  const xc = track(spawn('xcodebuild', ['test-without-building', ...xcodeArgs(o), '-destination', `platform=iOS Simulator,id=${udid}`,
    `-only-testing:ikutUITests/${only}`, '-resultBundlePath', bundle, '-collect-test-diagnostics', 'never'], { env: { ...process.env, ...env } }));
  const t = { id, label, logPath, checks: [], xc };
  let buf = '';
  const onData = (d) => {
    log.write(d);
    buf += d.toString();
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const l = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      const c = /QA CHECK: (PASS|FAIL|NOTE) (.*)$/.exec(l);
      if (c) t.checks.push({ kind: c[1], name: c[2] });
      const why = abortOn?.(l);
      if (why) onFail(why);
      onLine?.(l, t);
      if (echo.test(l)) process.stdout.write(`  ${id} | ${l}\n`);
      if (/\*\* TEST (SUCCEEDED|FAILED) \*\*/.test(l)) t.result ??= l.trim();
      // xcodebuild on a second simulator sometimes never exits after the suite finishes; the suite line decides.
      const suite = /Test Suite 'Selected tests' (passed|failed)/.exec(l);
      if (suite && !t.suite) {
        t.suite = suite[1];
        setTimeout(() => { if (t.code === undefined) { say(`${id}'s xcodebuild still running 60 s after its suite ${t.suite}; killing it`); xc.kill('SIGKILL'); } }, 60_000);
      }
    }
  };
  xc.stdout.on('data', onData);
  xc.stderr.on('data', onData);
  t.exit = new Promise((r) => xc.on('exit', (code) => { t.code = code; t.ok = code === 0 || (code === null && t.suite === 'passed'); r(code); }));
  t.exit.then((code) => { say(`${label}'s test exited ${code} (${t.result ?? `suite ${t.suite ?? 'unfinished'}`})`); if (!t.ok) onFail(`${label}'s test failed`); });
  return t;
}

/** The demos' UI test: log and result bundle named after the tag and the phone, check events for the dashboard. */
function startTest(o, tag, phone, syncDir, say, onFail) {
  const endTrip = o.endTrip || o.backend === 'production'; // phone 1 ends the trip from its Trip menu once `end` is written
  return startUiTest(o, {
    udid: phone.udid, only: phone.test, id: phone.id, label: phone.label, say, onFail,
    logPath: path.join(o.logs, `${tag}-xcodebuild-${phone.id}.log`),
    bundle: path.join(o.logs, `${tag}-${phone.id}.xcresult`),
    env: { TEST_RUNNER_IKUT_SYNC_DIR: syncDir, TEST_RUNNER_IKUT_QA_SCREENS: path.join(o.logs, `${tag}-screens`),
      ...(o.backend === 'production' ? { TEST_RUNNER_IKUT_USE_PRODUCTION: '1' } : {}),
      ...(phone.id === 'a' && endTrip ? { TEST_RUNNER_IKUT_END_TRIP: '1' } : {}), ...phone.env },
    onLine: (l) => {
      const c = /QA CHECK: (PASS|FAIL|NOTE) (.*)$/.exec(l);
      if (c) emit({ type: 'check', phone: phone.id === 'a' ? 1 : 2, status: c[1] === 'PASS' ? 'PASS' : 'FAIL', name: c[2] });
    },
  });
}

// ---------------------------------------------------------------- the show

/**
 * config: { tag, title, cast, order (front to back, scripted + phones), endAt (s), stopAt?, phones: [{ id: 'a'|'b', label,
 *   udid, test, follows (cast key whose track the simulator plays), tracks (its car publishes positions), env }],
 *   timeline: (d) => [{ at, text: (t) => string, run?: async (d) => {}, note?: true }], sanity?: (d) => string[] }
 * `d` is the demo object: d.world, d.cars (scripted, by key), d.sync, d.say, d.check, d.o.
 */
let activeCleanup = null;
export async function runDemo(config, o) {
  try { return await runDemoInner(config, o); } catch (e) {
    console.error(`demo failed: ${e.stack ?? e}`);
    emit({ type: 'error', message: e.message });
    emit({ type: 'phase', phase: 'failed', detail: e.message });
    await activeCleanup?.().catch(() => {});
    return 1;
  }
}

async function runDemoInner(config, o) {
  const t0 = Date.now();
  const clock = { T: null };
  const say = (...a) => console.log(clock.T !== null ? `[T+${String(Math.round(clock.T)).padStart(3, ' ')}s]` : `[+${String(Math.round((Date.now() - t0) / 1000)).padStart(3, ' ')}s ]`, ...a);
  const world = new World(config.cast);
  const results = [];
  const d = {
    o, world, say, clock, cars: {}, results, tag: config.tag,
    check(name, pass, detail = '') { results.push({ name, pass, detail }); say(`QA CHECK ${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` (${detail})` : ''}`); return pass; },
  };
  // Offsets don't depend on the route (but for its length), so the plan can be printed on a stand-in before the
  // phone has created the trip; it is rebuilt on the real route once that is known.
  world.route = standInRoute();
  let timeline = config.timeline(d).sort((a, b) => a.at - b.at);
  const lineFor = (e) => `T+${String(e.at).padStart(3, ' ')}s (${mmss(e.at)}): ${e.text(e.at)}`;
  const printTimeline = () => {
    console.log('Timeline (T = seconds after go; "watch" lines are cues, nothing is done at that moment):');
    for (const e of timeline) console.log(`  ${lineFor(e)}${e.note ? '   [watch]' : ''}`);
  };

  // ---- --describe: one JSON object for the dashboard, nothing else on stdout
  if (o.describe) {
    console.log(JSON.stringify({
      id: config.id, title: config.title, summary: config.summary,
      phones: config.phones.map((p, i) => ({ udid: p.udid, label: `iPhone 17 #${i + 1}`, role: p.role })),
      cast: Object.values(config.cast).map((c) => ({ name: c.displayName, role: c.role })),
      durationSeconds: config.endAt,
      timeline: timeline.map((e) => ({ at: e.at, text: e.text(e.at), watch: Boolean(e.note), who: e.who ?? 'script' })),
    }));
    return 0;
  }

  // ---- dry run: the geometry on a stand-in route
  if (o.dryRun) {
    console.log(`${config.title} (dry run, stand-in route: osrm-main.json, ${(world.route.length / 1000).toFixed(1)} km)`);
    for (const [who, c] of Object.entries(config.cast)) {
      console.log(`  ${who.padEnd(7)} ${c.displayName.padEnd(7)} starts ${c.motion.start} m along, ${(c.motion.speed * 3.6).toFixed(0)} km/h${c.scripted ? ', scripted' : ', a phone'}`);
    }
    printTimeline();
    const problems = [];
    for (const t of [0, config.endAt / 2, config.endAt]) {
      const got = Object.keys(config.cast).sort((a, b) => world.offsetOf(b, t) - world.offsetOf(a, t));
      if (got.join() !== config.order.join()) problems.push(`order at T+${t}s is ${got.join(' > ')}, wanted ${config.order.join(' > ')}`);
    }
    if (world.offsetOf('lead', config.endAt) > world.route.length - 1000) problems.push('the lead runs out of route before the end');
    problems.push(...(config.sanity?.(d) ?? []));
    console.log(`Total ${mmss(config.endAt)} min. Geometry: ${problems.length ? 'PROBLEMS\n  - ' + problems.join('\n  - ') : 'ok'}`);
    return problems.length === 0 ? 0 : 1;
  }

  // ---- the real thing
  // Its SIGINT/SIGTERM handler (below) cleans up; the deadline goes through it too.
  const end = endsWithResult({ deadlineS: o.deadline ?? (o.skipBuild ? 0 : 1800) + config.endAt + 900 });
  setLogLevel('error');
  emit({ type: 'phase', phase: 'building', detail: o.skipBuild ? 'reusing the build' : 'xcodebuild build-for-testing' });
  const tag = config.tag;
  fs.mkdirSync(o.logs, { recursive: true });
  const sync = new Sync(path.join(o.logs, `${tag}-sync`), say);
  d.sync = sync;
  const scriptedKeys = Object.keys(config.cast).filter((k) => config.cast[k].scripted);
  d.cars = Object.fromEntries(scriptedKeys.map((k) => [k, new Car({ key: k, ...config.cast[k] }, o, say)]));
  const phones = config.phones;
  let tests = [];
  let ticker = null;
  let feeder = null;
  const players = {};

  const endTrip = o.endTrip || o.backend === 'production'; // production: always end the trip, it is a real one
  let tripCreated = false;
  const cleanup = async () => {
    // Let phone 1 end the trip (its Trip menu) before its test is stopped.
    if (endTrip && tripCreated && !sync.has('end')) {
      sync.mark('end');
      await Promise.race([Promise.all(tests.map((t) => t.exit)), sleep(60_000)]);
    }
    clearInterval(ticker);
    clearInterval(feeder);
    for (const p of Object.values(players)) p.kill();
    for (const p of phones) simctl('location', p.udid, 'clear');
    for (const t of tests) if (t.xc.exitCode === null && t.xc.signalCode === null) t.xc.kill('SIGTERM');
    for (const c of Object.values(d.cars)) await c.close();
  };
  activeCleanup = cleanup;
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, async () => { console.log(`\n${sig}: interrupted`); if (!(endTrip && tripCreated)) sync.abort('interrupted'); await cleanup(); emit({ type: 'phase', phase: 'failed', detail: `stopped (${sig})` }); process.exit(sig === 'SIGINT' ? 130 : 143); });
  }

  const project = firebaseConfig(o, 'x').projectId;
  emit({ type: 'backend', backend: o.backend, project });
  console.log(`ikut live demo: ${config.title}\nbackend ${o.backend === 'production' ? `PRODUCTION (real Firebase project ${project}; the trip is ended at the end)` : `emulators on ${o.host}`}, project ${project}, phone 1 ${o.udid}, phone 2 ${o.udid2}, clock 1x\n`);
  printTimeline();
  console.log('');

  for (const p of phones) prepareSimulator(p.udid, say);
  if (!o.skipBuild) {
    say('building (build-for-testing)');
    const build = buildForTesting(o, path.join(o.logs, `${tag}-build.log`));
    if (!build.ok) throw new Error(`build failed, see ${build.logPath}`);
  }
  emit({ type: 'phase', phase: 'joining', detail: 'phones start their UI tests' });
  tests = phones.map((p) => startTest(o, tag, p, sync.dir, say, (why) => sync.abort(why)));
  say(`UI tests started on ${phones.map((p) => p.label).join(' and ')}`);

  // 1. the organizer's phone creates the trip. The scripted cars join it (they are members, so they can read it under the
  // real rules), read its route back and everyone is parked on it. Then phone 2 joins with the code.
  const code = await sync.wait('a.code', 420);
  tripCreated = true;
  emit({ type: 'code', code });
  const wallNow = () => (Date.now() - t0) / 1000;
  let trip = null;
  for (const c of Object.values(d.cars)) {
    await c.connect();
    await c.join(code);
    trip ??= await c.readTrip();
    if (c.key === Object.keys(d.cars)[0]) {
      world.route = trip.route;
      timeline = config.timeline(d).sort((x, y) => x.at - y.at);
      d.tripId = c.tripId;
    }
    await c.ensureRoute(world.route, world.fixAt(c.key, 0), wallNow);
    c.onFix(world.fixAt(c.key, 0));
    say(`${c.displayName} (${c.name}) joined`);
  }
  console.log(`\nTRIP CODE: ${code}  (trip ${d.tripId}, ${(trip.route.length / 1000).toFixed(1)} km to ${trip.destination})\n`);
  d.check('the trip created on phone 1 has a route long enough for the show', trip.route.length > world.offsetOf('lead', config.endAt) + 1000, `${(trip.route.length / 1000).toFixed(1)} km`);
  for (const p of phones) simctl('location', p.udid, 'set', locStr(world.route.coordinateAtOffset(world.offsetOf(p.follows, 0))));
  sync.mark('code', code);
  await sync.wait('b.lobby', 300);
  let goWall = null;
  const tick = (T) => { for (const [k, c] of Object.entries(d.cars)) { c.onFix(world.fixAt(k, T), Math.max(0.2, 0.8 - T / 6000)); c.publisher.tick(); } };
  ticker = setInterval(() => { if (goWall === null) tick(0); }, 1000); // heartbeats at the start until go
  await sleep(3000);
  sync.mark('cars.joined');

  // 3. both phones on the map. The simulator doesn't repeat an unchanged location and the app drops fixes older
  // than 15 s, so nudge the parked fix until the tracking phones' cars report a position.
  emit({ type: 'phase', phase: 'waiting', detail: 'both phones open the map' });
  await sync.wait('a.map', 240);
  await sync.wait('b.map', 240);
  const expected = scriptedKeys.length + phones.filter((p) => p.tracks).length;
  const anyCar = Object.values(d.cars)[0];
  for (let i = 0; i < 90; i++) {
    const snap = await getDocs(collection(anyCar.db, `trips/${d.tripId}/positions`));
    if (snap.size >= expected) break;
    if (i % 5 === 4) for (const p of phones) { const c = world.route.coordinateAtOffset(world.offsetOf(p.follows, 0)); simctl('location', p.udid, 'set', locStr({ latitude: c.latitude + (i % 10 === 4 ? 0.000005 : 0), longitude: c.longitude })); }
    if (i === 89) say('a phone is still not reporting a position; going anyway');
    await sleep(1000);
  }

  // 4. go: the simulators play their tracks, resynced every 20 s (`simctl location start` drifts, see qa/README.md)
  const feed = (p) => {
    const T = (Date.now() - goWall) / 1000;
    const m = world.offsetOf(p.follows, T);
    if (m >= world.route.length - 1) return;
    const r = world.route;
    const pts = [r.coordinateAtOffset(m)];
    for (let off = m + 80; off < Math.min(r.length, m + 25_000); off += 80) pts.push(r.coordinateAtOffset(off));
    players[p.id]?.kill();
    players[p.id] = feedLocation({ udid: p.udid, points: pts, mps: config.cast[p.follows].motion.speed, label: p.id });
  };
  emit({ type: 'phase', phase: 'running', detail: 'go' });
  console.log('\n================ DEMO START ================');
  goWall = Date.now();
  clock.T = 0;
  for (const p of phones) feed(p);
  feeder = setInterval(() => phones.forEach(feed), 20_000);
  const pending = timeline.map((e) => ({ ...e, done: false }));
  let scriptError = null;
  try {
    for (let sec = 0; sec <= config.endAt; sec++) {
      const wait = goWall + sec * 1000 - Date.now();
      if (wait > 0) await sleep(wait);
      clock.T = sec;
      if (sync.aborted) throw new Error(`aborted: ${sync.aborted}`);
      tick(sec);
      if (sec % 5 === 0) emit({ type: 'tick', t: sec });
      for (const e of pending) {
        if (e.done || sec < e.at) continue;
        e.done = true;
        console.log(`${lineFor(e)}${e.note ? '   [watch]' : ''}`);
        emit({ type: 'event', at: e.at, text: e.text(e.at), watch: Boolean(e.note), who: e.who ?? 'script' });
        // Run in the background so the cars keep driving while a step waits for a phone.
        if (e.run) e.run(d).catch((err) => { say(`!! "${e.text(e.at)}" failed: ${err.message}`); d.check(`step "${e.text(e.at).slice(0, 60)}"`, false, err.message); });
      }
    }
  } catch (e) { scriptError = e; say(`stopping early: ${e.message}`); }
  console.log('================ DEMO END ================');
  sync.mark('end'); // phone 1 ends the trip first when asked to (--end-trip, always in production)
  const exited = await Promise.race([Promise.all(tests.map((t) => t.exit)), sleep(90_000).then(() => null)]);
  if (!exited) for (const t of tests) if (t.code === undefined) { say(`killing ${t.label}'s test`); t.xc.kill('SIGKILL'); }
  await Promise.all(tests.map((t) => t.exit));
  await cleanup();

  console.log('\n---- QA CHECK lines');
  for (const t of tests) for (const c of t.checks) console.log(`QA CHECK ${c.kind} ${t.id}: ${c.name}`);
  for (const r of results) console.log(`QA CHECK ${r.pass ? 'PASS' : 'FAIL'} script: ${r.name}${r.detail ? ` (${r.detail})` : ''}`);
  for (const t of tests) console.log(`${t.label}: ${t.result ?? `suite ${t.suite ?? 'unfinished'}, exit ${t.code}`}, log ${t.logPath}`);
  const ok = !scriptError && results.every((r) => r.pass) && tests.every((t) => t.ok);
  end.result(ok);
  emit({ type: 'phase', phase: ok ? 'ended' : 'failed', detail: ok ? 'all checks passed' : 'see the QA CHECK lines' });
  return ok ? 0 : 1;
}

// ---------------------------------------------------------------- the highlight

/** How long the open request stays on the phones, with the OKs in, before "We've stopped", seconds. */
export const STOP_OPEN_S = 45;

/** What Faiz types on his phone (the UI test types the same words). */
export const STOP_MESSAGE = 'Low on fuel, next R&R please';

/**
 * The stop story: Faiz (phone 2) taps Pit stop > Fuel > Add a message > Inform the convoy (marker stop.b);
 * Hafiz and then Daniel tap OK; the organizer taps OK on her pill if her car was asked (marker agree) and the OKs
 * show on her card; the request stays STOP_OPEN_S; the organizer taps We've stopped (marker arrive) and the
 * request closes on every phone.
 */
export async function stopStory(d) {
  const { cars, sync, say } = d;
  let eventId;
  sync.mark('stop.b');
  for (let i = 0; i < 240 && !eventId; i++) {
    eventId = cars.hafiz.events.find((e) => e.category === 'stopRequest' && e.status !== 'closed' && e.expiresAt?.toMillis() > Date.now())?.id;
    if (!eventId) await sleep(500);
  }
  if (!d.check("Faiz's stop request reached the scripted cars", Boolean(eventId))) throw new Error('no stop request arrived');
  const ref = doc(cars.hafiz.db, `trips/${d.tripId}/events/${eventId}`);
  const asked = (await getDoc(ref)).data();
  d.check('the request carries his message, no place, and closes itself after 30 minutes', asked?.message === STOP_MESSAGE && asked.place === undefined && asked.expiresAt.toMillis() - asked.createdAt.toMillis() === 30 * 60 * 1000, JSON.stringify({ message: asked?.message, place: asked?.place }));
  await sleep(6000);
  await cars.hafiz.ok(eventId);
  say('Hafiz taps OK');
  await sleep(6000);
  await cars.daniel.ok(eventId);
  say('Daniel taps OK');
  await sleep(4000);
  sync.mark('agree'); // phone 1: OK on the pill if her car is asked, then the card with the OKs
  await sync.wait('a.ok', 120);
  say(`the OKs are in; the request stays open for ${STOP_OPEN_S} s so it can be watched`);
  await sleep(STOP_OPEN_S * 1000);
  sync.mark('arrive'); // phone 1 taps We've stopped
  await sync.wait('a.stopped', 90);
  const closed = (await getDoc(ref)).data();
  d.check("We've stopped closed the request (status closed, reason stopped, expiresAt now)", closed?.status === 'closed' && closed.closedReason === 'stopped' && Boolean(closed.closedBy) && closed.expiresAt.toMillis() <= Date.now() + 1000, JSON.stringify({ status: closed?.status, closedReason: closed?.closedReason }));
  await sync.wait('b.sawStopped', 120);
  say("the request is closed on phone 2 too");
}
