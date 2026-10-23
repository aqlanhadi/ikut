#!/usr/bin/env node
// What a test run came to, in a few lines: counts, then each failure with its message.
//
//   tools/test-summary.mjs run.xcresult        # from the result bundle (exact counts)
//   tools/test-summary.mjs run.log             # from xcodebuild's output, or a qa runner's log
//
// Prints `tests: N passed, M failed, K skipped` (or the qa runner's RESULT and its check counts), then up to 20
// failures. Exit code 0 when nothing failed, 1 when something did, 2 when the file has no result in it yet.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';

const file = process.argv[2];
if (!file || !fs.existsSync(file)) {
  console.error('usage: tools/test-summary.mjs <run.xcresult | run.log>');
  process.exit(64);
}
const MAX = 20;
const out = (failures, line) => {
  console.log(line);
  for (const f of failures.slice(0, MAX)) console.log(`  ✘ ${f}`);
  if (failures.length > MAX) console.log(`  … and ${failures.length - MAX} more`);
};

if (file.endsWith('.xcresult')) {
  const r = spawnSync('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', file, '--compact'], { encoding: 'utf8' });
  if (r.status !== 0) { console.error(r.stderr.trim() || 'xcresulttool failed'); process.exit(2); }
  const s = JSON.parse(r.stdout);
  const failures = (s.testFailures ?? []).map((f) => `${f.targetName ? `${f.targetName}/` : ''}${f.testName}: ${(f.failureText ?? '').split('\n')[0]}`);
  out(failures, `tests: ${s.passedTests} passed, ${s.failedTests} failed, ${s.skippedTests} skipped (${s.result})`);
  process.exit(s.failedTests > 0 || s.result === 'Failed' ? 1 : 0);
}

const lines = fs.readFileSync(file, 'utf8').split('\n');

// A qa runner's log ends in `RESULT: PASS|FAIL|ABORT …`; report it with its PASS/FAIL/SKIP check lines.
const count = (re) => lines.filter((l) => re.test(l)).length;
const checkFails = lines.filter((l) => /(^|\]\s+|QA CHECK:? )FAIL\b/.test(l)).map((l) => l.replace(/^.*?FAIL:?\s*/, ''));
const checks = () => `checks: ${count(/(^|\]\s+|QA CHECK:? )PASS\b/)} passed, ${checkFails.length} failed, ${count(/(^|\]\s+)SKIP\b/)} skipped`;
const result = lines.findLast((l) => /^RESULT: (PASS|FAIL|ABORT)/.test(l));
if (result) {
  out(checkFails, `${result}\n${checks()}`);
  process.exit(/^RESULT: PASS/.test(result) ? 0 : 1);
}

// xcodebuild output: Swift Testing (✔/✘ Test …) and XCTest (Test Case '-[…]' passed/failed).
let passed = 0;
let failed = 0;
let skipped = 0;
const failures = [];
const issues = new Map(); // Swift Testing test name -> its first recorded issue
for (const l of lines) {
  let m;
  if ((m = /^✔ Test (.+?) passed after/.exec(l))) passed++;
  else if ((m = /^✘ Test (.+?) recorded an issue at (\S+?):? (.*)$/.exec(l))) { if (!issues.has(m[1])) issues.set(m[1], `${m[2]} ${m[3]}`); }
  else if ((m = /^✘ Test (?!run with)(.+?) failed after/.exec(l))) { failed++; failures.push(`${m[1]}: ${issues.get(m[1]) ?? 'failed'}`); }
  else if (/^\S+ Test (?!run with).+ skipped/.test(l)) skipped++;
  else if ((m = /^Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped)/.exec(l))) {
    if (m[3] === 'passed') passed++;
    else if (m[3] === 'skipped') skipped++;
    else { failed++; failures.push(`${m[1]}.${m[2]}: ${issues.get(`${m[1]} ${m[2]}`) ?? 'failed'}`); }
  } else if ((m = /^(\S+:\d+): error: -\[(\S+) (\S+)\] : (.*)$/.exec(l))) { if (!issues.has(`${m[2]} ${m[3]}`)) issues.set(`${m[2]} ${m[3]}`, `${m[1]} ${m[4]}`); }
}
// XCTest prints the failure line before "Test Case … failed"; fill in messages found after the fact.
for (let i = 0; i < failures.length; i++) {
  const m = /^(\S+?)\.(\S+): failed$/.exec(failures[i]);
  if (m && issues.has(`${m[1]} ${m[2]}`)) failures[i] = `${m[1]}.${m[2]}: ${issues.get(`${m[1]} ${m[2]}`)}`;
}
// Counts come from the frameworks' own summary lines when they're there: Swift Testing's "Test run with N tests in M
// suites passed|failed after …" and XCTest's last "Executed N tests, with … failures" (the grand total). The per-test
// lines above are only the fallback for a run still going, and the source of the failure list.
const st = lines.findLast((l) => /^\S+ Test run with \d+ tests? in \d+ suites? (passed|failed)/.test(l));
const xt = lines.findLast((l) => /^\s*Executed \d+ tests?, with /.test(l));
if (st || xt) {
  let total = 0;
  let totalFailed = 0;
  let totalSkipped = 0;
  if (st) {
    const m = /Test run with (\d+) tests?/.exec(st);
    total += Number(m[1]);
    if (/ failed after /.test(st)) totalFailed += Math.max(failures.filter((f) => !/^\S+\.\S+: /.test(f)).length, 1);
  }
  if (xt) {
    const m = /Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?/.exec(xt);
    total += Number(m[1]);
    totalSkipped += Number(m[2] ?? 0);
    totalFailed += Number(m[3]);
  }
  const swiftSkipped = lines.filter((l) => /^\S+ Test (?!run with).+ skipped/.test(l)).length;
  totalSkipped += st ? swiftSkipped : 0;
  passed = Math.max(total - totalFailed - totalSkipped, 0);
  failed = totalFailed;
  skipped = totalSkipped;
}
const verdict = lines.findLast((l) => /\*\* (TEST|BUILD|TEST BUILD) (SUCCEEDED|FAILED|INTERRUPTED) \*\*/.test(l))?.trim();
if (verdict === '** BUILD FAILED **' || verdict === '** TEST BUILD FAILED **' || (!passed && !failed && lines.some((l) => /: error: /.test(l)))) {
  const errs = [...new Set(lines.filter((l) => /^\/\S+:\d+:\d+: error: /.test(l)).map((l) => l.replace(/^.*\/(\S+:\d+:\d+): error: /, '$1 ')))];
  out(errs, `build failed: ${errs.length} error(s)`);
  process.exit(1);
}
if (!verdict && !passed && !failed) {
  if (checkFails.length || lines.some((l) => /^@@DONE |QA CHECK[: ]|\]\s+PASS\b/.test(l))) { out(checkFails, `${checks()} (no RESULT line yet: still running, or killed)`); process.exit(2); }
  console.log('no test results in this log yet (still running, or it stopped before testing)');
  process.exit(2);
}
failures.push(...checkFails.map((f) => `QA CHECK ${f}`));
out(failures, `tests: ${passed} passed, ${failed} failed, ${skipped} skipped (${passed + failed + skipped} in all)${verdict ? ` (${verdict.replaceAll('*', '').trim()})` : ' (no verdict line yet)'}`);
process.exit(failed || /FAILED/.test(verdict ?? '') ? 1 : 0);
