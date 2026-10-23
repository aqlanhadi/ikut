import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { request } from 'node:http';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { testingOn, parseScreens, groupScreens, launchScreen, simHolder, SIMULATORS, BUNDLE_ID } from '../dashboard/screens.mjs';
import { readScreens } from '../dashboard/screens.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const swiftPath = join(here, '../../ios/ikut/Lobby/LobbyDemo.swift');

test('parseScreens finds the current states and ignores default', async () => {
  const names = await readScreens(swiftPath);
  for (const n of ['lobby-organizer', 'lobby-empty', 'lobby-member', 'lobby-turnback', 'lobby-meet-failure', 'add-search', 'add-details', 'add-meet']) assert.ok(names.includes(n), n);
  assert.ok(!names.includes('default'));
});

test('parseScreens survives a case on its own line, several labels, and other switches', () => {
  const src = `enum Other { func f() { switch x { case "nope": break } } }
enum DemoScreens {
    static func view() {
        switch name {
        case "a-one":
            return 1
        case "a-two", "b-one": return 2
          case "c":
        return 3
        default: return nil
        }
    }
}`;
  assert.deepEqual(parseScreens(src), ['a-one', 'a-two', 'b-one', 'c']);
  assert.deepEqual(parseScreens('nothing here'), []);
  assert.deepEqual(groupScreens(['a-one', 'a-two', 'b-one', 'c']).map((g) => [g.prefix, g.names.length]), [['a', 2], ['b', 1], ['c', 1]]);
});

const names = ['lobby-organizer'];
const fakeExec = (calls, fail = {}) => async (cmd, args, opts) => {
  calls.push([cmd, ...args, opts?.env?.SIMCTL_CHILD_IKUT_SCREEN].filter(Boolean));
  const key = args[1];
  if (fail[key]) throw Object.assign(new Error('x'), { stderr: fail[key] });
  return { stdout: key === 'get_app_container' ? '/x/ikut.app\n' : '' };
};
const free = async () => null;

test('launchScreen refuses an unknown simulator or screen before running anything', async () => {
  const calls = [];
  assert.equal((await launchScreen({ sim: '3', screen: 'lobby-organizer' }, { names, exec: fakeExec(calls), holder: free, ps: async () => [] })).code, 404);
  assert.equal((await launchScreen({ sim: 'C0A40D2A-0607-4B95-A1BE-F8C9190D81C1', screen: 'lobby-organizer' }, { names, exec: fakeExec(calls), holder: free, ps: async () => [] })).code, 404);
  assert.equal((await launchScreen({ sim: '1', screen: 'x; rm -rf /' }, { names, exec: fakeExec(calls), holder: free, ps: async () => [] })).code, 404);
  assert.deepEqual(calls, []);
});

test('launchScreen launches with the screen in the child environment, and reports busy and not installed in words', async () => {
  const calls = [];
  const ok = await launchScreen({ sim: '1', screen: 'lobby-organizer' }, { names, exec: fakeExec(calls), holder: free, ps: async () => [], modified: async () => new Date(0) });
  assert.equal(ok.ok, true);
  assert.deepEqual(calls.at(-1), ['xcrun', 'simctl', 'launch', '--terminate-running-process', SIMULATORS[0].udid, BUNDLE_ID, 'lobby-organizer']);
  const busy = await launchScreen({ sim: '2', screen: 'lobby-organizer' }, { names, exec: fakeExec([]), holder: async () => 'run-ui (pid 1)' });
  assert.equal(busy.code, 409); assert.match(busy.message, /busy with: run-ui/);
  const none = await launchScreen({ sim: '2', screen: 'lobby-organizer' }, { names, exec: fakeExec([], { get_app_container: 'No such app' }), holder: free, ps: async () => [] });
  assert.equal(none.code, 409); assert.match(none.message, /not installed/); assert.match(none.hint, new RegExp(SIMULATORS[1].udid));
});

test('a running xcodebuild test makes only its own simulator busy', async () => {
  const u1 = SIMULATORS[0].udid, u2 = SIMULATORS[1].udid;
  const ps = [
    `  101 00:12 /usr/bin/xcodebuild test -scheme ikut -destination platform=iOS Simulator,id=${u1} -derivedDataPath /tmp/x`,
    `  102 00:03 /usr/bin/xcodebuild build -scheme ikut -destination platform=iOS Simulator,id=${u2}`,
  ];
  assert.match(testingOn(u1, ps), /xcodebuild test/);
  assert.equal(testingOn(u2, ps), null, 'a plain build does not count, nor does the other phone');
  const calls = [];
  const r = await launchScreen({ sim: '1', screen: 'lobby-organizer' }, { names, exec: fakeExec(calls), holder: free, ps: async () => ps });
  assert.equal(r.code, 409); assert.match(r.message, /iPhone 17 #1 is running tests \(xcodebuild test …\)\. Wait for it to finish, or use the other phone\./);
  assert.deepEqual(calls, []);
  assert.equal((await launchScreen({ sim: '2', screen: 'lobby-organizer' }, { names, exec: fakeExec([]), holder: free, ps: async () => ps })).ok, true);
});

test('simHolder reads the holder when lockf cannot take the lock', async () => {
  assert.equal(await simHolder('u', async () => ({})), null);
  assert.equal(await simHolder('u', async () => { throw new Error('held'); }, async () => 'run-ui (pid 5)\n'), 'run-ui (pid 5)');
});

// ---- the HTTP checks, against a real server on its own port with no demos
let server, port;
before(async () => {
  port = 4900 + Math.floor(Math.random() * 90);
  const dir = await mkdtemp(join(tmpdir(), 'ikut-dash-'));
  server = spawn('node', [join(here, '../dashboard/server.mjs'), '--port', String(port), '--demos', dir], { stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise((ok) => server.stdout.on('data', (d) => String(d).includes('http://') && ok()));
});
after(() => server.kill());
const post = (headers, body = { sim: '1', screen: 'nope' }) => fetch(`http://127.0.0.1:${port}/api/screen`, { method: 'POST', headers, body: JSON.stringify(body) });

test('GET /api/screens lists the groups and the two simulators', async () => {
  const j = await (await fetch(`http://127.0.0.1:${port}/api/screens`)).json();
  assert.equal(j.simulators.length, 2);
  assert.ok(j.groups.find((g) => g.prefix === 'lobby').names.includes('lobby-organizer'));
});

test('POST /api/screen: wrong content type, wrong Host or Origin, unknown simulator or name are refused', async () => {
  assert.equal((await post({ 'content-type': 'text/plain' })).status, 403);
  assert.equal((await post({ 'content-type': 'application/json', origin: 'http://evil.example' })).status, 403);
  const evilHost = await new Promise((ok) => { // fetch won't send a made-up Host
    const r = request({ host: '127.0.0.1', port, path: '/api/screen', method: 'POST', headers: { 'content-type': 'application/json', host: 'evil.example' } }, (res) => { res.resume(); ok(res.statusCode); });
    r.end('{"sim":"1","screen":"lobby-organizer"}');
  });
  assert.equal(evilHost, 403);
  assert.equal((await post({ 'content-type': 'application/json' }, { sim: '1', screen: 'nope' })).status, 404);
  assert.equal((await post({ 'content-type': 'application/json' }, { sim: '9', screen: 'lobby-organizer' })).status, 404);
});
