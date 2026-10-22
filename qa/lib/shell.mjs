// Small process helpers shared by the scripts that drive simulators and Xcode.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: 'utf8', ...opts });
export const simctl = (...args) => run('xcrun', ['simctl', ...args]);

/** A logger that prefixes each line with the script's name and the seconds since it started. */
export function makeSay(label, startedAt = Date.now()) {
  return (...a) => console.log(`[${label} ${((Date.now() - startedAt) / 1000).toFixed(0).padStart(4)}s]`, ...a);
}

/**
 * Makes a runner's output end in one `RESULT: PASS|FAIL|ABORT …` line however it stops: its own verdict (`result`),
 * an early exit, a crash, a signal, or running past `deadlineS`. Whoever waits on the log or the exit (an agent, the
 * dashboard) then always sees an end. At the deadline the script gets SIGTERM, so its own cleanup runs; `signals`
 * adds a plain handler for scripts that have none. Children passed to `track` are killed when the script exits.
 */
export function endsWithResult({ deadlineS = 0, signals = false } = {}) {
  let done = false;
  let why = null;
  const children = new Set();
  process.on('exit', (code) => {
    for (const c of children) if (c.exitCode === null && c.signalCode === null) c.kill('SIGKILL');
    // Synchronous, so the line is written even when the process is on its way out.
    if (!done) fs.writeSync(1, `\nRESULT: ABORT (${why ?? `exited with code ${code} before its checks finished`})\n`);
  });
  if (signals) {
    for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143]]) process.on(sig, () => { why ??= `stopped by ${sig}`; process.exit(code); });
  }
  if (deadlineS > 0) {
    setTimeout(() => {
      why = `still running after ${deadlineS} s, stopped`;
      console.log(`\n${why}`);
      process.kill(process.pid, 'SIGTERM');
      setTimeout(() => process.exit(124), 120_000).unref(); // the script's cleanup hung too
    }, deadlineS * 1000).unref();
  }
  return {
    track: (child) => { children.add(child); return child; },
    result: (ok) => { done = true; console.log(ok ? '\nRESULT: PASS' : '\nRESULT: FAIL'); },
  };
}

const simlock = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'simlock.sh');

/**
 * Runs this script again under qa/simlock.sh, holding the simulators it drives, so two runs never drive one
 * simulator's screen at once (CLAUDE.md, "Simulators"). A second run waits, saying who has the simulator, for up to
 * `waitS`, then stops with `RESULT: ABORT`. Returns at once when the script already holds them (it is the run under
 * the lock, or was started under simlock.sh); otherwise it never returns, and exits with the locked run's code.
 */
export async function holdSimulators(udids, waitS = 1800) {
  const held = (process.env.IKUT_SIMLOCK_HELD ?? '').split(',');
  if (udids.every((u) => held.includes(u))) return;
  // Its own process group, so a signal reaches the lock and the run under it, not just the shell in between.
  const child = spawn(simlock, ['-t', String(waitS), udids.join(','), '--', process.execPath, ...process.argv.slice(1)], { stdio: 'inherit', detached: true });
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { try { process.kill(-child.pid, sig); } catch {} });
  const [code, sig] = await new Promise((r) => child.on('exit', (c, s) => r([c, s])));
  process.exit(code ?? 128 + os.constants.signals[sig]);
}
