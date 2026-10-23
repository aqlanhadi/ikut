// The Screens tab's logic: the Debug launch states (IKUT_SCREEN) read from the app code, and launching one on a simulator.
// Everything that touches a process takes `exec` (execFile-style, never a shell string) so qa/lib/screens.test.mjs can fake it.

import { execFile } from 'node:child_process';
import { readFile, stat } from 'node:fs/promises';
import { promisify } from 'node:util';

export const BUNDLE_ID = 'dev.aqlan.ikut'; // ios/project.yml
export const SIMULATORS = [ // the only two the dashboard may touch, never taken from a request
  { id: '1', name: 'iPhone 17 #1', udid: 'C0A40D2A-0607-4B95-A1BE-F8C9190D81C1' },
  { id: '2', name: 'iPhone 17 #2', udid: 'FD0ACD10-F3C4-4797-8DB8-A6F554585CC1' },
];
export const BUILD_HINT = 'cd ios && xcodebuild build -scheme ikut -destination \'platform=iOS Simulator,id=<udid>\' -derivedDataPath /tmp/ikut-dd-screens && xcrun simctl install <udid> /tmp/ikut-dd-screens/Build/Products/Debug-iphonesimulator/ikut.app';

/** The state names in `enum DemoScreens` (ios/ikut/Lobby/LobbyDemo.swift): every string in a `case "…":` line, in order, no duplicates. */
export function parseScreens(swift) {
  const from = swift.search(/enum\s+DemoScreens\b/);
  if (from < 0) return [];
  const names = [];
  for (const line of swift.slice(from).split('\n')) {
    const m = /^\s*case\s+("[^"]+"(?:\s*,\s*"[^"]+")*)\s*:/.exec(line);
    if (!m) continue;
    for (const [, n] of m[1].matchAll(/"([^"]+)"/g)) if (!names.includes(n)) names.push(n);
  }
  return names;
}

/** [{prefix, names}] grouped by the part before the first `-`, in order of first appearance. */
export function groupScreens(names) {
  const groups = [];
  for (const name of names) {
    const prefix = name.includes('-') ? name.split('-')[0] : name;
    let g = groups.find((x) => x.prefix === prefix);
    if (!g) groups.push(g = { prefix, names: [] });
    g.names.push(name);
  }
  return groups;
}

export const simById = (id) => SIMULATORS.find((s) => s.id === String(id));
export const lockPath = (udid) => `/tmp/ikut-sim-${udid}.lock`;
export const holderPath = (udid) => `/tmp/ikut-sim-${udid}.holder`;

/** Who holds the simulator through qa/simlock.sh, or null when it is free. `lockf -t 0` fails at once when someone holds it. */
export async function simHolder(udid, exec = promisify(execFile), read = (p) => readFile(p, 'utf8')) {
  try { await exec('lockf', ['-k', '-t', '0', lockPath(udid), 'true']); return null; } catch (e) {
    if (e.code === 'ENOENT') return null; // no lockf: nothing can be holding it
    try { return (await read(holderPath(udid))).trim() || 'another run'; } catch { return 'another run'; }
  }
}

/** The `xcodebuild test` (or test-without-building) aimed at this simulator, from `ps -axo pid=,etime=,command=` lines; null when none.
 *  Mirrors the parse in tools/status.mjs (an xcodebuild command, its action, `id=<udid>` in the destination). */
export function testingOn(udid, psLines) {
  for (const line of psLines) {
    const m = /^\s*\d+\s+\S+\s+(.*)$/.exec(line);
    const cmd = m?.[1] ?? '';
    if (!/^\S*xcodebuild\s/.test(cmd)) continue;
    const action = /\s(test-without-building|build-for-testing|test|build|clean)(\s|$)/.exec(cmd)?.[1];
    if ((action === 'test' || action === 'test-without-building') && cmd.includes(`id=${udid}`)) return `xcodebuild ${action}`;
  }
  return null;
}
const psLines = async (exec) => (await exec('ps', ['-axo', 'pid=,etime=,command='])).stdout.split('\n');

/** The state of a launch request as plain words. Returns {ok, message, build?, hint?}. */
export async function launchScreen({ sim, screen }, { names, exec = promisify(execFile), holder = simHolder, ps = psLines, modified = async (p) => (await stat(p)).mtime } = {}) {
  const s = simById(sim);
  if (!s) return { code: 404, ok: false, message: 'That simulator is not one of the two this page can use.' };
  if (!names.includes(screen)) return { code: 404, ok: false, message: 'The app has no screen with that name.' };
  const busy = await holder(s.udid, exec);
  if (busy) return { code: 409, ok: false, message: `${s.name} is busy with: ${busy}. Wait for it to finish, or use the other phone.` };
  const testing = testingOn(s.udid, await ps(exec).catch(() => []));
  if (testing) return { code: 409, ok: false, message: `${s.name} is running tests (${testing} …). Wait for it to finish, or use the other phone.` };
  let build = null;
  try { await boot(s, exec); } catch (e) { return { code: 500, ok: false, message: `${s.name} would not start (${String(e.stderr || e.message).trim().split('\n')[0]}).` }; }
  try {
    const { stdout } = await exec('xcrun', ['simctl', 'get_app_container', s.udid, BUNDLE_ID]);
    try { build = (await modified(stdout.trim())).toISOString(); } catch { /* the install date is a nice-to-have */ }
  } catch { return notInstalled(s); }
  try {
    await exec('xcrun', ['simctl', 'launch', '--terminate-running-process', s.udid, BUNDLE_ID], { env: { ...process.env, SIMCTL_CHILD_IKUT_SCREEN: screen } });
  } catch (e) {
    return { code: 500, ok: false, message: `${s.name} would not open the app (${String(e.stderr || e.message).trim().split('\n')[0]}).` };
  }
  return { code: 200, ok: true, message: `Opened ${screen} on ${s.name}.`, build };
}

const notInstalled = (s) => ({ code: 409, ok: false, message: `The app is not installed on ${s.name}. Build and install it, then try again.`, hint: BUILD_HINT.replaceAll('<udid>', s.udid) });

/** Boots the simulator if it is shut down (never creates, erases or shuts one down) and brings the Simulator app forward. */
async function boot(s, exec) {
  try { await exec('xcrun', ['simctl', 'boot', s.udid]); await exec('xcrun', ['simctl', 'bootstatus', s.udid, '-b']); await exec('open', ['-a', 'Simulator']); } catch (e) {
    if (!/current state: Booted/.test(String(e.stderr))) throw e; // already booted is fine
  }
}

export const readScreens = async (swiftPath) => parseScreens(await readFile(swiftPath, 'utf8'));
