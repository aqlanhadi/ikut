// Local dashboard for the ikut live demos: lists qa/demo*.mjs, starts one, stops it, and shows its events live.
//
//   node qa/dashboard/server.mjs [--port 4322] [--demos <dir | dir/pattern*.mjs>]   → http://localhost:4322
//
// The demos print `DEMO {json}` lines (see qa/lib/demo-common.mjs); everything else is plain log.
// Only one demo runs at a time (they share the two simulators). The current/last run is kept in memory
// and replayed to every new page, so a reload loses nothing.

import { createServer } from 'node:http';
import { spawn, execFile } from 'node:child_process';
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, basename } from 'node:path';
import { createInterface } from 'node:readline';
import { promisify } from 'node:util';
import { connect } from 'node:net';

const here = dirname(fileURLToPath(import.meta.url));
const QA = join(here, '..');
const PAGE = join(here, 'index.html');
const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };
const PORT = Number(arg('--port') || process.env.PORT) || 4322;
const DEMOS = arg('--demos') || process.env.DEMOS || QA;
const LOG_LINES = 500;
const KILL_AFTER_MS = 20_000;

// ---- discovery: `--demos` is a folder (files named demo*.mjs) or a path with a * in the file name
const [demoDir, demoPattern] = DEMOS.includes('*')
  ? [dirname(DEMOS), new RegExp('^' + basename(DEMOS).replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$')]
  : [DEMOS, /^demo.*\.mjs$/];

const run1 = promisify(execFile);
async function describe(file) {
  try {
    const { stdout } = await run1('node', [join(demoDir, file), '--describe'], { cwd: QA, timeout: 15_000 });
    const info = JSON.parse(stdout.trim().split('\n').pop());
    return { file, ...info };
  } catch {
    return { file, title: file, summary: 'No description for this one yet.', phones: [], cast: [], timeline: [], noDescription: true };
  }
}
let demos = [];

// ---- backend hints: are the emulators up, and which project is "production"
const probe = (port) => new Promise((ok) => {
  const s = connect({ port, host: '127.0.0.1' });
  s.setTimeout(800, () => { s.destroy(); ok(false); });
  s.on('connect', () => { s.destroy(); ok(true); }).on('error', () => ok(false));
});
async function backends() {
  const [firestore, auth, functions] = await Promise.all([8080, 9099, 5001].map(probe));
  let project = null;
  try {
    const plist = join(QA, '..', 'ios/ikut/Resources/GoogleService-Info.plist');
    project = (await run1('/usr/libexec/PlistBuddy', ['-c', 'Print :PROJECT_ID', plist])).stdout.trim();
  } catch { /* no plist: the page just won't name the project */ }
  return { emulators: { up: firestore && auth && functions, hint: 'Emulators not running: cd firebase && firebase emulators:start' }, production: { project } };
}
async function discover() {
  const files = (await readdir(demoDir)).filter((f) => demoPattern.test(f)).sort();
  demos = await Promise.all(files.map(describe));
}

// ---- the one run
let run = null; // { demo, options, status, startedAt, exitCode, events, log, child }
const clients = new Set();
const publish = (msg) => { for (const res of clients) res.write(`data: ${JSON.stringify(msg)}\n\n`); };
const meta = () => run && { file: run.demo.file, title: run.demo.title, durationSeconds: run.demo.durationSeconds, timeline: run.demo.timeline,
  options: run.options, status: run.status, startedAt: run.startedAt, exitCode: run.exitCode, stopping: run.stopping };
const snapshot = () => run ? { k: 'snapshot', run: meta(), events: run.events, log: run.log } : { k: 'snapshot', run: null, events: [], log: [] };

function addEvent(ev) {
  ev.ts = Date.now();
  run.events.push(ev);
  publish({ k: 'ev', ev });
}
function addLine(line) {
  if (line.startsWith('DEMO ')) {
    try { return addEvent(JSON.parse(line.slice(5))); } catch { /* not valid JSON: show it as a log line */ }
  }
  run.log.push(line);
  if (run.log.length > LOG_LINES) run.log.shift();
  publish({ k: 'log', line });
}

function start(demo, options) {
  const args = [join(demoDir, demo.file)];
  if (options.skipBuild) args.push('--skip-build');
  if (options.endTrip) args.push('--end-trip');
  args.push('--backend', options.backend);
  const child = spawn('node', args, { cwd: QA, stdio: ['ignore', 'pipe', 'pipe'] });
  const r = run = { demo, options, status: 'running', startedAt: Date.now(), exitCode: null, stopping: false, events: [], log: [], child };
  for (const stream of [child.stdout, child.stderr]) createInterface({ input: stream }).on('line', (l) => { if (run === r) addLine(l); });
  child.on('error', (e) => { if (run === r) addEvent({ type: 'error', message: `Could not start: ${e.message}` }); });
  child.on('close', (code, signal) => {
    clearTimeout(r.killTimer);
    r.status = 'finished'; r.exitCode = code ?? signal;
    const last = [...r.events].reverse().find((e) => e.type === 'phase')?.phase;
    if (last !== 'ended' && last !== 'failed') {
      addEvent({ type: 'phase', phase: 'failed', detail: r.stopping ? 'stopped' : `the script exited early (${r.exitCode})` });
    }
    publish({ k: 'run', run: meta() });
  });
  publish(snapshot());
}

function stop() {
  const r = run;
  r.stopping = true;
  r.child.kill('SIGTERM');
  r.killTimer = setTimeout(() => r.child.kill('SIGKILL'), KILL_AFTER_MS);
  publish({ k: 'run', run: meta() });
}

// ---- http
const send = (res, code, body, type = 'application/json') => {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
};
async function readJson(req) {
  let body = '';
  for await (const chunk of req) body += chunk;
  return JSON.parse(body || '{}');
}
const isRunning = () => run?.status === 'running';

await discover();

createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const p = url.pathname;
    if (req.method === 'GET' && (p === '/' || p === '/index.html')) return send(res, 200, await readFile(PAGE), 'text/html; charset=utf-8');
    if (req.method === 'GET' && p === '/api/demos') {
      if (url.searchParams.has('refresh')) await discover();
      return send(res, 200, { demos, running: isRunning(), backends: await backends() });
    }
    if (req.method === 'GET' && p === '/api/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
      res.write(`data: ${JSON.stringify(snapshot())}\n\n`);
      clients.add(res);
      req.on('close', () => clients.delete(res));
      return;
    }
    if (req.method === 'POST' && p === '/api/start') {
      const body = await readJson(req);
      if (!['emulators', 'production'].includes(body.backend ?? 'emulators')) return send(res, 400, { error: 'Backend must be emulators or production.' });
      const demo = demos.find((d) => d.file === body.file);
      if (!demo) return send(res, 404, { error: 'No such demo.' });
      if (isRunning()) return send(res, 409, { error: 'A demo is already running. Stop it first.' });
      start(demo, { skipBuild: Boolean(body.skipBuild), endTrip: Boolean(body.endTrip), backend: body.backend ?? 'emulators' });
      return send(res, 200, { ok: true });
    }
    if (req.method === 'POST' && p === '/api/stop') {
      if (!isRunning()) return send(res, 409, { error: 'Nothing is running.' });
      stop();
      return send(res, 200, { ok: true });
    }
    send(res, 404, { error: 'not found' });
  } catch (err) {
    console.error(err);
    send(res, 500, { error: String(err.message || err) });
  }
}).listen(PORT, '127.0.0.1', () => {
  console.log(`ikut demo dashboard → http://localhost:${PORT}  (${demos.length} demo${demos.length === 1 ? '' : 's'} in ${demoDir})`);
});

// Don't leave a demo (and its simulators) running when the dashboard is closed.
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { if (isRunning()) run.child.kill('SIGTERM'); setTimeout(() => process.exit(0), 500); });
