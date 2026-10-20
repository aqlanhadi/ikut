// Small process helpers shared by the scripts that drive simulators and Xcode.
import { spawnSync } from 'node:child_process';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: 'utf8', ...opts });
export const simctl = (...args) => run('xcrun', ['simctl', ...args]);

/** A logger that prefixes each line with the script's name and the seconds since it started. */
export function makeSay(label, startedAt = Date.now()) {
  return (...a) => console.log(`[${label} ${((Date.now() - startedAt) / 1000).toFixed(0).padStart(4)}s]`, ...a);
}
