#!/usr/bin/env node
// Runs a worktree's Firestore rules tests on an emulator of their own, so it never touches the shared one at :8080
// (which another branch's emulator tests may be using). Project demo-ikut-rules, never ikut-b1083.
//
//   tools/rules-tests.mjs                 # the checkout this script is in
//   tools/rules-tests.mjs <worktree>      # e.g. .claude/worktrees/d25-lobby-stops
//   tools/rules-tests.mjs <worktree> --log /tmp/ikut-logs-d25/rules.log   # also keep the full output there
//
// It picks free ports for Firestore, the emulator hub and logging, writes a scratch firebase.json in $TMPDIR (UI
// off, the rules path absolute), and runs `firebase emulators:exec`, which sets FIRESTORE_EMULATOR_HOST for
// rules.test.js. A worktree without node_modules borrows the main checkout's for the run. Ends with one line:
// `RESULT: PASS|FAIL|ABORT rules tests: N passed, M failed, K skipped`. Exit 0 on PASS.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const li = args.indexOf('--log');
const logFile = li >= 0 ? args.splice(li, 2)[1] : null;
const here = path.dirname(fileURLToPath(import.meta.url));
const mainRepo = path.dirname(path.resolve(here, spawnSync('git', ['-C', here, 'rev-parse', '--git-common-dir'], { encoding: 'utf8' }).stdout.trim()));
const tree = path.resolve(args[0] ?? path.join(here, '..'));
const rules = path.join(tree, 'firebase', 'firestore.rules');
const testsDir = path.join(tree, 'firebase', 'rules-tests');
const abort = (why) => { console.log(`RESULT: ABORT ${why}`); process.exit(1); };
if (!fs.existsSync(rules) || !fs.existsSync(path.join(testsDir, 'rules.test.js'))) abort(`no firebase/firestore.rules and rules-tests in ${tree}`);

const freePort = () => new Promise((res, rej) => {
  const s = net.createServer();
  s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => res(port)); });
  s.on('error', rej);
});
const [fsPort, hubPort, logPort] = [await freePort(), await freePort(), await freePort()];

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ikut-rules-'));
fs.writeFileSync(path.join(scratch, 'firebase.json'), JSON.stringify({
  firestore: { rules },
  emulators: {
    singleProjectMode: false,
    firestore: { port: fsPort, host: '127.0.0.1' },
    hub: { port: hubPort, host: '127.0.0.1' },
    logging: { port: logPort, host: '127.0.0.1' },
    ui: { enabled: false },
  },
}));

let borrowed = null;
const modules = path.join(testsDir, 'node_modules');
if (!fs.existsSync(modules)) {
  const donor = path.join(mainRepo, 'firebase', 'rules-tests', 'node_modules');
  if (!fs.existsSync(donor)) abort(`no node_modules in ${testsDir} or the main checkout; run npm ci in firebase/rules-tests`);
  fs.symlinkSync(donor, modules);
  borrowed = modules;
}
const cleanup = () => {
  if (borrowed) try { fs.unlinkSync(borrowed); } catch {}
  try { fs.rmSync(scratch, { recursive: true, force: true }); } catch {}
};

console.error(`rules tests: ${tree} on Firestore :${fsPort} (scratch config ${scratch})`);
const child = spawn('firebase', ['emulators:exec', '--only', 'firestore', '--project', 'demo-ikut-rules', '--config', path.join(scratch, 'firebase.json'),
  `npm --prefix '${testsDir}' test`], { cwd: scratch, stdio: ['ignore', 'pipe', 'pipe'] });
let output = '';
const take = (d) => { output += d; };
child.stdout.on('data', take);
child.stderr.on('data', take);
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => child.kill(sig));
const code = await new Promise((res) => child.on('close', res));
cleanup();
if (logFile) fs.writeFileSync(logFile, output);

const n = (name) => Number(new RegExp(`^(?:#|ℹ) ${name} (\\d+)`, 'm').exec(output)?.[1] ?? NaN);
const [tests, pass, fail, skipped] = [n('tests'), n('pass'), n('fail'), n('skipped')];
if (Number.isNaN(tests)) {
  console.log(output.split('\n').slice(-25).join('\n'));
  abort('rules tests did not run (see the output above)');
}
const failures = [...output.matchAll(/^\s*(?:not ok \d+ -|✖) (.*)$/gm)].map((m) => m[1]);
for (const f of failures.slice(0, 20)) console.log(`  ✘ ${f}`);
console.log(`RESULT: ${fail === 0 && code === 0 ? 'PASS' : 'FAIL'} rules tests: ${pass} passed, ${fail} failed, ${skipped} skipped (of ${tests})`);
process.exit(fail === 0 && code === 0 ? 0 : 1);
