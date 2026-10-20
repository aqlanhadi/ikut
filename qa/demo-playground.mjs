#!/usr/bin/env node
// PLAYGROUND: a route you can play, for trying single events on the real app without sitting through a scripted demo.
//
//   node demo-playground.mjs [--skip-build] [--derived-data D] [--udid U1] [--udid2 U2]     (emulators only)
//   node demo-playground.mjs --dry-run      # no Firebase, no simulator: print the cast and the placement maths
//   node demo-playground.mjs --describe     # JSON for the dashboard
//
// You tap the real app on two simulators (phone 1 creates the trip, phone 2 joins it); this script provides the route:
// where everybody starts, how fast each car drives, play/pause, and two generated cars (Daniel, Hafiz) with a few
// behaviours (agree to stop requests, suggest a place, drop their signal). It fires no scripted events.
//
// Commands arrive on stdin as `CMD {json}` lines (the dashboard writes them); state goes out as `DEMO {"type":"state"}`
// every second. Commands: prepare {start, skipBuild}, place {car, km, offRoute?, sideMeters?}, speed {car, kmh},
// play {car, playing}, playAll {playing}, behaviour {car, agree?, suggest?}, drop {car, offline}. Cars: phone1, phone2,
// daniel, hafiz. Details in qa/README.md ("Playground").

import { execFile, spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { GeoPoint, collection, deleteField, doc, getDocs, setLogLevel, updateDoc } from 'firebase/firestore';
import { START, Car, PROJECT_ID, emit, firebaseConfig, parseArgs, repo, sleep, standInRoute } from './lib/demo-common.mjs';
import { CarRouteLogic, Polyline, RouteLine, bearing } from './lib/route.mjs';
import { PositionBuilder, PositionPublisher } from './lib/tracking.mjs';
import {
  advanceOffset, ageSeconds, clampKmh, decodeDoc, feedPoints, nudged, offRouteCoords, parseStart, pendingVotes, suggestionAhead,
} from './lib/playground.mjs';

// --no-sim (developing the script itself): no builds and no simctl calls at all, for trying the cars without simulators.
const NO_SIM = process.argv.includes('--no-sim') || process.env.IKUT_PLAYGROUND_NO_SIM === '1';
const o = parseArgs(process.argv.filter((a) => a !== '--no-sim'), 'See the header of demo-playground.mjs (qa/README.md, "Playground").');
const BUNDLE = 'dev.aqlan.ikut';

const phones = [
  { id: 'phone1', udid: o.udid, label: 'iPhone 17 #1', role: 'Organizer: creates the trip by hand' },
  { id: 'phone2', udid: o.udid2, label: 'iPhone 17 #2', role: 'Joins by hand with the trip code, as its own car' },
];
const GENERATED = {
  daniel: { displayName: 'Daniel', name: 'Daniel’s City', color: '#7C3AED', place: 'R&R Demo' },
  hafiz: { displayName: 'Hafiz', name: 'Hafiz’s Hilux', color: '#0F766E', place: 'Rest Stop Demo' },
};
const DEFAULTS = { phone1: 3000, phone2: 2200, daniel: 1400, hafiz: 600 };
const KEYS = ['phone1', 'phone2', 'daniel', 'hafiz'];
const DEFAULT_KMH = 90;

if (o.describe) {
  console.log(JSON.stringify({
    id: 'playground', interactive: true, title: 'Playground',
    summary: 'A playable route for two simulators: you tap the real app, this places the cars, sets their speeds and plays or pauses them. Two more cars are generated.',
    phones: phones.map((p) => ({ udid: p.udid, label: p.label, role: p.role })),
    cast: [{ name: 'Daniel', role: 'generated car' }, { name: 'Hafiz', role: 'generated car' }],
  }));
  process.exit(0);
}

const say = (...a) => console.log(new Date().toTimeString().slice(0, 8), ...a);

if (o.backend === 'production') {
  const message = 'The playground only runs on the emulators, never on the real Firebase project.';
  console.error(message);
  emit({ type: 'error', message });
  emit({ type: 'phase', phase: 'failed', detail: message });
  process.exit(2);
}

if (o.dryRun) {
  const route = standInRoute();
  console.log(`Playground (dry run, stand-in route: osrm-main.json, ${(route.length / 1000).toFixed(1)} km)`);
  for (const k of KEYS) console.log(`  ${k.padEnd(7)} starts ${DEFAULTS[k]} m along, ${DEFAULT_KMH} km/h, paused, ${GENERATED[k] ? 'generated' : 'a phone'}`);
  const coords = offRouteCoords(route, 6000, 2000);
  const plan = CarRouteLogic.makePlan(coords, route);
  console.log(`  an off-route car merging at 6.0 km: ${plan.state}, mergeOffset ${plan.mergeOffset.toFixed(0)} m, own route ${plan.route.length} chars`);
  process.exit(plan.state === 'joining' && Math.abs(plan.mergeOffset - 6000) < 120 ? 0 : 1);
}

// ---------------------------------------------------------------- state

const t0 = Date.now();
const nowSeconds = () => (Date.now() - t0) / 1000;
const S = {
  phase: 'setup', detail: 'Pick where everyone starts, then prepare the phones.', problem: null,
  start: { latitude: START.latitude, longitude: START.longitude, label: 'The E1 start used by the demos' },
  code: null, tripId: null, destination: null, route: null, organizerId: null,
};
/** Everyone in the playground, by key. */
const cars = Object.fromEntries(KEYS.map((k) => [k, {
  key: k, kind: GENERATED[k] ? 'generated' : 'phone', label: GENERATED[k]?.displayName ?? (k === 'phone1' ? 'Phone 1' : 'Phone 2'),
  offset: DEFAULTS[k], speed: DEFAULT_KMH, playing: false, joining: false, sideMeters: 2000, mergeKm: null, ownOffset: 0, own: null,
  offline: false, agree: false, suggest: false, carId: null, car: null, player: null, nudges: 0,
}]));
let rest = { positions: new Map(), cars: new Map(), events: [], votes: new Map() }; // what the emulator has, as the owner sees it
const timers = [];

const routeLen = () => S.route?.length ?? 0;
const phone = (c) => phones.find((p) => p.id === c.key);

// ---------------------------------------------------------------- simulators

const simctl = (...args) => (NO_SIM ? { status: 0, stdout: '', stderr: '' } : spawnSync('xcrun', ['simctl', ...args], { encoding: 'utf8' }));
const simctlAsync = (...args) => { if (!NO_SIM) execFile('xcrun', ['simctl', ...args], () => {}); };
const locStr = (c) => `${c.latitude.toFixed(6)},${c.longitude.toFixed(6)}`;

/** Who is using a simulator right now (other demos, UI tests, location playback). Empty when it is free. */
function inUse() {
  const ps = spawnSync('ps', ['-axo', 'pid=,command='], { encoding: 'utf8' }).stdout.split('\n');
  const found = [];
  for (const line of ps) {
    const m = /^\s*(\d+)\s+(.*)$/.exec(line);
    if (!m || Number(m[1]) === process.pid) continue;
    const cmd = m[2];
    if (/--describe|--dry-run/.test(cmd) || /^(ps|grep)\b/.test(cmd)) continue;
    let who = null;
    if (/\bnode\b.*\b(demo[\w-]*|run-ui|run-convoy2|drive-trip|convoy-sim)\.mjs/.test(cmd)) who = `${/([\w-]+)\.mjs/.exec(cmd)[1]} (running)`;
    else if (/xcodebuild.*\btest(-without-building)?\b/.test(cmd) && !/build-for-testing/.test(cmd)) who = 'a UI test (xcodebuild)';
    else if (/simctl location/.test(cmd)) who = 'a simulator location playback';
    if (!who) continue;
    const udids = phones.filter((p) => cmd.includes(p.udid)).map((p) => p.udid);
    found.push({ who, udids: udids.length ? udids : phones.map((p) => p.udid), pid: m[1] });
  }
  return found;
}

function prepareSimulator(p, app) {
  const line = simctl('list', 'devices').stdout.split('\n').find((l) => l.includes(p.udid));
  if (!line) throw new Error(`${p.label} (${p.udid}) is not among the installed simulators`);
  if (!line.includes('(Booted)')) { say(`booting ${p.label}`); simctl('boot', p.udid); simctl('bootstatus', p.udid, '-b'); }
  // A fresh install every time: the app keeps its anonymous user in the Keychain, and one left over from an earlier
  // emulator session can't refresh its token, so every write would hang.
  simctl('terminate', p.udid, BUNDLE);
  simctl('uninstall', p.udid, BUNDLE);
  const r = simctl('install', p.udid, app);
  if (r.status !== 0) throw new Error(`could not install the app on ${p.label}: ${r.stderr.trim()}`);
  simctl('privacy', p.udid, 'grant', 'location-always', BUNDLE);
  simctl('location', p.udid, 'set', locStr(S.start));
  const l = simctl('launch', p.udid, BUNDLE);
  if (l.status !== 0) throw new Error(`could not open the app on ${p.label}: ${l.stderr.trim()}`);
}

function stopPlayer(c) { c.player?.kill(); c.player = null; }

/** Point the simulator of a phone at its car: play from the car's offset at its speed, or park there. */
function feedPhone(c) {
  const p = phone(c);
  if (!S.route || !p) return;
  stopPlayer(c);
  const at = S.route.coordinateAtOffset(c.offset);
  if (!c.playing || c.speed <= 0 || c.offset >= S.route.length - 1) { simctlAsync('location', p.udid, 'set', locStr(at)); return; }
  if (NO_SIM) return;
  const loc = spawn('xcrun', ['simctl', 'location', p.udid, 'start', `--speed=${(c.speed / 3.6).toFixed(2)}`, '--interval=1', '-']);
  loc.stdin.end(`${feedPoints(S.route, c.offset).map(locStr).join('\n')}\n`);
  loc.stderr.on('data', (x) => { if (!/Parsed \d+ waypoints/.test(String(x))) say(`${p.label} location: ${x}`.trim()); });
  c.player = loc;
}

// ---------------------------------------------------------------- the emulator, over REST as the owner

const REST = `http://${o.host}:8080/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
const headers = { Authorization: 'Bearer owner', 'Content-Type': 'application/json' };
async function restList(p) {
  const r = await fetch(`${REST}/${p}?pageSize=300`, { headers });
  if (!r.ok) return [];
  return ((await r.json()).documents ?? []).map(decodeDoc);
}
async function findNewTrip(sinceMs) {
  const res = await fetch(`${REST}:runQuery`, {
    method: 'POST', headers,
    body: JSON.stringify({ structuredQuery: { from: [{ collectionId: 'trips' }], where: { fieldFilter: { field: { fieldPath: 'status' }, op: 'EQUAL', value: { stringValue: 'active' } } } } }),
  });
  if (!res.ok) throw new Error(`the Firestore emulator answered ${res.status}`);
  const trips = (await res.json()).filter((r) => r.document).map((r) => decodeDoc(r.document))
    .filter((t) => (t.createdAt ?? 0) >= sinceMs && t.route && t.code).sort((a, b) => b.createdAt - a.createdAt);
  return trips[0] ?? null;
}
async function pollRest() {
  if (!S.tripId) return;
  const base = `trips/${S.tripId}`;
  const [positions, carDocs, events] = await Promise.all([restList(`${base}/positions`), restList(`${base}/cars`), restList(`${base}/events`)]);
  const votes = new Map();
  await Promise.all(events.filter((e) => e.category === 'stopRequest').map(async (e) => votes.set(e.id, await restList(`${base}/events/${e.id}/votes`))));
  rest = { positions: new Map(positions.map((p) => [p.id, p])), cars: new Map(carDocs.map((c) => [c.id, c])), events, votes };
  // Phone 1 is the organizer's car, phone 2 the other car that is not generated.
  const generated = new Set(['daniel', 'hafiz'].map((k) => cars[k].carId));
  const mine = carDocs.filter((c) => !generated.has(c.id));
  cars.phone1.carId = mine.find((c) => c.trackerUserId && c.trackerUserId === S.organizerId)?.id ?? mine.find((c) => c.isLead)?.id ?? null;
  cars.phone2.carId = mine.find((c) => c.id !== cars.phone1.carId)?.id ?? null;
}

// ---------------------------------------------------------------- generated cars

const fixFor = (c) => {
  const route = c.joining ? c.own : S.route;
  const m = c.joining ? c.ownOffset : c.offset;
  const p = route.coordinateAtOffset(m);
  return { latitude: p.latitude, longitude: p.longitude, speed: c.playing ? c.speed / 3.6 : 0, course: bearing(p, route.coordinateAtOffset(m + 25)) };
};

async function placeGenerated(c, { km, offRoute, sideMeters }) {
  const carRef = () => doc(c.car.db, `trips/${S.tripId}/cars/${c.carId}`);
  const merge = Math.min(routeLen(), Math.max(0, km * 1000));
  if (offRoute) {
    c.sideMeters = sideMeters ?? c.sideMeters;
    const plan = CarRouteLogic.makePlan(offRouteCoords(S.route, Math.max(merge, 1600), c.sideMeters), S.route);
    c.own = new RouteLine(Polyline.decode(plan.route));
    c.ownOffset = 0;
    c.mergeKm = plan.mergeOffset / 1000;
    c.joining = true;
    c.car.builder = new PositionBuilder(S.route, c.own);
    await updateDoc(carRef(), { route: plan.route, mergeOffset: plan.mergeOffset, state: plan.state });
    say(`${c.label} placed off the route, ${c.sideMeters} m to the side, merging at ${c.mergeKm.toFixed(1)} km (joining)`);
  } else {
    c.offset = merge;
    c.joining = false;
    c.own = null;
    c.mergeKm = null;
    c.car.builder = new PositionBuilder(S.route, null);
    const p = S.route.project(S.route.coordinateAtOffset(merge));
    await updateDoc(carRef(), { route: deleteField(), mergeOffset: p.offset, state: 'convoy' });
    say(`${c.label} placed on the route at ${(merge / 1000).toFixed(1)} km`);
  }
  publishNow(c);
}

function publishNow(c) {
  if (!c.car?.publisher) return;
  c.car.onFix(fixFor(c), 0.8);
  if (!c.car.publisher.inFlight) c.car.publisher.lastSendAt = null; // a move shows at once, not after the 5 s spacing
  c.car.publisher.tick();
}

async function merged(c) {
  const m = S.route.mergeOffset(c.own, CarRouteLogic.mergeTolerance);
  c.offset = m ? m.mainOffset + Math.max(0, c.ownOffset - m.otherOffset) : c.offset;
  c.joining = false;
  c.car.builder = new PositionBuilder(S.route, null);
  say(`${c.label} reached its merge point, now in the convoy`);
  await updateDoc(doc(c.car.db, `trips/${S.tripId}/cars/${c.carId}`), { state: 'convoy' }).catch((e) => say(`${c.label} could not mark itself merged: ${e.message}`));
}

async function setupGenerated(c) {
  const spec = GENERATED[c.key];
  c.car = new Car({ key: c.key, ...spec }, o, say);
  await c.car.connect();
  await c.car.join(S.code);
  c.carId = c.car.carId;
  c.car.route = S.route;
  c.car.builder = new PositionBuilder(S.route, null);
  c.car.publisher = new PositionPublisher({ write: (p) => c.car.writePosition(p), now: nowSeconds });
  c.voted = new Set();
  c.seen = new Map();
  await updateDoc(doc(c.car.db, `trips/${S.tripId}/cars/${c.carId}`), { mergeOffset: c.offset, state: 'convoy' });
  say(`${c.label} (${spec.name}) joined, car ${c.carId}`);
  publishNow(c);
}

const leadOffset = () => Math.max(...KEYS.map((k) => cars[k].joining ? 0 : cars[k].offset));

async function behave(c) {
  if (!c.agree || c.offline) return;
  const ids = pendingVotes(c.car.events, c.carId, c.seen, c.voted, Date.now(), 4000 + Math.random() * 2000);
  for (const id of ids) {
    c.voted.add(id);
    const place = c.suggest ? suggestionAhead(S.route, leadOffset(), GENERATED[c.key].place) : null;
    const suggestion = place && { name: place.name, coordinate: new GeoPoint(place.latitude, place.longitude), routeOffset: place.routeOffset };
    c.car.vote(id, true, suggestion).catch((e) => say(`${c.label}'s vote failed: ${e.message}`));
    say(`${c.label} agrees to the stop${place ? ` and suggests ${place.name} at ${(place.routeOffset / 1000).toFixed(1)} km` : ''}`);
  }
}

// ---------------------------------------------------------------- ticking

let tickNo = 0;
async function tick() {
  tickNo += 1;
  if (S.route) {
    for (const c of Object.values(cars)) {
      if (c.playing) {
        if (c.joining) c.ownOffset = advanceOffset(c.ownOffset, c.speed, 1, c.own.length);
        else c.offset = advanceOffset(c.offset, c.speed, 1, routeLen());
      }
      if (c.kind === 'generated' && c.car?.publisher) {
        if (c.joining) {
          const m = S.route.mergeOffset(c.own, CarRouteLogic.mergeTolerance);
          if (m && c.ownOffset >= m.otherOffset) await merged(c);
        }
        c.car.onFix(fixFor(c), 0.8);
        c.car.publisher.tick();
        await behave(c);
      } else if (c.kind === 'phone' && !c.playing && tickNo % 5 === 0) {
        const p = phone(c);
        simctlAsync('location', p.udid, 'set', locStr(nudged(S.route.coordinateAtOffset(c.offset), c.nudges++))); // a parked simulator needs a changed fix
      }
    }
  }
  emitState();
}

function carState(c) {
  const rep = c.carId ? rest.positions.get(c.carId) : null;
  const doc_ = c.carId ? rest.cars.get(c.carId) : null;
  const shown = c.joining && S.route ? (S.route.project(fixFor(c))?.offset ?? c.offset) : c.offset;
  return {
    key: c.key, label: c.label, kind: c.kind, name: GENERATED[c.key]?.name ?? doc_?.name ?? null, color: GENERATED[c.key]?.color ?? null,
    number: doc_?.number ?? null, joined: c.kind === 'generated' ? Boolean(c.car) : Boolean(c.carId), carId: c.carId,
    offset: Math.round(shown), speed: c.speed, playing: c.playing, joining: c.joining, mergeKm: c.mergeKm, sideMeters: c.sideMeters,
    state: doc_?.state ?? null, offline: c.offline, agree: c.agree, suggest: c.suggest,
    reported: rep ? {
      offset: rep.routeOffset === undefined ? null : Math.round(rep.routeOffset), convoyOffset: rep.convoyOffset === undefined ? null : Math.round(rep.convoyOffset),
      ageSeconds: ageSeconds(rep.updatedAt, Date.now()), speed: rep.speed ?? null,
    } : null,
  };
}

function eventsState() {
  const label = new Map(KEYS.map((k) => [cars[k].carId, cars[k].label]));
  const now = Date.now();
  return rest.events.map((e) => {
    const v = rest.votes.get(e.id) ?? [];
    return {
      id: e.id, type: e.type, category: e.category, by: label.get(e.carId) ?? (e.carId ? 'another car' : null), offset: e.routeOffset === undefined ? null : Math.round(e.routeOffset),
      ageSeconds: ageSeconds(e.createdAt, now), agree: v.filter((x) => x.agree).length, disagree: v.filter((x) => !x.agree).length,
      suggestions: v.filter((x) => x.suggestion).map((x) => x.suggestion.name),
      pinned: e.place?.name ?? null, resolved: Boolean(e.expiresAt) && e.expiresAt <= now,
    };
  }).sort((a, b) => (a.ageSeconds ?? 0) - (b.ageSeconds ?? 0));
}

function emitState() {
  emit({
    type: 'state', phase: S.phase, detail: S.detail, problem: S.problem, start: S.start, code: S.code, tripId: S.tripId,
    destination: S.destination, routeLength: routeLen() || null, defaults: DEFAULTS,
    cars: KEYS.map((k) => carState(cars[k])), events: S.tripId ? eventsState() : [],
  });
}

// ---------------------------------------------------------------- phases

let preparing = false;
async function prepare({ start, skipBuild, derivedData }) {
  if (S.phase !== 'setup' || preparing) { S.problem = 'The phones are already prepared.'; return; }
  S.problem = null;
  let point = null;
  if (!start || start === 'default') point = { latitude: START.latitude, longitude: START.longitude, label: 'The E1 start used by the demos' };
  else {
    const parsed = typeof start === 'string' ? parseStart(start) : start;
    if (!parsed) { S.problem = 'Start should look like 3.45,101.40 (latitude, longitude).'; return; }
    point = { ...parsed, label: `${parsed.latitude.toFixed(5)}, ${parsed.longitude.toFixed(5)}` };
  }
  const busy = NO_SIM ? [] : inUse();
  if (busy.length) {
    S.problem = `The simulators are busy: ${[...new Set(busy.map((b) => `${b.who} on ${b.udids.map((u) => phones.find((p) => p.udid === u)?.label).join(' and ')}`))].join('; ')}. Stop that first.`;
    say(S.problem);
    return;
  }
  preparing = true;
  S.start = point;
  try {
    const dd = derivedData || o.derivedData;
    if (NO_SIM) say('--no-sim: no build, no simulators');
    else if (!skipBuild && !o.skipBuild) {
      S.phase = 'preparing'; S.detail = 'Building the app (a few minutes the first time).';
      emit({ type: 'phase', phase: 'building', detail: 'xcodebuild build-for-testing' });
      fs.mkdirSync(o.logs, { recursive: true });
      const buildLog = path.join(o.logs, 'playground-build.log');
      const xc = spawn('xcodebuild', ['build-for-testing', '-project', path.join(repo, 'ios', 'ikut.xcodeproj'), '-scheme', 'ikut', '-derivedDataPath', dd,
        '-clonedSourcePackagesDirPath', path.join(dd, 'SourcePackages'), '-destination', 'generic/platform=iOS Simulator'], { stdio: ['ignore', fs.openSync(buildLog, 'w'), 'inherit'] });
      const code = await new Promise((r) => xc.on('exit', r));
      if (code !== 0) throw new Error(`The build did not work, see ${buildLog}`);
    }
    const app = path.join(dd, 'Build', 'Products', 'Debug-iphonesimulator', 'ikut.app');
    if (!NO_SIM && !fs.existsSync(app)) throw new Error(`There is no build in ${dd}. Untick “Skip the build”.`);
    S.phase = 'preparing'; S.detail = 'Putting the app on both phones.';
    if (!NO_SIM) for (const p of phones) { say(`preparing ${p.label}`); prepareSimulator(p, app); }
    S.phase = 'waiting'; S.detail = 'Create a trip on phone 1.';
    S.readyAt = Date.now() - 3000;
    say('both phones are ready at the start; waiting for a trip created on phone 1');
    emit({ type: 'phase', phase: 'waiting', detail: S.detail });
  } catch (e) {
    S.phase = 'setup'; S.detail = 'Pick where everyone starts, then prepare the phones.'; S.problem = e.message;
    say(`prepare: ${e.message}`);
  } finally { preparing = false; }
}

let finding = false;
async function waitForTrip() {
  if (S.phase !== 'waiting' || finding) return;
  finding = true;
  try {
    const trip = await findNewTrip(S.readyAt);
    if (!trip) return;
    S.phase = 'joining'; S.detail = 'Daniel and Hafiz are joining.';
    S.code = trip.code; S.tripId = trip.id; S.organizerId = trip.organizerId ?? null;
    S.route = new RouteLine(Polyline.decode(trip.route));
    S.destination = trip.destination?.name ?? '?';
    say(`trip ${trip.code} (${trip.id}), ${(routeLen() / 1000).toFixed(1)} km to ${S.destination}`);
    emit({ type: 'code', code: trip.code });
    for (const k of ['daniel', 'hafiz']) { cars[k].offset = Math.min(cars[k].offset, routeLen()); await setupGenerated(cars[k]); }
    for (const k of ['phone1', 'phone2']) simctl('location', phone(cars[k]).udid, 'set', locStr(S.route.coordinateAtOffset(cars[k].offset)));
    S.phase = 'ready'; S.detail = 'Join on phone 2 with the code, then press Play.';
    emit({ type: 'phase', phase: 'running', detail: 'the playground is ready' });
    timers.push(setInterval(() => { for (const k of ['phone1', 'phone2']) if (cars[k].playing) feedPhone(cars[k]); }, 20_000));
  } catch (e) {
    S.phase = 'waiting'; S.detail = 'Create a trip on phone 1.'; S.problem = e.message; say(`trip: ${e.message}`);
    S.tripId = null; S.code = null;
  } finally { finding = false; }
}

// ---------------------------------------------------------------- commands

async function command(m) {
  const c = cars[m.car];
  const need = () => { if (!c) throw new Error(`no car ${m.car}`); };
  switch (m.cmd) {
    case 'prepare': return prepare(m);
    case 'place': {
      need();
      if (!S.route) return;
      if (c.kind === 'phone') { c.offset = Math.min(routeLen(), Math.max(0, m.km * 1000)); feedPhone(c); say(`${c.label} placed at ${(c.offset / 1000).toFixed(1)} km`); }
      else if (c.car) await placeGenerated(c, m);
      return;
    }
    case 'speed': need(); c.speed = clampKmh(m.kmh); if (c.kind === 'phone') feedPhone(c); say(`${c.label} speed ${c.speed} km/h`); return;
    case 'play': need(); c.playing = Boolean(m.playing); if (c.kind === 'phone') feedPhone(c); else publishNow(c); say(`${c.label} ${c.playing ? 'plays' : 'pauses'}`); return;
    case 'playAll':
      for (const k of KEYS) { cars[k].playing = Boolean(m.playing); if (cars[k].kind === 'phone') feedPhone(cars[k]); }
      say(m.playing ? 'all cars play' : 'all cars pause'); return;
    case 'behaviour': need(); if (c.kind !== 'generated') return; for (const f of ['agree', 'suggest']) if (typeof m[f] === 'boolean') c[f] = m[f]; say(`${c.label}: agrees ${c.agree}, suggests a place ${c.suggest}`); return;
    case 'drop':
      need();
      if (c.kind !== 'generated' || !c.car) return;
      if (m.offline && !c.offline) { c.offline = true; await c.car.goOffline(); say(`${c.label} loses signal`); }
      else if (!m.offline && c.offline) { c.offline = false; await c.car.goOnline(); say(`${c.label} has signal again`); }
      return;
    default: throw new Error(`unknown command ${m.cmd}`);
  }
}

// ---------------------------------------------------------------- go

setLogLevel('error');
console.log(`ikut playground: emulators on ${o.host}, phone 1 ${o.udid}, phone 2 ${o.udid2}`);
emit({ type: 'backend', backend: 'emulators', project: firebaseConfig(o, 'x').projectId });
emit({ type: 'phase', phase: 'waiting', detail: 'pick a start and prepare the phones' });

createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.startsWith('CMD ')) return;
  let m;
  try { m = JSON.parse(line.slice(4)); } catch { say(`bad command: ${line}`); return; }
  command(m).catch((e) => { S.problem = e.message; say(`command ${m.cmd}: ${e.message}`); });
});

timers.push(setInterval(() => { tick().catch((e) => say(`tick: ${e.message}`)); }, 1000));
timers.push(setInterval(() => { waitForTrip(); pollRest().catch(() => {}); }, 1500));

let leaving = false;
async function leave(sig) {
  if (leaving) return;
  leaving = true;
  say(`${sig}: closing; the trip is left as it is (end it on phone 1)`);
  timers.forEach(clearInterval);
  for (const c of Object.values(cars)) { stopPlayer(c); }
  for (const p of phones) simctl('location', p.udid, 'clear');
  for (const c of Object.values(cars)) await c.car?.close().catch(() => {});
  emit({ type: 'phase', phase: 'ended', detail: 'playground closed' });
  process.exit(0);
}
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => leave(sig));
process.stdin.on('end', () => leave('stdin closed'));
