#!/usr/bin/env node
// Runs a command with a branch's Firestore rules loaded into the shared emulator, then puts main's rules back,
// also when the command fails or is stopped with Ctrl-C. For the app's emulator tests on a branch that changes
// firestore.rules (TEST_RUNNER_IKUT_EMULATOR_TESTS=1), instead of loading and restoring rules by hand.
//
//   tools/with-rules.mjs <worktree> -- <command…>
//   tools/with-rules.mjs .claude/worktrees/d25-lobby-stops -- xcodebuild test … -only-testing:ikutTests/<Suite>
//   tools/with-rules.mjs --port 18080 --project ikut-b1083 <worktree> -- curl …      # another emulator
//
// - `--port` (default 8080) and `--project` (default ikut-b1083) say which Firestore emulator and project to load
//   into. "Main's rules" are `git show main:firebase/firestore.rules` of the main checkout.
// - One run at a time per emulator, through lockf like qa/simlock.sh: a second run says who has it and waits up to
//   `-t` seconds (default 1800), then ends with `RESULT: ABORT` and exit code 75. The lock belongs to the process,
//   so a crashed run never leaves it held (the rules it loaded stay, though: the next run starts by loading its own).
// - Rule compile errors are printed (and the command isn't run); warnings such as "Unused function" are not.
// - Exit code is the command's. Prints nothing else unless something went wrong.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);
const take = (flag, dflt) => { const i = argv.indexOf(flag); return i >= 0 ? argv.splice(i, 2)[1] : dflt; };
const inner = argv[0] === '--inner' ? argv.shift() : null;
const port = take('--port', '8080');
const project = take('--project', 'ikut-b1083');
const waitS = take('-t', '1800');
const dash = argv.indexOf('--');
if (dash < 1 || dash === argv.length - 1) {
  console.error('usage: tools/with-rules.mjs [--port 8080] [--project ikut-b1083] [-t seconds] <worktree> -- <command…>');
  process.exit(64);
}
const tree = path.resolve(argv[0]);
const command = argv.slice(dash + 1);
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(path.resolve(here, spawnSync('git', ['-C', here, 'rev-parse', '--git-common-dir'], { encoding: 'utf8' }).stdout.trim()));
const rulesFile = path.join(tree, 'firebase', 'firestore.rules');
if (!fs.existsSync(rulesFile)) { console.error(`with-rules: no firebase/firestore.rules in ${tree}`); process.exit(64); }

if (!inner) {
  // Take the lock, then run this same script inside it.
  const lock = `/tmp/ikut-rules-${port}.lock`;
  const holder = `/tmp/ikut-rules-${port}.holder`;
  if (spawnSync('lockf', ['-k', '-t', '0', lock, 'true']).status !== 0) {
    console.error(`[with-rules] the emulator on :${port} is in use by: ${fs.existsSync(holder) ? fs.readFileSync(holder, 'utf8').trim() : 'another run'}; waiting up to ${waitS} s`);
  }
  const me = `with-rules ${path.basename(tree)} -- ${command.join(' ')}`;
  const r = spawnSync('lockf', ['-k', '-t', waitS, lock, '/bin/sh', '-c',
    'printf "%s (pid %s, since %s)\\n" "$1" "$$" "$(date +%H:%M:%S)" > "$2"; shift 2; exec "$@"', 'with-rules', me, holder,
    process.execPath, fileURLToPath(import.meta.url), '--inner', '--port', port, '--project', project, tree, '--', ...command], { stdio: 'inherit' });
  if (r.status === 75) {
    console.error(`[with-rules] the emulator on :${port} still in use after ${waitS} s by: ${fs.existsSync(holder) ? fs.readFileSync(holder, 'utf8').trim() : 'another run'}`);
    console.log(`\nRESULT: ABORT (emulator :${port} busy for ${waitS} s)`);
  }
  process.exit(r.status ?? 1);
}

// ---- inside the lock
const url = `http://127.0.0.1:${port}/emulator/v1/projects/${project}:securityRules`;
async function load(content, what) {
  let res;
  try {
    res = await fetch(url, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ rules: { files: [{ name: 'firestore.rules', content }] } }) });
  } catch (e) {
    console.error(`with-rules: can't reach the emulator on :${port} (${e.cause?.code ?? e.message}); start it with tools/emulators.mjs`);
    return false;
  }
  const text = await res.text();
  let body = {};
  try { body = JSON.parse(text); } catch {}
  const errors = (body.issues ?? []).filter((i) => i.severity !== 'WARNING');
  if (!res.ok || errors.length) {
    console.error(`with-rules: the emulator won't take ${what}:`);
    if (body.error?.message) console.error(`  ${body.error.message.replaceAll('\n', '\n  ')}`);
    else if (!errors.length) console.error(`  HTTP ${res.status} ${text.slice(0, 300)}`);
    for (const i of errors) console.error(`  ${i.sourcePosition?.fileName ?? 'rules'}:${i.sourcePosition?.line ?? '?'}:${i.sourcePosition?.column ?? '?'} ${i.severity} ${i.description}`);
    return false;
  }
  return true;
}
const mainRules = spawnSync('git', ['-C', repo, 'show', 'main:firebase/firestore.rules'], { encoding: 'utf8', maxBuffer: 1 << 24 });
if (mainRules.status !== 0) { console.error(`with-rules: can't read main's rules: ${mainRules.stderr.trim()}`); process.exit(1); }

let child = null;
let stopping = null;
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => { stopping = sig; child?.kill(sig); });

let code = 1;
try {
  if (await load(fs.readFileSync(rulesFile, 'utf8'), `${tree}'s rules`)) {
    if (!stopping) {
      child = spawn(command[0], command.slice(1), { stdio: 'inherit' });
      code = await new Promise((res) => { child.on('error', (e) => { console.error(`with-rules: ${e.message}`); res(127); }); child.on('close', (c, s) => res(c ?? (s ? 128 + 15 : 1))); });
    }
  }
} finally {
  if (!(await load(mainRules.stdout, "main's rules back"))) console.error(`with-rules: MAIN'S RULES ARE NOT BACK on :${port}; load them by hand from main's firebase/firestore.rules`);
}
process.exit(code);
