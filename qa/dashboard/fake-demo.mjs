// Stand-in demo for testing the dashboard. Follows the same DEMO-line contract as the real demos.
// Not matched by the qa/demo*.mjs discovery glob. FAKE_NO_DESCRIBE=1 mimics an old script
// without --describe; --fail ends in an error halfway.
const argv = process.argv.slice(2);
const timeline = [
  { at: 5, text: 'Car 2 falls a bit behind', watch: true, who: 'Sam' },
  { at: 12, text: 'Hazard ahead: stopped car', watch: true, who: 'Aini' },
  { at: 22, text: 'Rest stop vote starts', watch: true, who: 'Sam' },
  { at: 32, text: 'Convoy is back together', watch: false, who: 'script' },
];
const info = {
  id: 'fake', title: 'Fake demo (for testing)', summary: 'A 40 second pretend drive used to try out the dashboard.',
  phones: [{ udid: 'FAKE-1', label: 'iPhone 17 #1', role: 'Leader' }, { udid: 'FAKE-2', label: 'iPhone 17 #2', role: 'Follower' }],
  cast: [{ name: 'Sam', role: 'Leader' }, { name: 'Aini', role: 'Follower' }],
  durationSeconds: 40, timeline,
};
if (argv.includes('--describe')) {
  if (process.env.FAKE_NO_DESCRIBE) { console.log('usage: not supported'); process.exit(2); }
  console.log(JSON.stringify(info));
  process.exit(0);
}
const emit = (o) => console.log(`DEMO ${JSON.stringify(o)}`);
process.on('SIGTERM', () => {
  console.log('got SIGTERM, leaving');
  emit({ type: 'phase', phase: 'failed', detail: 'stopped (SIGTERM)' });
  process.exit(143);
});
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const backend = argv[argv.indexOf('--backend') + 1] === 'production' ? 'production' : 'emulators';
emit({ type: 'backend', backend, project: backend === 'production' ? 'ikut-b1083' : 'demo-ikut' });
emit({ type: 'phase', phase: 'building', detail: argv.includes('--skip-build') ? 'reusing the build' : 'building' });
await wait(1000);
emit({ type: 'phase', phase: 'joining', detail: 'phones join' });
emit({ type: 'code', code: 'KX7Q2M' });
await wait(1000);
emit({ type: 'phase', phase: 'running', detail: 'go' });
for (let t = 0; t <= 40; t++) {
  if (t % 5 === 0) emit({ type: 'tick', t });
  console.log(`plain log line at T+${t}`);
  for (const e of timeline) if (e.at === t) emit({ type: 'event', ...e });
  if (t === 8) emit({ type: 'check', phone: 1, status: 'PASS', name: 'Sees car 2' });
  if (t === 14) emit({ type: 'check', phone: 2, status: 'PASS', name: 'Hazard banner shows' });
  if (t === 24) emit({ type: 'check', phone: 2, status: argv.includes('--fail') ? 'FAIL' : 'PASS', name: 'Stop vote visible' });
  if (t === 26 && argv.includes('--fail')) {
    emit({ type: 'error', message: 'Phone 2 lost the trip' });
    emit({ type: 'phase', phase: 'failed', detail: 'a check failed' });
    process.exit(1);
  }
  await wait(1000);
}
emit({ type: 'phase', phase: 'ended', detail: argv.includes('--end-trip') ? 'trip ended' : 'all checks passed' });
