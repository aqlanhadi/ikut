#!/usr/bin/env node
// Makes sure the Firebase emulators (Auth :9099, Firestore :8080, Functions :5001) are up, and returns once they
// answer. Leaves running ones alone; starts them in the background when none are up, logging to
// $TMPDIR/ikut-emulators.log. Exit 0 when all three answer, 1 when they don't within --wait seconds (default 120).
//
//   tools/emulators.mjs

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const waitS = Number(process.argv[process.argv.indexOf('--wait') + 1]) || 120;
// The main checkout, also when this runs from a worktree or another directory.
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(path.resolve(here, spawnSync('git', ['-C', here, 'rev-parse', '--git-common-dir'], { encoding: 'utf8' }).stdout.trim()));
const ports = { auth: 9099, firestore: 8080, functions: 5001 };
const up = (port) => spawnSync('curl', ['-s', '-o', '/dev/null', '-m', '2', '-w', '%{http_code}', `http://127.0.0.1:${port}`], { encoding: 'utf8' }).stdout !== '000';
const state = () => Object.fromEntries(Object.entries(ports).map(([n, p]) => [n, up(p)]));
const line = (s) => Object.entries(s).map(([n, ok]) => `${n} ${ok ? 'up' : 'down'}`).join(', ');

let s = state();
if (Object.values(s).every(Boolean)) { console.log(`emulators up (${line(s)})`); process.exit(0); }
if (Object.values(s).some(Boolean)) {
  // Part of a set is still starting or shutting down; a second set would fight it for the ports.
  console.log(`emulators partly up (${line(s)}); waiting for them, not starting another set`);
} else {
  const log = path.join(os.tmpdir(), 'ikut-emulators.log');
  const out = fs.openSync(log, 'a');
  const child = spawn('firebase', ['emulators:start', '--project', 'ikut-b1083'], { cwd: path.join(repo, 'firebase'), detached: true, stdio: ['ignore', out, out] });
  child.unref();
  console.log(`starting the emulators (pid ${child.pid}), log ${log}`);
}
const deadline = Date.now() + waitS * 1000;
while (Date.now() < deadline) {
  await new Promise((r) => setTimeout(r, 2000));
  s = state();
  if (Object.values(s).every(Boolean)) { console.log(`emulators up (${line(s)})`); process.exit(0); }
}
console.log(`emulators not up after ${waitS} s (${line(s)}); see $TMPDIR/ikut-emulators.log`);
process.exit(1);
