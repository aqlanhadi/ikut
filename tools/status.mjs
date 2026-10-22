#!/usr/bin/env node
// What's going on right now, in one look: who holds each simulator, which builds, tests and qa runs are going (and
// for which task), whether the emulators answer, the open worktrees, and the board's tasks in progress.
// Read-only; use it instead of ps/pgrep before starting a run or to see whether one is still going.
//
//   tools/status.mjs

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const sh = (cmd, args) => spawnSync(cmd, args, { encoding: 'utf8' });
const SIMS = { 'C0A40D2A-0607-4B95-A1BE-F8C9190D81C1': 'iPhone 17 #1', 'FD0ACD10-F3C4-4797-8DB8-A6F554585CC1': 'iPhone 17 #2' };
// The main checkout, also when this runs from a worktree or another directory.
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(path.resolve(here, spawnSync('git', ['-C', here, 'rev-parse', '--git-common-dir'], { encoding: 'utf8' }).stdout.trim()));

// ---- simulators
console.log('Simulators');
const devices = sh('xcrun', ['simctl', 'list', 'devices']).stdout;
for (const [udid, name] of Object.entries(SIMS)) {
  const state = /\((Booted|Shutdown|Shutting Down|Booting)\)/.exec(devices.split('\n').find((l) => l.includes(udid)) ?? '')?.[1] ?? 'missing';
  const lock = `/tmp/ikut-sim-${udid}.lock`;
  const busy = fs.existsSync(lock) && sh('lockf', ['-k', '-t', '0', lock, 'true']).status === 75;
  const holder = busy ? (fs.readFileSync(`/tmp/ikut-sim-${udid}.holder`, 'utf8').trim() || 'another run') : null;
  console.log(`  ${name.padEnd(13)} ${state.padEnd(9)} ${busy ? `held by: ${holder}` : 'free'}`);
}

// ---- running work
const ps = sh('ps', ['-axo', 'pid=,etime=,command=']).stdout.split('\n');
const flag = (cmd, f) => new RegExp(`${f}[ =]'?([^ ']+)`).exec(cmd)?.[1];
const rows = [];
for (const line of ps) {
  const m = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(line);
  if (!m || Number(m[1]) === process.pid) continue;
  const [, pid, etime, cmd] = m;
  let what = null;
  if (/^\S*xcodebuild\s/.test(cmd)) {
    const action = /\s(test-without-building|build-for-testing|test|build|clean)(\s|$)/.exec(cmd)?.[1] ?? 'xcodebuild';
    const dd = flag(cmd, '-derivedDataPath');
    const only = [...cmd.matchAll(/-only-testing:(\S+)/g)].map((x) => x[1]).join(',');
    const dest = /id=([0-9A-F-]{36})/.exec(cmd)?.[1];
    what = `xcodebuild ${action}${only ? ` ${only}` : ''}${dest ? ` on ${SIMS[dest] ?? dest.slice(0, 8)}` : ''}${dd ? ` (${dd})` : ''}`;
  } else if (/^\S*node\s.*\b(convoy-sim|run-ui|run-convoy2|demo[\w-]*|drive-trip|battery-watch|prod-smoke)\.mjs/.test(cmd)) {
    what = `qa ${cmd.replace(/^\S*node\s+\S*\//, '')}`;
  } else if (/simctl location \S+ start/.test(cmd)) {
    const udid = /location (\S+) start/.exec(cmd)[1];
    what = `location playback on ${SIMS[udid] ?? udid.slice(0, 8)}`;
  } else if (/firebase.*emulators:start|cloud-firestore-emulator/.test(cmd) && /node|java/.test(cmd) && !/java/.test(cmd)) {
    what = 'firebase emulators';
  }
  if (what) rows.push(`  ${etime.padStart(11)}  ${what}  [pid ${pid}]`);
}
console.log('\nRunning (elapsed, what)');
console.log(rows.length ? rows.join('\n') : '  nothing');

// ---- emulators
const up = (port) => sh('curl', ['-s', '-o', '/dev/null', '-m', '2', '-w', '%{http_code}', `http://127.0.0.1:${port}`]).stdout !== '000';
const ports = { firestore: 8080, auth: 9099, functions: 5001 };
const state = Object.entries(ports).map(([n, p]) => `${n} ${up(p) ? 'up' : 'down'}`);
console.log(`\nEmulators: ${state.join(', ')}${state.every((s) => s.endsWith('up')) ? '' : '  (tools/emulators.mjs starts them)'}`);

// ---- worktrees and build folders
console.log('\nWorktrees');
const wt = sh('git', ['-C', repo, 'worktree', 'list']).stdout.trim().split('\n');
for (const w of wt) console.log(`  ${w.replace(repo, '.')}`);
const dirs = (re) => fs.readdirSync('/tmp').filter((d) => re.test(d) && fs.statSync(`/tmp/${d}`).isDirectory());
const dd = dirs(/^ikut-dd-/);
const logs = dirs(/^ikut-logs-/);
if (dd.length) console.log(`\nBuild folders: ${dd.map((d) => `/tmp/${d}`).join(', ')}`);
if (logs.length) console.log(`Log folders: ${logs.map((d) => `/tmp/${d}`).join(', ')}`);

// ---- board
try {
  const board = JSON.parse(fs.readFileSync(path.join(repo, 'planning', 'board.json'), 'utf8'));
  const doing = (board.tasks ?? board).filter((t) => t.status === 'doing');
  console.log(`\nBoard, doing:${doing.length ? doing.map((t) => `\n  ${t.id}  ${t.title.slice(0, 90)}`).join('') : ' nothing'}`);
} catch { /* the board lives only in the main checkout */ }
const tag = sh('git', ['-C', repo, 'log', '--oneline', '--first-parent', 'regression-pass..main', '--', 'ios', 'firebase']);
console.log(tag.status === 0
  ? `Regression pass: ${tag.stdout.trim().split('\n').filter(Boolean).length} merges into ios/ or firebase/ since the last one (due at 5)`
  : 'Regression pass: none yet, one is due');
