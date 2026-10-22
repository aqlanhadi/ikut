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
// every second, the shared route and each car's own roads as `DEMO {"type":"geometry"}` whenever they change.
// Every car drives a TRACK (lib/playground.mjs): the shared route from a km, or a start road that merges into it, an own
// ending, a deviation (out to a pin, wait, back). Commands: prepare, useTrip, placeAt, ending, clearEnding, deviate,
// cancelDeviation, addCar, removeCar, rename, vote, voteAll, askStop, report, and the older place, speed, play, playAll,
// behaviour, drop. Cars: phone1, phone2, daniel, hafiz, g3, g4... Details in qa/README.md ("Playground").


import { execFile, spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { GeoPoint, deleteField, doc, setLogLevel, updateDoc } from 'firebase/firestore';
import { START, Car, PROJECT_ID, emit, firebaseConfig, parseArgs, repo, standInRoute } from './lib/demo-common.mjs';
import { loadRoutes } from './generate-gpx.mjs';
import { CarRouteLogic, Polyline, RouteLine, haversine } from './lib/route.mjs';
import { PositionBuilder, PositionPublisher } from './lib/tracking.mjs';
import {
  MAX_GENERATED, REPORT_TYPES, STOP_TYPES, UserError, ageSeconds, answersByCar, autoPick, carNameFor, composeTrack, coordIn, decodeDoc,
  encodeLine, eventKindIn, eventStatus, locate, mainDistance, nameIn, newCarState, nextCar, nextWait, nudged, numberIn, offRouteCoords,
  openStopSnapshot, optionalCoords, pendingVotes, placeOnRoute, planDeviation, planEnding, planStart, relocate, shouldPark, sideRoad, startFrom,
  stepTrack, suggestionAhead, trackFeedPoints, validDerivedData, destinationPoint, LEAVE_SLACK,
} from './lib/playground.mjs';

// --no-sim (developing the script itself): no builds and no simctl calls at all, for trying the cars without simulators.
const NO_SIM = process.argv.includes('--no-sim') || process.env.IKUT_PLAYGROUND_NO_SIM === '1';
const o = parseArgs(process.argv.filter((a) => a !== '--no-sim'), 'See the header of demo-playground.mjs (qa/README.md, "Playground").');
const BUNDLE = 'dev.aqlan.ikut';

const phones = [
  { id: 'phone1', udid: o.udid, label: 'iPhone 17 #1', role: 'Organizer: creates the trip by hand' },
  { id: 'phone2', udid: o.udid2, label: 'iPhone 17 #2', role: 'Joins by hand with the trip code, as its own car' },
];
/** The two generated cars every playground starts with; more come from addCar (lib/playground.mjs nextCar). */
const FIRST_GENERATED = [
  { key: 'daniel', label: 'Daniel', name: 'Daniel’s City', color: '#7C3AED', place: 'R&R Demo' },
  { key: 'hafiz', label: 'Hafiz', name: 'Hafiz’s Hilux', color: '#0F766E', place: 'Rest Stop Demo' },
];
const PHONE_COLORS = { phone1: '#0a6cff', phone2: '#d9480f' };
const DEFAULTS = { phone1: 3000, phone2: 2200, daniel: 1400, hafiz: 600 };
const KEYS = ['phone1', 'phone2', 'daniel', 'hafiz'];
const DEFAULT_KMH = 90;
const BACK_OF_CONVOY = 500; // an added car starts this far behind the last car

if (o.describe) {
  console.log(JSON.stringify({
    id: 'playground', interactive: true, title: 'Playground',
    summary: 'A playable route for two simulators: you tap the real app, this places the cars, sets their speeds and plays or pauses them. Two more cars are generated, and more can be added.',
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

if (o.dryRun) process.exit(dryRun());

// ---------------------------------------------------------------- state

const t0 = Date.now();
const nowSeconds = () => (Date.now() - t0) / 1000;
const defaultStart = () => ({ latitude: START.latitude, longitude: START.longitude, label: 'The E1 start used by the demos' });
const S = {
  phase: 'setup', detail: 'Pick where everyone starts, then prepare the phones.', problem: null, problemAt: null,
  start: defaultStart(), starts: null, newStarts: false,
  code: null, tripId: null, destination: null, destinationPin: null, route: null, routeEncoded: null, organizerId: null,
  candidates: [], ended: false,
};
const failedTrips = new Set(); // trips the generated cars could not join: not offered again by themselves
const touched = new Set(); // simulators this run has put something on: only those are cleared when it closes
let geomVersion = 0;
let geomDirty = false;
let nextKeyNo = 3; // generated car keys: daniel, hafiz, g3, g4... never reused

/** Everyone in the playground, by key (insertion order is the order on the page). */
const cars = {};
function makeCar(key, kind, props) {
  const c = {
    key, kind, label: props.label, name: props.name ?? null, appName: props.name ?? null, color: props.color ?? PHONE_COLORS[key] ?? null, place: props.place ?? null,
    speed: DEFAULT_KMH, playing: false, moving: false,
    base: { kind: 'main', offset: props.offset ?? 0 }, startPin: null, deviation: null, ending: null, // the pieces of the track
    track: null, st: newCarState(), loc: null, parked: null, group: null, legsVersion: 0,
    sideMeters: 2000, offline: false, agree: false, suggest: false, carId: null, car: null, player: null, nudges: 0, voted: new Set(), seen: new Map(),
  };
  cars[key] = c;
  return c;
}
for (const k of ['phone1', 'phone2']) makeCar(k, 'phone', { label: k === 'phone1' ? 'Phone 1' : 'Phone 2', offset: DEFAULTS[k] });
for (const g of FIRST_GENERATED) makeCar(g.key, 'generated', { ...g, offset: DEFAULTS[g.key] });
const allCars = () => Object.values(cars);
const generatedCars = () => allCars().filter((c) => c.kind === 'generated');

const removedCarIds = new Set(); // cars the playground removed: their docs stay in the trip, but they are not a phone's
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
  const ps = spawnSync('ps', ['-axo', 'pid=,ppid=,command='], { encoding: 'utf8' }).stdout.split('\n');
  const parents = new Map();
  for (const line of ps) { const m = /^\s*(\d+)\s+(\d+)\s/.exec(line); if (m) parents.set(Number(m[1]), Number(m[2])); }
  const mine = new Set([process.pid]); // this process and the ones that started it (an agent's `zsh -c '... node demo-playground.mjs'`)
  for (let p = parents.get(process.pid); p && !mine.has(p); p = parents.get(p)) mine.add(p);
  const found = [];
  for (const line of ps) {
    const m = /^\s*(\d+)\s+\d+\s+(.*)$/.exec(line);
    if (!m || mine.has(Number(m[1]))) continue;
    const cmd = m[2];
    if (/--describe|--dry-run/.test(cmd) || /^(ps|grep)\b/.test(cmd)) continue;
    let who = null; // a demo counts only as the node process itself, not as a shell wrapper around it (`zsh -c 'node ...'`)
    if (/^\S*node\s.*\b(demo[\w-]*|run-ui|run-convoy2|drive-trip|convoy-sim)\.mjs/.test(cmd)) who = `${/([\w-]+)\.mjs/.exec(cmd)[1]} (running)`;
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
  touched.add(p.udid);
  simctl('location', p.udid, 'set', locStr((S.starts ?? {})[p.id] ?? S.start));
  const l = simctl('launch', p.udid, BUNDLE);
  if (l.status !== 0) throw new Error(`could not open the app on ${p.label}: ${l.stderr.trim()}`);
}

function stopPlayer(c) { c.player?.kill(); c.player = null; }

/** Point the simulator of a phone at its car: play the track from the car's distance at its speed (up to the next wait), or park there. */
function feedPhone(c) {
  const p = phone(c);
  if (!S.route || !p) return;
  stopPlayer(c);
  touched.add(p.udid);
  if (!c.track) { if (c.parked) simctlAsync('location', p.udid, 'set', locStr(c.parked)); return; }
  const at = refreshLoc(c).point;
  const stopAt = nextWait(c.track, c.st)?.startAt ?? null;
  const points = trackFeedPoints(c.track, c.st.d, { stopAt });
  if (!c.playing || c.speed <= 0 || c.st.waiting || shouldPark(c.st.d, c.track.length) || points.length < 2) { simctlAsync('location', p.udid, 'set', locStr(at)); return; }
  if (NO_SIM) return;
  const loc = spawn('xcrun', ['simctl', 'location', p.udid, 'start', `--speed=${(c.speed / 3.6).toFixed(2)}`, '--interval=1', '-']);
  loc.stdin.end(`${points.map(locStr).join('\n')}\n`);
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
async function activeTrips() {
  const res = await fetch(`${REST}:runQuery`, {
    method: 'POST', headers,
    body: JSON.stringify({ structuredQuery: { from: [{ collectionId: 'trips' }], where: { fieldFilter: { field: { fieldPath: 'status' }, op: 'EQUAL', value: { stringValue: 'active' } } } } }),
  });
  if (!res.ok) throw new Error(`the Firestore emulator answered ${res.status}`);
  return (await res.json()).filter((r) => r.document).map((r) => decodeDoc(r.document)).filter((t) => t.route && t.code);
}
/** New active trips since Prepare, newest first, with what tells a phone-made trip from a script's: its cars and where the first one is. */
async function scanTrips() {
  const fresh = (await activeTrips()).filter((t) => (t.createdAt ?? 0) >= S.readyAt && !failedTrips.has(t.id)).sort((a, b) => b.createdAt - a.createdAt).slice(0, 5);
  return Promise.all(fresh.map(async (t) => {
    const [carDocs, positions] = await Promise.all([restList(`trips/${t.id}/cars`), restList(`trips/${t.id}/positions`)]);
    const first = [...carDocs].sort((x, y) => (x.number ?? 99) - (y.number ?? 99))[0];
    const pos = first && positions.find((p) => p.id === first.id)?.location;
    return { tripId: t.id, code: t.code, destination: t.destination?.name ?? '?', cars: carDocs.length, firstCarDistance: pos ? Math.round(haversine(pos, S.start)) : null, trip: t };
  }));
}
async function tripEnded() {
  const r = await fetch(`${REST}/trips/${S.tripId}`, { headers });
  return r.ok && decodeDoc(await r.json()).status !== 'active';
}
async function pollRest() {
  if (!S.tripId || S.ended) return;
  if (S.phase === 'ready' && await tripEnded()) return endPlayground();
  const base = `trips/${S.tripId}`;
  const [positions, carDocs, events] = await Promise.all([restList(`${base}/positions`), restList(`${base}/cars`), restList(`${base}/events`)]);
  const votes = new Map();
  await Promise.all(events.filter((e) => e.category === 'stopRequest').map(async (e) => votes.set(e.id, await restList(`${base}/events/${e.id}/votes`))));
  rest = { positions: new Map(positions.map((p) => [p.id, p])), cars: new Map(carDocs.map((c) => [c.id, c])), events, votes };
  // Phone 1 is the organizer's car, phone 2 the other car that is not generated.
  const generated = new Set([...generatedCars().map((c) => c.carId), ...removedCarIds]);
  const mine = carDocs.filter((c) => !generated.has(c.id));
  cars.phone1.carId = mine.find((c) => c.trackerUserId && c.trackerUserId === S.organizerId)?.id ?? mine.find((c) => c.isLead)?.id ?? null;
  cars.phone2.carId = mine.find((c) => c.id !== cars.phone1.carId)?.id ?? null;
}

// ---------------------------------------------------------------- tracks

/** The track of a car's pieces (start, deviation, ending) on the trip's route. */
const composeFor = (c) => composeTrack(S.route, {
  startOffset: c.base.kind === 'main' ? c.base.offset : 0, start: c.base.kind === 'road' ? c.base : null, deviation: c.deviation, ending: c.ending,
});

function refreshLoc(c) {
  c.loc = c.track ? locate(c.track, c.st.d, { waiting: c.st.waiting?.id ?? null }) : null;
  return c.loc;
}

/**
 * Put `track` under a car. `keep`: the car stays where it is (the same shared-route offset, or the same place on the same own
 * road); when that place is gone it goes to `fallbackOffset` on the shared route, else to its nearest point on it. Not `keep`:
 * it starts at the beginning.
 */
function applyTrack(c, track, { keep = true, fallbackOffset = null } = {}) {
  const old = c.track;
  let d = 0;
  let waiting = null;
  let served = new Set();
  if (old && keep) {
    d = relocate(old, c.st.d, c.st.waiting?.id ?? null, track);
    if (d === null) d = fallbackOffset !== null ? mainDistance(track, fallbackOffset) : null;
    if (d === null) d = mainDistance(track, S.route.project(refreshLoc(c).point)?.offset ?? 0) ?? 0;
    const ids = new Set(track.legs.map((l) => l.id));
    served = new Set([...c.st.served].filter((id) => ids.has(id)));
    if (c.st.waiting && ids.has(c.st.waiting.id)) waiting = c.st.waiting;
  }
  c.track = track;
  c.st = { d, waiting, served };
  c.legsVersion += 1;
  geomDirty = true;
  refreshLoc(c);
}

/** Try a change to a car's pieces; when they no longer fit together, put everything back and tell the person. */
function changePieces(c, patch, applyOptions) {
  const saved = { base: c.base, startPin: c.startPin, deviation: c.deviation, ending: c.ending };
  Object.assign(c, patch);
  try {
    applyTrack(c, composeFor(c), applyOptions);
  } catch (e) {
    Object.assign(c, saved);
    throw e;
  }
}

/** The first shared-route offset where this car can still turn off for an ending or a deviation: where it is, or where it rejoins. */
function leaveFloor(c) {
  const loc = refreshLoc(c);
  if (loc.onMain) return loc.mainOffset;
  if (loc.phase === 'joining') return c.base.mergeMain;
  if (['out', 'waiting', 'back'].includes(loc.phase)) return c.deviation.mergeMain;
  return Infinity; // on its ending road: nothing is left to leave
}

const groupOf = (loc) => (loc.onMain ? 'main' : loc.phase === 'joining' ? 'start' : loc.phase === 'ending' || loc.phase === 'arrived' ? 'end' : 'dev');
const ownRouteOf = (encoded) => new RouteLine(Polyline.decode(encoded));

// ---------------------------------------------------------------- generated cars

const fixFor = (c) => {
  const loc = c.loc ?? refreshLoc(c);
  return { latitude: loc.point.latitude, longitude: loc.point.longitude, speed: c.moving ? c.speed / 3.6 : 0, course: loc.heading };
};

/**
 * The car doc and the position builder for the part of the track a car is on (what CarRouteService writes, as in convoy-sim's car 4):
 * on the shared route: convoy; on a start road: its road, mergeOffset, joining; out, waiting and back: the whole deviation road (leave point to
 * merge), joining; on its own ending: that road, which never rejoins (CarRouteLogic.makePlan: mergeOffset where its end projects), joining.
 * `reset` (a car placed somewhere new) also clears an old route; a plain merge only marks the car convoy again.
 */
function enterGroup(c, group, { reset = false } = {}) {
  const prev = c.group;
  c.group = group;
  if (!c.car?.publisher) return;
  let fields;
  if (group === 'main') {
    c.car.builder = new PositionBuilder(S.route, null);
    const fresh = reset || prev === 'end';
    fields = fresh ? { route: deleteField(), mergeOffset: S.route.project(c.loc.point).offset, state: 'convoy' } : { state: 'convoy' };
  } else {
    const plan = group === 'start' ? c.base.plan : group === 'dev' ? c.deviation.plan : c.ending.plan;
    c.car.builder = new PositionBuilder(S.route, ownRouteOf(plan.route));
    fields = { route: plan.route, mergeOffset: plan.mergeOffset, state: plan.state };
  }
  updateDoc(doc(c.car.db, `trips/${S.tripId}/cars/${c.carId}`), fields).catch((e) => say(`${c.label} could not update its car: ${e.message}`));
  say(`${c.label} is ${group === 'main' ? 'on the shared route' : group === 'start' ? 'on its way to the route (joining)' : group === 'dev' ? 'off the route on a deviation (joining)' : 'on its own road to its end'}`);
}

/** After a car was put somewhere (placeAt, place, an added car): its doc, its position, its simulator. */
function afterMove(c) {
  if (c.kind === 'phone') return feedPhone(c);
  if (!c.car?.publisher) return;
  enterGroup(c, groupOf(refreshLoc(c)), { reset: true });
  publishNow(c);
}

function publishNow(c) {
  if (!c.car?.publisher) return;
  c.car.onFix(fixFor(c), 0.8);
  if (!c.car.publisher.inFlight) c.car.publisher.lastSendAt = null; // a move shows at once, not after the 5 s spacing
  c.car.publisher.tick();
}

async function setupGenerated(c) {
  c.car = new Car({ key: c.key, displayName: c.label, name: c.name, color: c.color }, o, say);
  if (process.env.IKUT_PLAYGROUND_FAIL_JOIN === c.key) throw new Error('forced join failure (IKUT_PLAYGROUND_FAIL_JOIN, for trying the retry path)');
  await c.car.connect();
  await c.car.join(S.code);
  c.carId = c.car.carId;
  c.appName = c.name;
  c.car.route = S.route;
  c.car.builder = new PositionBuilder(S.route, null);
  c.car.publisher = new PositionPublisher({ write: (p) => c.car.writePosition(p), now: nowSeconds });
  if (!c.track) applyTrack(c, composeFor(c), { keep: false });
  refreshLoc(c);
  c.group = null;
  const g = groupOf(c.loc);
  if (g === 'main') await updateDoc(doc(c.car.db, `trips/${S.tripId}/cars/${c.carId}`), { mergeOffset: S.route.project(c.loc.point).offset, state: 'convoy' });
  else enterGroup(c, g, { reset: true });
  c.group = g;
  say(`${c.label} (${c.name}) joined, car ${c.carId}`);
  publishNow(c);
}

const leadOffset = () => Math.max(0, ...allCars().map((c) => (c.loc?.phase === 'onRoute' ? c.loc.mainOffset : 0)));

async function behave(c) {
  if (!c.agree || c.offline) return;
  const ids = pendingVotes(c.car.events, c.carId, c.seen, c.voted, Date.now(), 4000 + Math.random() * 2000);
  for (const id of ids) {
    c.voted.add(id);
    const place = c.suggest ? suggestionAhead(S.route, leadOffset(), c.place ?? `${c.label}’s pick`) : null;
    const suggestion = place && { name: place.name, coordinate: new GeoPoint(place.latitude, place.longitude), routeOffset: place.routeOffset };
    c.car.vote(id, true, suggestion).catch((e) => say(`${c.label}'s vote failed: ${e.message}`));
    say(`${c.label} agrees to the stop${place ? ` and suggests ${place.name} at ${(place.routeOffset / 1000).toFixed(1)} km` : ''}`);
  }
}

// ---------------------------------------------------------------- ticking

let tickNo = 0;
async function tick() {
  tickNo += 1;
  if (S.route && !S.ended) {
    for (const c of allCars()) {
      try {
        await tickCar(c);
      } catch (e) { if (!c.failing) say(`${c.label}: ${e.message}`); c.failing = true; continue; }
      c.failing = false;
    }
  }
  emitState();
}

const isParked = (c) => !c.playing || c.speed <= 0 || Boolean(c.st.waiting) || (c.track && shouldPark(c.st.d, c.track.length));

async function tickCar(c) {
  if (S.ended || !c.track) return;
  const before = c.st;
  c.st = stepTrack(c.track, c.st, c.speed, 1, c.playing);
  const loc = refreshLoc(c);
  c.moving = c.st.d > before.d + 1e-6;
  if (before.waiting && !c.st.waiting) say(`${c.label} has waited and drives back`);
  else if (!before.waiting && c.st.waiting) say(`${c.label} reached its pin and waits ${c.st.waiting.left} s`);
  if (c.kind === 'generated' && c.car?.publisher) {
    const g = groupOf(loc);
    if (g !== c.group) enterGroup(c, g);
    c.car.onFix(fixFor(c), 0.8);
    c.car.publisher.tick();
    await behave(c);
  } else if (c.kind === 'phone') {
    if (Boolean(before.waiting) !== Boolean(c.st.waiting)) feedPhone(c);
    else if (isParked(c) && tickNo % 5 === 0) simctlAsync('location', phone(c).udid, 'set', locStr(nudged(loc.point, c.nudges++))); // a parked simulator needs a changed fix
  }
}

const point2 = (p) => (p ? { latitude: p.latitude, longitude: p.longitude } : null);

function carState(c) {
  const rep = c.carId ? rest.positions.get(c.carId) : null;
  const doc_ = c.carId ? rest.cars.get(c.carId) : null;
  const loc = c.track ? (c.loc ?? refreshLoc(c)) : null;
  const here = loc?.point ?? c.parked ?? null;
  const shown = loc ? (loc.onMain ? loc.mainOffset : (S.route?.project(loc.point)?.offset ?? 0)) : here && S.route ? (S.route.project(here)?.offset ?? 0) : c.base.kind === 'main' ? c.base.offset : 0;
  const phase = loc ? loc.phase : c.parked ? 'parked' : null;
  const e = c.ending;
  const dev = c.deviation;
  return {
    key: c.key, label: c.label, kind: c.kind, name: c.kind === 'generated' ? c.appName : doc_?.name ?? null, color: c.kind === 'generated' ? c.color : doc_?.color ?? c.color,
    number: doc_?.number ?? null, joined: c.kind === 'generated' ? Boolean(c.car) : Boolean(c.carId), carId: c.carId,
    offset: Math.round(shown), speed: c.speed, playing: c.playing, joining: phase === 'joining', mergeKm: c.base.kind === 'road' ? c.base.mergeMain / 1000 : null, sideMeters: c.sideMeters,
    state: doc_?.state ?? null, offline: c.offline, agree: c.agree, suggest: c.suggest,
    latitude: here?.latitude ?? null, longitude: here?.longitude ?? null, heading: loc ? Math.round(loc.heading) : null,
    phase, waitSecondsLeft: c.st.waiting ? Math.ceil(c.st.waiting.left) : null,
    trackMeters: c.track ? { at: Math.round(c.st.d), of: Math.round(c.track.length) } : null,
    pins: {
      start: point2(c.startPin), startMergeKm: c.base.kind === 'road' ? c.base.mergeMain / 1000 : null,
      end: point2(e?.end), endLeaveKm: e ? (e.kind === 'road' ? e.leaveOffset / 1000 : null) : null, endOnRoute: Boolean(e && e.kind === 'onRoute'),
      deviation: dev ? { pin: point2(dev.pin), leaveKm: dev.leaveOffset / 1000, mergeKm: dev.mergeMain / 1000, waitSeconds: dev.waitSeconds } : null,
    },
    legsVersion: c.legsVersion,
    reported: rep ? {
      offset: rep.routeOffset === undefined ? null : Math.round(rep.routeOffset), convoyOffset: rep.convoyOffset === undefined ? null : Math.round(rep.convoyOffset),
      ageSeconds: ageSeconds(rep.updatedAt, Date.now()), speed: rep.speed ?? null,
      latitude: rep.location?.latitude ?? null, longitude: rep.location?.longitude ?? null, heading: rep.heading ?? null,
    } : null,
  };
}

function eventsState() {
  const keyOf = new Map(allCars().filter((c) => c.carId).map((c) => [c.carId, c.key]));
  const label = new Map(allCars().filter((c) => c.carId).map((c) => [c.carId, c.label]));
  const now = Date.now();
  return rest.events.map((e) => {
    const v = rest.votes.get(e.id) ?? [];
    return {
      id: e.id, type: e.type, category: e.category, by: label.get(e.carId) ?? (e.carId ? 'another car' : null), byKey: keyOf.get(e.carId) ?? null,
      offset: e.routeOffset === undefined ? null : Math.round(e.routeOffset), latitude: e.location?.latitude ?? null, longitude: e.location?.longitude ?? null,
      ageSeconds: ageSeconds(e.createdAt, now), status: eventStatus(e, now), agree: v.filter((x) => x.agree).length, disagree: v.filter((x) => !x.agree).length,
      answers: answersByCar(v, keyOf), suggestions: v.filter((x) => x.suggestion).map((x) => x.suggestion.name),
      pinned: e.place?.name ?? null, resolved: Boolean(e.expiresAt) && e.expiresAt <= now,
    };
  }).sort((a, b) => (a.ageSeconds ?? 0) - (b.ageSeconds ?? 0));
}

/** The shared route and every car's own roads: sent when they change, not every second (the state carries geometryVersion). */
function emitGeometry() {
  geomVersion += 1;
  geomDirty = false;
  emit({
    type: 'geometry', version: geomVersion, route: S.routeEncoded, routeLength: routeLen() || null,
    destination: S.destinationPin ? { name: S.destination, ...S.destinationPin } : null,
    cars: Object.fromEntries(allCars().map((c) => [c.key, {
      version: c.legsVersion,
      legs: (c.track?.legs ?? []).filter((l) => l.kind === 'own').map((l) => ({ role: l.role, polyline: encodeLine(l.line), meters: Math.round(l.line.length) })),
    }])),
  });
}

function emitState() {
  if (geomDirty) emitGeometry();
  emit({
    type: 'state', phase: S.phase, detail: S.detail, problem: S.problem, problemAt: S.problemAt, start: S.start, starts: S.starts, code: S.code, tripId: S.tripId,
    destination: S.destination, routeLength: routeLen() || null, geometryVersion: geomVersion, defaults: DEFAULTS, candidates: S.phase === 'waiting' ? S.candidates : [],
    cars: allCars().map(carState), events: S.tripId ? eventsState() : [],
  });
}

// ---------------------------------------------------------------- phases

let preparing = false;
const pointLabel = (p) => `${p.latitude.toFixed(5)}, ${p.longitude.toFixed(5)}`;
/** A start from the page: the word "default", "lat,lng" text (the old page), or {latitude, longitude}; null for default. */
function startPoint(v, what) {
  if (v === undefined || v === null || v === 'default') return null;
  if (typeof v === 'object') return { ...coordIn(v, what), label: pointLabel(coordIn(v, what)) };
  const p = startFrom(v);
  return p === 'default' ? null : { ...p, label: pointLabel(p) };
}

async function prepare({ start, starts, skipBuild, derivedData }) {
  if (S.phase !== 'setup' || preparing) { S.problem = 'The phones are already prepared.'; return; }
  S.problem = null;
  if (starts !== undefined && (starts === null || typeof starts !== 'object' || Array.isArray(starts))) throw new UserError('The starts should name a place for each phone.');
  const single = startPoint(start, 'The start') ?? defaultStart();
  const s1 = starts?.phone1 ? startPoint(starts.phone1, 'Phone 1’s start') : null;
  const s2 = starts?.phone2 ? startPoint(starts.phone2, 'Phone 2’s start') : null;
  const dd = validDerivedData(derivedData) || o.derivedData;
  const busy = NO_SIM ? [] : inUse();
  if (busy.length) {
    S.problem = `The simulators are busy: ${[...new Set(busy.map((b) => `${b.who} on ${b.udids.map((u) => phones.find((p) => p.udid === u)?.label).join(' and ')}`))].join('; ')}. Stop that first.`;
    say(S.problem);
    return;
  }
  preparing = true;
  S.newStarts = Boolean(starts);
  S.starts = { phone1: s1 ?? single, phone2: s2 ?? single };
  S.explicit2 = Boolean(s2);
  S.start = S.starts.phone1;
  try {
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
    S.phase = 'setup'; S.detail = 'Pick where everyone starts, then prepare the phones.'; S.problem = e.message; S.starts = null;
    say(`prepare: ${e.message}`);
  } finally { preparing = false; }
}

let finding = false;
/** While waiting: list the new trips for the page, and take one by itself only when it is surely the one phone 1 made. */
async function waitForTrip() {
  if (S.phase !== 'waiting' || finding) return;
  finding = true;
  try {
    const found = await scanTrips();
    S.candidates = found.map(({ trip, ...c }) => c);
    const pick = autoPick(S.candidates);
    if (pick) await attachTrip(found.find((f) => f.tripId === pick.tripId).trip);
  } catch (e) { say(`looking for the trip: ${e.message}`); } finally { finding = false; }
}

/** Put a car at a pin: on the shared route when the pin is within 150 m of it, else on a road that merges into it (joining). */
function placeCar(c, start, road) {
  const info = planStart(S.route, start, road);
  const base = info.kind === 'main' ? { kind: 'main', offset: info.offset } : { kind: 'road', ...info };
  const keepEnding = c.ending;
  try {
    changePieces(c, { base, startPin: start, deviation: null, parked: null }, { keep: false });
  } catch (e) {
    if (!(e instanceof UserError) || !keepEnding) throw e;
    say(`${c.label}'s ending is before its new start, so it is dropped`);
    changePieces(c, { base, startPin: start, deviation: null, ending: null, parked: null }, { keep: false });
  }
  if (info.kind === 'road') say(`${c.label} placed off the route${info.straight ? ' (straight road)' : ''}, merging at ${(info.mergeMain / 1000).toFixed(1)} km (joining)`);
  else say(`${c.label} placed on the route at ${(info.offset / 1000).toFixed(1)} km`);
  afterMove(c);
}

/** Every generated car joins this trip: nothing is joined before this. */
async function attachTrip(trip) {
  if (S.phase !== 'waiting') return;
  S.phase = 'joining'; S.detail = 'The generated cars are joining.'; S.problem = null;
  S.code = trip.code; S.tripId = trip.id; S.organizerId = trip.organizerId ?? null;
  try {
    S.route = new RouteLine(Polyline.decode(trip.route));
    S.routeEncoded = trip.route;
    S.destination = trip.destination?.name ?? '?';
    S.destinationPin = trip.destination?.coordinate ? point2(trip.destination.coordinate) : null;
    geomDirty = true;
    say(`using trip ${trip.code} (${trip.id}), ${(routeLen() / 1000).toFixed(1)} km to ${S.destination}`);
    emit({ type: 'code', code: trip.code });
    for (const c of allCars()) {
      c.base = c.base.kind === 'main' ? { kind: 'main', offset: Math.min(c.base.offset, routeLen()) } : c.base;
      if (c.kind === 'phone' && S.newStarts) continue; // placed below, from its own start
      applyTrack(c, composeFor(c), { keep: false });
    }
    for (const c of generatedCars()) await setupGenerated(c);
    for (const k of ['phone1', 'phone2']) {
      const c = cars[k];
      if (S.newStarts && k === 'phone1') placeCar(c, S.starts.phone1, null);
      else if (S.newStarts && S.explicit2) { c.parked = { latitude: S.starts.phone2.latitude, longitude: S.starts.phone2.longitude }; c.startPin = c.parked; simctl('location', phone(c).udid, 'set', locStr(c.parked)); }
      else if (S.newStarts) { applyTrack(c, composeFor(c), { keep: false }); simctl('location', phone(c).udid, 'set', locStr(refreshLoc(c).point)); }
      else simctl('location', phone(c).udid, 'set', locStr(refreshLoc(c).point));
    }
    S.phase = 'ready'; S.detail = 'Join on phone 2 with the code, then press Play.';
    emit({ type: 'phase', phase: 'running', detail: 'the playground is ready' });
  } catch (e) {
    say(`joining trip ${trip.code}: ${e.message}`);
    failedTrips.add(trip.id); // not offered again by itself
    for (const c of generatedCars()) { await c.car?.close().catch(() => {}); c.car = null; c.carId = null; c.track = null; c.loc = null; }
    for (const c of allCars()) { c.track = null; c.loc = null; c.group = null; }
    S.phase = 'waiting'; S.detail = 'Create a trip on phone 1, or type its code.';
    S.problem = `The generated cars could not join trip ${trip.code}. Pick it again, or use another trip.`;
    S.tripId = null; S.code = null; S.route = null; S.routeEncoded = null; S.destination = null; S.destinationPin = null;
    geomDirty = true;
  }
}

/** The trip is over (phone 1 ended it): the generated cars' writes would be rejected, so stop them. */
async function endPlayground() {
  if (S.ended) return;
  S.ended = true; S.phase = 'ended'; S.detail = 'The trip has ended.';
  say('the trip has ended; stopping the generated cars');
  for (const c of allCars()) { c.playing = false; stopPlayer(c); }
  for (const c of generatedCars()) await c.car?.close().catch(() => {});
  emit({ type: 'phase', phase: 'ended', detail: 'the trip has ended' });
}

// ---------------------------------------------------------------- commands

const needRoute = () => { if (!S.route || S.ended) throw new UserError('Pick the trip first: create it on phone 1, then press Use this trip.'); };
const needJoined = (c, what) => {
  if (c.kind !== 'generated') throw new UserError(`Only the generated cars can ${what}. Use the app on the phone.`);
  if (!c.car?.publisher) throw new UserError(`${c.label} has not joined the trip yet.`);
  if (c.offline) throw new UserError(`${c.label} has no signal. Give it signal back first.`);
};
const needPlaced = (c) => {
  needRoute();
  if (!c.track) throw new UserError(`Put ${c.label} on the map first.`);
};
const plainWrite = (e, what) => (e?.code === 'permission-denied' ? new UserError(`${what} was not accepted (the request may have been closed).`) : e);

/** The newest copy of a stop request as one generated car sees it. */
function openStopFor(c, eventId) {
  if (typeof eventId !== 'string' || !eventId) throw new UserError('Pick a stop request first.');
  const e = c.car.events.find((x) => x.id === eventId);
  if (!e || e.category !== 'stopRequest') throw new UserError('That stop request is not on the trip.');
  if (!openStopSnapshot(e)) throw new UserError('That stop request is already closed.');
  return e;
}
const suggestionOf = (place) => place && { name: place.name, coordinate: new GeoPoint(place.latitude, place.longitude), routeOffset: place.routeOffset };

async function addCar(m) {
  if (S.phase === 'joining') throw new UserError('The generated cars are still joining. Try again in a moment.');
  if (generatedCars().length >= MAX_GENERATED) throw new UserError(`The playground has ${MAX_GENERATED} generated cars already, the most it can hold.`);
  const counter = nextKeyNo;
  const next = nextCar(generatedCars(), counter);
  const label = m.name === undefined || m.name === null ? next.label : nameIn(m.name);
  const key = `g${nextKeyNo++}`;
  const offsets = allCars().map((x) => (x.loc?.onMain ? x.loc.mainOffset : x.base.kind === 'main' ? x.base.offset : null)).filter((x) => x !== null);
  const c = makeCar(key, 'generated', { label, name: carNameFor(label, counter), color: next.color, place: `${label}’s pick`, offset: Math.max(0, Math.min(...offsets, 3000) - BACK_OF_CONVOY) });
  say(`${c.label} added (${key}, ${c.name}), ${(c.base.offset / 1000).toFixed(1)} km`);
  if (S.route && !S.ended && S.phase === 'ready') {
    try {
      applyTrack(c, composeFor(c), { keep: false });
      await setupGenerated(c);
    } catch (e) {
      await c.car?.close().catch(() => {});
      delete cars[key];
      geomDirty = true;
      say(`${label} could not join: ${e.message}`);
      throw new UserError(`${label} could not join the trip.`);
    }
    geomDirty = true;
  }
}

async function removeCar(c) {
  if (c.kind !== 'generated') throw new UserError('The phones stay. End the trip from phone 1 when you are done.');
  stopPlayer(c);
  c.playing = false;
  delete cars[c.key];
  if (c.carId) removedCarIds.add(c.carId);
  geomDirty = true;
  await c.car?.close().catch(() => {});
  say(`${c.label} removed; the trip keeps its car, which the other phones will see go stale`);
}

async function renameCar(c, nameValue) {
  if (c.kind !== 'generated') throw new UserError('A phone’s car takes its name from the app.');
  const label = nameIn(nameValue);
  const model = / (\S+)$/.exec(c.name)?.[1] ?? 'Myvi';
  c.label = label;
  c.name = `${label}’s ${model}`;
  if (!c.car) { c.appName = c.name; return say(`${c.key} is now ${label}`); }
  // The rules let only the organizer rename a car, so after joining the app keeps the old car name; the playground shows the new first name.
  try {
    await updateDoc(doc(c.car.db, `trips/${S.tripId}/cars/${c.carId}`), { name: c.name });
    c.appName = c.name;
    say(`${c.key} is now ${label}; the app shows ${c.name}`);
  } catch {
    say(`${c.key} is now ${label} here; the app keeps ${c.appName} (only the organizer can rename a car)`);
  }
}

async function command(m) {
  if (!m || typeof m !== 'object') throw new UserError('That command was not understood.');
  const c = cars[m.car];
  const need = () => { if (!Object.hasOwn(cars, m.car)) throw new UserError(`${String(m.car).slice(0, 20)} isn't a car on the playground.`); };
  switch (m.cmd) {
    case 'prepare': return prepare(m);
    case 'useTrip': {
      if (S.phase !== 'waiting') throw new UserError('Prepare the phones first.');
      let trip = null;
      if (typeof m.code === 'string' && m.code.trim()) {
        const code = m.code.replace(/\s+/g, '').toUpperCase();
        if (!/^[A-Z0-9]{4,8}$/.test(code)) throw new UserError('A trip code is 4 to 8 letters and numbers.');
        trip = (await activeTrips()).find((t) => t.code === code);
        if (!trip) throw new UserError(`There is no active trip with the code ${code}.`);
      } else {
        trip = (await scanTrips()).find((t) => t.tripId === m.tripId)?.trip;
        if (!trip) throw new UserError('That trip is not on the list any more.');
      }
      failedTrips.delete(trip.id);
      return attachTrip(trip);
    }
    case 'place': { // the old "km along the route" placement, as a track
      need();
      const km = numberIn(m.km, 0, 1000, 'Km');
      const side = m.offRoute && c.kind === 'generated' ? numberIn(m.sideMeters ?? c.sideMeters, 200, 20000, 'The side road distance') : null;
      if (!S.route || S.ended) return;
      const merge = Math.min(routeLen(), km * 1000);
      if (side !== null) {
        c.sideMeters = side;
        const coords = offRouteCoords(S.route, Math.max(merge, 1600), side);
        placeCar(c, coords[0], coords);
      } else {
        changePieces(c, { base: { kind: 'main', offset: merge }, startPin: null, deviation: null, ending: null, parked: null }, { keep: false });
        say(`${c.label} placed at ${(merge / 1000).toFixed(1)} km`);
        afterMove(c);
      }
      return;
    }
    case 'placeAt': {
      need(); needRoute();
      return placeCar(c, coordIn(m.start, 'The start'), optionalCoords(m.road, 'The road from the start'));
    }
    case 'ending': {
      need(); needPlaced(c);
      const end = coordIn(m.end, 'The end');
      const road = optionalCoords(m.road, 'The road to the end');
      const leaveKm = m.leaveKm === undefined || m.leaveKm === null ? null : numberIn(m.leaveKm, 0, 1000, 'The leave point');
      const floor = leaveFloor(c);
      if (floor === Infinity) throw new UserError(`${c.label} is already on its way to its end. Clear that ending first.`);
      if (leaveKm !== null && leaveKm * 1000 < floor - 1) throw new UserError(`${c.label} has already passed that point. Pick a spot ahead of it.`);
      let plan = planEnding(S.route, { end, road, leaveKm: road || leaveKm !== null ? leaveKm : floor / 1000 });
      if (plan.kind === 'road' && plan.leaveOffset < floor - 1) {
        if (floor - plan.leaveOffset > LEAVE_SLACK + 100) throw new UserError(`That road leaves the route behind ${c.label}. Draw it from where the car is.`);
        plan = planEnding(S.route, { end, road, leaveKm: floor / 1000 });
      }
      if (plan.kind === 'onRoute' && plan.parkOffset < floor) throw new UserError('That end is on the route behind the car. Pick a place ahead of it.');
      changePieces(c, { ending: plan });
      say(plan.kind === 'road' ? `${c.label} leaves the route at ${(plan.leaveOffset / 1000).toFixed(1)} km for its own end` : `${c.label} will park at ${(plan.parkOffset / 1000).toFixed(1)} km`);
      return c.kind === 'phone' ? feedPhone(c) : undefined;
    }
    case 'clearEnding': {
      need();
      if (!c.ending || !c.track) return;
      const wasOn = c.ending.kind === 'road' ? c.ending.leaveOffset : null;
      changePieces(c, { ending: null }, { fallbackOffset: wasOn });
      say(`${c.label} has no ending of its own now`);
      if (c.kind === 'phone') feedPhone(c);
      return;
    }
    case 'deviate': {
      need(); needPlaced(c);
      const loc = refreshLoc(c);
      if (loc.phase === 'joining') throw new UserError(`${c.label} is still joining the route. Try once it has merged.`);
      if (['out', 'waiting', 'back'].includes(loc.phase)) throw new UserError(`${c.label} is already off the route. Cancel that deviation first.`);
      if (!loc.onMain) throw new UserError(`${c.label} has already left the route for its end.`);
      const pin = coordIn(m.pin, 'The pin');
      const out = optionalCoords(m.out, 'The road to the pin');
      const back = optionalCoords(m.back, 'The road back');
      const waitSeconds = m.waitSeconds === undefined || m.waitSeconds === null ? 30 : numberIn(m.waitSeconds, 0, 600, 'The wait');
      const leaveKm = m.leaveKm === undefined || m.leaveKm === null ? (loc.mainOffset + Math.max(100, (c.speed / 3.6) * 5)) / 1000 : numberIn(m.leaveKm, 0, 1000, 'The leave point');
      if (leaveKm * 1000 < loc.mainOffset - 1) throw new UserError(`${c.label} has already passed that point. Pick a spot ahead of it.`);
      const dev = planDeviation(S.route, { leaveKm, pin, out, back });
      changePieces(c, { deviation: { ...dev, waitSeconds } });
      say(`${c.label} will leave the route at ${(dev.leaveOffset / 1000).toFixed(1)} km, wait ${waitSeconds} s at the pin and rejoin at ${(dev.mergeMain / 1000).toFixed(1)} km`);
      return c.kind === 'phone' ? feedPhone(c) : undefined;
    }
    case 'cancelDeviation': {
      need();
      if (!c.deviation || !c.track) return;
      const loc = refreshLoc(c);
      if (['out', 'waiting', 'back'].includes(loc.phase)) { // already off the route: skip the wait and go on back
        const dev = { ...c.deviation, waitSeconds: 0 };
        changePieces(c, { deviation: dev });
        if (c.st.waiting) c.st = { ...c.st, waiting: null, served: new Set([...c.st.served, c.st.waiting.id]) };
        say(`${c.label} skips the rest of its wait and drives back`);
      } else {
        changePieces(c, { deviation: null });
        say(`${c.label} has no deviation now`);
      }
      return c.kind === 'phone' ? feedPhone(c) : undefined;
    }
    case 'addCar': return addCar(m);
    case 'removeCar': need(); return removeCar(c);
    case 'rename': need(); return renameCar(c, m.name);
    case 'vote': {
      need(); needJoined(c, 'answer');
      if (m.answer !== 'yes' && m.answer !== 'notNow') throw new UserError('An answer is yes or notNow.');
      openStopFor(c, m.event);
      const place = m.place ? placeOnRoute(S.route, m.place) : null;
      await c.car.vote(m.event, m.answer === 'yes', suggestionOf(place)).catch((e) => { throw plainWrite(e, 'The answer'); });
      c.voted.add(m.event);
      say(`${c.label} answers ${m.answer}${place ? ` with ${place.name}` : ''}`);
      return;
    }
    case 'voteAll': {
      needRoute();
      let any = false;
      for (const g of generatedCars()) {
        if (!g.car?.publisher || g.offline) continue;
        const e = g.car.events.find((x) => x.id === m.event);
        if (!e || e.category !== 'stopRequest' || !openStopSnapshot(e)) continue;
        any = true;
        const answered = g.voted.has(m.event) || (rest.votes.get(m.event) ?? []).some((v) => v.id === g.carId);
        if (e.carId === g.carId || answered) continue;
        g.voted.add(m.event);
        await g.car.vote(m.event, true).catch((err) => { g.voted.delete(m.event); say(`${g.label}'s answer failed: ${err.message}`); });
        say(`${g.label} answers yes`);
      }
      if (!any && !allCars().some((x) => x.car?.events.some((e) => e.id === m.event))) throw new UserError('That stop request is not on the trip.');
      return;
    }
    case 'askStop': {
      need(); needJoined(c, 'ask for a stop');
      const kind = eventKindIn(m.type, STOP_TYPES, 'The stop');
      const place = m.place ? placeOnRoute(S.route, m.place) : null;
      const { id } = await c.car.reportEvent(kind.type, kind.category, kind.severity, kind.expirySeconds).catch((e) => { throw plainWrite(e, 'The request'); });
      if (place) await c.car.vote(id, true, suggestionOf(place)).catch((e) => { throw plainWrite(e, 'The place'); }); // the asker proposes its place through its own vote, as the app does
      c.voted.add(id);
      say(`${c.label} asks for a stop (${kind.type})${place ? ` at ${place.name}` : ''}`);
      return;
    }
    case 'report': {
      need(); needJoined(c, 'report a hazard');
      const kind = eventKindIn(m.type, REPORT_TYPES, 'The report');
      await c.car.reportEvent(kind.type, kind.category, kind.severity, kind.expirySeconds).catch((e) => { throw plainWrite(e, 'The report'); });
      say(`${c.label} reports ${kind.type}`);
      return;
    }
    case 'speed': need(); c.speed = numberIn(m.kmh, 0, 200, 'Speed'); if (c.kind === 'phone') feedPhone(c); say(`${c.label} speed ${c.speed} km/h`); return;
    case 'play': need(); c.playing = Boolean(m.playing); if (c.kind === 'phone') feedPhone(c); else publishNow(c); say(`${c.label} ${c.playing ? 'plays' : 'pauses'}`); return;
    case 'playAll':
      for (const x of allCars()) { x.playing = Boolean(m.playing); if (x.kind === 'phone') feedPhone(x); }
      say(m.playing ? 'all cars play' : 'all cars pause'); return;
    case 'behaviour':
      need();
      if (c.kind !== 'generated') return;
      if (typeof m.agree === 'boolean') { c.agree = m.agree; if (!m.agree) c.suggest = false; } // a suggestion goes with the agree vote
      if (typeof m.suggest === 'boolean') { c.suggest = m.suggest; if (m.suggest) c.agree = true; }
      say(`${c.label}: agrees ${c.agree}, suggests a place ${c.suggest}`); return;
    case 'drop':
      need();
      if (c.kind !== 'generated' || !c.car) return;
      if (m.offline && !c.offline) { c.offline = true; await c.car.goOffline(); say(`${c.label} loses signal`); }
      else if (!m.offline && c.offline) { c.offline = false; await c.car.goOnline(); say(`${c.label} has signal again`); }
      return;
    default: throw new UserError(`${String(m.cmd).slice(0, 20)} is not something the playground can do.`);
  }
}

// ---------------------------------------------------------------- dry run

/** No Firebase, no simulator: the cast, and a start pin, an ending and a deviation on the stand-in route (osrm-main.json), with their lengths and merge points. */
function dryRun() {
  const route = standInRoute();
  console.log(`Playground (dry run, stand-in route: osrm-main.json, ${(route.length / 1000).toFixed(1)} km)`);
  for (const k of KEYS) console.log(`  ${k.padEnd(7)} starts ${DEFAULTS[k]} m along, ${DEFAULT_KMH} km/h, paused, ${k === 'daniel' || k === 'hafiz' ? 'generated' : 'a phone'}`);
  const coords = offRouteCoords(route, 6000, 2000);
  const plan = CarRouteLogic.makePlan(coords, route);
  console.log(`  an off-route car merging at 6.0 km: ${plan.state}, mergeOffset ${plan.mergeOffset.toFixed(0)} m, own route ${plan.route.length} chars`);
  let ok = plan.state === 'joining' && Math.abs(plan.mergeOffset - 6000) < 120;
  const check = (what, pass, detail) => { console.log(`  ${pass ? 'ok  ' : 'FAIL'} ${what}: ${detail}`); ok = ok && pass; };

  // a start pin: the car 4 road of the demos (osrm-car4.json) from its first point
  const car4 = loadRoutes().car4Coords;
  const truth = route.mergeOffset(new RouteLine(car4), CarRouteLogic.mergeTolerance);
  const sp = planStart(route, car4[0], car4);
  check('start pin on the car 4 road', sp.kind === 'road' && sp.plan.state === 'joining' && Math.abs(sp.mergeMain - truth.mainOffset) < 150 && Math.abs(sp.line.length - truth.otherOffset) < 150,
    `${sp.kind}, own leg ${(sp.line.length / 1000).toFixed(1)} km, merges at ${(sp.mergeMain / 1000).toFixed(1)} km (road meets the route at ${(truth.mainOffset / 1000).toFixed(1)} km)`);
  const startTrack = composeTrack(route, { start: sp });
  check('  its track', Math.abs(startTrack.length - (sp.line.length + route.length - sp.mergeMain)) < 1 && locate(startTrack, 10).phase === 'joining' && locate(startTrack, sp.line.length + 10).phase === 'onRoute',
    `${(startTrack.length / 1000).toFixed(1)} km, joining then onRoute`);
  const straight = planStart(route, destinationPoint(route.coordinateAtOffset(20000), -90, 2500), null);
  check('start pin without a road', straight.kind === 'road' && straight.straight && Math.abs(straight.mergeMain - 21500) < 400, `straight road, merges at ${(straight.mergeMain / 1000).toFixed(1)} km`);
  const onRoute = planStart(route, destinationPoint(route.coordinateAtOffset(8000), 90, 80), null);
  check('start pin 80 m from the route', onRoute.kind === 'main' && Math.abs(onRoute.offset - 8000) < 120, `on the route at ${(onRoute.offset / 1000).toFixed(1)} km`);

  // an ending: shares the route from 15 km to 18 km, then a side road 3 km long
  const shared = [];
  for (let m = 15000; m <= 18000; m += 40) shared.push(route.coordinateAtOffset(m));
  const side = sideRoad(route, 18000, 3000);
  const ending = planEnding(route, { end: side.at(-1), road: [...shared, ...side.slice(1)] });
  check('ending', ending.kind === 'road' && Math.abs(ending.leaveOffset - 18000) < 100 && Math.abs(ending.line.length - 3000) < 150 && ending.plan.kind === 'neverMerges',
    `leaves at ${(ending.leaveOffset / 1000).toFixed(1)} km, own road ${(ending.line.length / 1000).toFixed(1)} km, car doc: ${ending.plan.kind}`);
  const endTrack = composeTrack(route, { startOffset: 15000, ending });
  check('  its track', Math.abs(endTrack.length - (ending.leaveOffset - 15000 + ending.line.length)) < 1 && locate(endTrack, endTrack.length).phase === 'arrived', `${(endTrack.length / 1000).toFixed(1)} km, arrives at the end`);

  // a deviation: leave at 12 km, pin 1.5 km off, back merging at 14 km (before the ending above)
  const out = sideRoad(route, 12000, 1500);
  const back = [out.at(-1), ...sideRoad(route, 14000, 1500).reverse(), ...[0, 400, 800].map((m) => route.coordinateAtOffset(14000 + m))];
  const dev = planDeviation(route, { leaveKm: 12, pin: out.at(-1), out, back });
  check('deviation', Math.abs(dev.mergeMain - 14000) < 120 && dev.plan.state === 'joining', `leaves at 12.0 km, out ${(dev.out.length / 1000).toFixed(2)} km, back ${(dev.back.length / 1000).toFixed(2)} km, merges at ${(dev.mergeMain / 1000).toFixed(1)} km`);
  const devTrack = composeTrack(route, { startOffset: 10000, deviation: { ...dev, waitSeconds: 30 }, ending });
  const phases = [];
  for (let d = 0; d <= devTrack.length; d += 100) phases.push(locate(devTrack, d).phase);
  const order = phases.filter((p, i) => p !== phases[i - 1]).join(' > ');
  check('  its track with the ending after it', order === 'onRoute > out > back > onRoute > ending > arrived' || order === 'onRoute > out > back > onRoute > ending',
    `${order}; wait ${nextWait(devTrack, newCarState())?.seconds} s`);
  return ok ? 0 : 1;
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
  S.problem = null;
  command(m).catch((e) => {
    S.problem = e instanceof UserError ? `That didn't work: ${e.message}` : "That didn't work. The details are in the log.";
    S.problemAt = Date.now();
    say(`command ${m?.cmd}: ${e.message}`);
  });
});

timers.push(setInterval(() => { tick().catch((e) => say(`tick: ${e.message}`)); }, 1000));
timers.push(setInterval(() => { waitForTrip(); pollRest().catch(() => {}); }, 1500));
timers.push(setInterval(() => { for (const k of ['phone1', 'phone2']) if (cars[k].playing && !S.ended) feedPhone(cars[k]); }, 20_000)); // resync the players

let leaving = false;
async function leave(sig) {
  if (leaving) return;
  leaving = true;
  say(`${sig}: closing; the trip is left as it is (end it on phone 1)`);
  timers.forEach(clearInterval);
  for (const c of allCars()) { stopPlayer(c); }
  for (const p of phones) if (touched.has(p.udid)) simctl('location', p.udid, 'clear'); // only what this run started
  for (const c of allCars()) await c.car?.close().catch(() => {});
  emit({ type: 'phase', phase: 'ended', detail: 'playground closed' });
  process.exit(0);
}
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => leave(sig));
process.stdin.on('end', () => leave('stdin closed'));
