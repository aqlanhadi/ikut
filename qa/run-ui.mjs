#!/usr/bin/env node
// Runs the whole scenario with one real app in the loop:
//
//   node run-ui.mjs                      # 2x (the default, every check runs), simulator C0A40D2A (iPhone 17 #1)
//   node run-ui.mjs --speed 1            # real time, before a field test
//   node run-ui.mjs --skip-build         # reuse a build in --derived-data
//   node run-ui.mjs --deadline 3600      # give up (RESULT: ABORT) after 3600 s; default 2100 s + the scenario
//   node run-ui.mjs --scenario parked    # the phone is parked on the route far ahead of the convoy (D26): the far
//                                        # stop request, the heads-up pill, then drives on (qa/gpx/car5-parked.gpx)
//
// 1. boots the simulator, grants location (xcrun simctl privacy), parks it at the start of qa/gpx/car5-app.gpx
// 2. starts convoy-sim.mjs --wait-app (4 simulated cars) and reads the trip code from it
// 3. starts xcodebuild test for ConvoyScenarioUITests with TEST_RUNNER_IKUT_JOIN_CODE
// 4. when the sim prints @@GO (the phone has joined and is tracking) it feeds car5-app.gpx to the simulator with
//    xcrun simctl location start, at the GPX's speed times --speed
// 5. waits for both to finish and prints their verdicts. Exit code 0 only if the sim checks and the UI test passed.
//
// It holds the simulator while it runs (qa/simlock.sh): a second run waits for it. The log always ends in one
// `RESULT: PASS|FAIL|ABORT` line, also when it stops early or runs past --deadline.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readGpx } from './lib/gpx.mjs';
import { endsWithResult, holdSimulators, makeSay, simctl } from './lib/shell.mjs';
import { feedLocation, prepareSimulator } from './lib/demo-common.mjs';
import { haversine } from './lib/route.mjs';
import { appKey } from './lib/scenario.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(here);

const o = {
  udid: 'C0A40D2A-0607-4B95-A1BE-F8C9190D81C1', // iPhone 17 #1 (shared, see CLAUDE.md)
  speed: 2, // the fastest at which every check runs (the signal drop needs <= 2x, lib/scenario.mjs)
  derivedData: '/tmp/ikut-dd-q1',
  skipBuild: false,
  name: 'Faiz',
  screens: path.join(here, 'screens'),
  logs: path.join(os.tmpdir(), 'ikut-qa'),
  deadline: null,
  scenario: 'drive',
};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  const next = () => process.argv[++i];
  if (a === '--speed') o.speed = Number(next());
  else if (a === '--udid') o.udid = next();
  else if (a === '--derived-data') o.derivedData = next();
  else if (a === '--skip-build') o.skipBuild = true;
  else if (a === '--name') o.name = next();
  else if (a === '--screens') o.screens = next();
  else if (a === '--logs') o.logs = next();
  else if (a === '--deadline') o.deadline = Number(next());
  else if (a === '--scenario') o.scenario = next();
  else { console.error(`unknown option ${a}`); process.exit(64); }
}
if (!['drive', 'parked'].includes(o.scenario)) { console.error(`unknown scenario ${o.scenario} (drive or parked)`); process.exit(64); }
o.only = o.scenario === 'parked'
  ? 'ikutUITests/ConvoyScenarioUITests/testParkedAheadOfTheConvoy'
  : 'ikutUITests/ConvoyScenarioUITests/testFifthCarInSimulatedConvoy';
await holdSimulators([o.udid]);
// The sim waits up to 1500 s for the phone to join (the build included), then plays its 900 s scenario.
const end = endsWithResult({ deadlineS: o.deadline ?? 1500 + 900 / o.speed + 600, signals: true });
process.on('exit', () => simctl('location', o.udid, 'clear'));
fs.mkdirSync(o.logs, { recursive: true });
fs.mkdirSync(o.screens, { recursive: true });

const t0 = Date.now();
const say = makeSay('run-ui', t0);

// ---- simulator
const track = readGpx(path.join(here, 'gpx', `${appKey(o.scenario)}.gpx`));
// The app stays installed (the UI test starts from its own state); only the permission and the location are set.
prepareSimulator(o.udid, say, { start: track[0], uninstall: false, privacy: 'location', bootText: 'booting simulator' });

// ---- sim
const simLog = fs.createWriteStream(path.join(o.logs, 'sim.log'));
// Both UI tests say OK to the stop request: from the card (drive) or the pill (parked).
const simArgs = [path.join(here, 'convoy-sim.mjs'), '--speed', String(o.speed), '--wait-app', '--wait-timeout', '1500', '--expect-app-ok', '--scenario', o.scenario];
const sim = end.track(spawn('node', simArgs, { cwd: here }));
let simCode = null;
let simGo = false;
let simDone = null;
let simBuf = '';
const goWaiters = [];
sim.stdout.on('data', (d) => {
  simLog.write(d);
  simBuf += d.toString();
  let nl;
  while ((nl = simBuf.indexOf('\n')) >= 0) {
    const l = simBuf.slice(0, nl);
    simBuf = simBuf.slice(nl + 1);
    process.stdout.write(`  sim| ${l}\n`);
    const m = /^@@CODE (\S+)/.exec(l);
    if (m) simCode = m[1];
    if (l.startsWith('@@GO')) { simGo = true; goWaiters.forEach((f) => f()); }
    if (l.startsWith('@@DONE')) simDone = l;
  }
});
sim.stderr.on('data', (d) => { simLog.write(d); process.stderr.write(`  sim! ${d}`); });
const simExit = new Promise((r) => sim.on('exit', (c) => r(c)));

while (!simCode) {
  if (sim.exitCode !== null) { console.error('sim exited during setup'); process.exit(1); }
  await new Promise((r) => setTimeout(r, 200));
}
say(`trip code ${simCode}`);

// ---- xcodebuild
const ios = path.join(repo, 'ios');
const args = ['test', '-project', path.join(ios, 'ikut.xcodeproj'), '-scheme', 'ikut', '-destination', `platform=iOS Simulator,id=${o.udid}`,
  '-derivedDataPath', o.derivedData, '-clonedSourcePackagesDirPath', path.join(o.derivedData, 'SourcePackages'),
  `-only-testing:${o.only}`, '-collect-test-diagnostics', 'never'];
if (o.skipBuild) args[0] = 'test-without-building';
const xcLogPath = path.join(o.logs, 'xcodebuild.log');
const xcLog = fs.createWriteStream(xcLogPath);
const xc = end.track(spawn('xcodebuild', args, {
  env: { ...process.env, TEST_RUNNER_IKUT_JOIN_CODE: simCode, TEST_RUNNER_IKUT_JOIN_NAME: o.name, TEST_RUNNER_IKUT_QA_SPEED: String(o.speed), TEST_RUNNER_IKUT_QA_SCREENS: o.screens, TEST_RUNNER_IKUT_QA_SCENARIO: o.scenario },
}));
let xcResult = null;
let xcBuf = '';
const onXc = (d) => {
  xcLog.write(d);
  xcBuf += d.toString();
  let nl;
  while ((nl = xcBuf.indexOf('\n')) >= 0) {
    const l = xcBuf.slice(0, nl);
    xcBuf = xcBuf.slice(nl + 1);
    if (/QA STEP|Test Case .*(passed|failed)|error:|\*\* TEST|Test run with|XCTAssert|Timed out/.test(l)) process.stdout.write(`  xc | ${l}\n`);
    if (/\*\* TEST (SUCCEEDED|FAILED) \*\*|Test run with/.test(l)) xcResult ??= l;
  }
};
xc.stdout.on('data', onXc);
xc.stderr.on('data', onXc);
const xcExit = new Promise((r) => xc.on('exit', (c) => r(c)));

// ---- feed the GPX to the simulator from go
// `simctl location start` plays waypoints at a constant speed but, on its own, drifted behind the scenario clock and
// once stalled for minutes (see qa/README.md, "Known quirks"). So the playback is restarted every RESYNC seconds from
// the point the GPX says the car should be at, which keeps the phone within a few seconds of its track.
await new Promise((r) => (simGo ? r() : goWaiters.push(r)));
const goAt = Date.now();
// Played at the track's speed while it moves; a parked stretch (the parked scenario) is held with location set.
let meters = 0;
let moving = 0;
const parkedAt = (i) => i + 1 < track.length && haversine(track[i], track[i + 1]) < 0.01;
for (let i = 1; i < track.length; i++) {
  const d = haversine(track[i - 1], track[i]);
  meters += d;
  if (d >= 0.01) moving += track[i].t - track[i - 1].t;
}
const mps = (meters / moving) * o.speed;
const RESYNC = 20;
let feeder = null;
const feed = () => {
  const T = ((Date.now() - goAt) / 1000) * o.speed;
  const from = Math.max(0, track.findIndex((p) => p.t >= T));
  if (parkedAt(from)) { simctl('location', o.udid, 'set', `${track[from].latitude},${track[from].longitude}`); return; }
  const pts = track.filter((p, i) => i >= from && (i % 4 === 0 || i === track.length - 1));
  if (pts.length < 2) return;
  feedLocation({ udid: o.udid, points: pts, mps });
};
say(`simctl location start at ${mps.toFixed(1)} m/s, resynced every ${RESYNC} s`);
feed();
feeder = setInterval(feed, RESYNC * 1000);

// ---- wait
const killAfter = async (ms, child, label) => {
  await new Promise((r) => setTimeout(r, ms));
  if (child.exitCode === null) { say(`${label} still running ${ms / 1000} s after its result, killing it`); child.kill('SIGKILL'); }
};
let xcCode;
{
  const first = await Promise.race([xcExit.then((c) => ({ c })), (async () => { while (!xcResult) await new Promise((r) => setTimeout(r, 1000)); return { result: true }; })()]);
  if (first.result) { killAfter(60_000, xc, 'xcodebuild'); }
  xcCode = await xcExit;
}
say(`xcodebuild exited ${xcCode} (${xcResult ?? 'no result line'}), log ${xcLogPath}`);
clearInterval(feeder);
simctl('location', o.udid, 'clear');
if (xcCode !== 0 && sim.exitCode === null) { say('UI test failed; stopping the simulator early'); sim.kill('SIGTERM'); }

// The sim runs on until the end of its scenario; give it its remaining time.
const simCode2 = await Promise.race([simExit, new Promise((r) => setTimeout(() => r('timeout'), (900 / o.speed + 120) * 1000))]);
if (simCode2 === 'timeout') sim.kill('SIGKILL');
say(`sim exited ${simCode2}: ${simDone ?? 'no @@DONE line'}`);
const ok = xcCode === 0 && simCode2 === 0;
end.result(ok);
process.exit(ok ? 0 : 1);
