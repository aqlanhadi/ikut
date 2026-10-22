#!/usr/bin/env node
// Cleans up after a piece is merged into main (CLAUDE.md, Branches): its worktree and branch, and, once no other
// branch of the same task is open, the task's review worktree, build folder and log folder.
//
//   tools/finish-task.mjs d21-stop-sounds
//   tools/finish-task.mjs d21-stop-sounds --dropped   # not merged: only when the owner agreed to drop it
//
// It doesn't merge; the overseer does that (git merge --no-ff) first.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const branch = process.argv.slice(2).find((a) => !a.startsWith('--'));
const dropped = process.argv.includes('--dropped');
if (!/^[a-z]+\d+[a-z]?-[a-z0-9-]+$/.test(branch ?? '')) {
  console.error('usage: tools/finish-task.mjs <branch, e.g. d21-stop-sounds> [--dropped]');
  process.exit(64);
}
const git = (...args) => spawnSync('git', args, { encoding: 'utf8' });
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(path.resolve(here, git('-C', here, 'rev-parse', '--git-common-dir').stdout.trim()));
const g = (...args) => git('-C', repo, ...args);

if (g('rev-parse', '--verify', '--quiet', `refs/heads/${branch}`).status !== 0) { console.error(`no branch ${branch}`); process.exit(1); }
const merged = g('branch', '--merged', 'main', '--list', branch).stdout.trim() !== '';
if (!merged && !dropped) {
  console.error(`${branch} isn't merged into main. Merge it first, or pass --dropped if the owner agreed to drop it.`);
  process.exit(1);
}

// ---- the branch's worktree and the branch
const blocks = g('worktree', 'list', '--porcelain').stdout.split('\n\n');
const mine = blocks.find((b) => new RegExp(`^branch refs/heads/${branch}$`, 'm').test(b));
if (mine) {
  const wt = /^worktree (.*)$/m.exec(mine)[1];
  const r = g('worktree', 'remove', wt);
  if (r.status !== 0) { console.error(`couldn't remove ${wt}: ${r.stderr.trim()}\nCommit or discard what's left there, then run this again.`); process.exit(1); }
  console.log(`removed worktree ${wt}`);
}
const del = g('branch', dropped && !merged ? '-D' : '-d', branch);
if (del.status !== 0) { console.error(del.stderr.trim()); process.exit(1); }
console.log(`deleted branch ${branch}${dropped && !merged ? ' (dropped, not merged)' : ''}`);

// ---- the task's folders, once its last piece is done
const task = branch.split('-')[0];
const others = g('branch', '--list', `${task}-*`, '--format=%(refname:short)').stdout.trim().split('\n').filter(Boolean);
if (others.length) {
  console.log(`kept the ${task} folders: ${others.join(', ')} still open`);
} else {
  const review = `/tmp/ikut-review-${task}`;
  if (fs.existsSync(review)) {
    if (g('worktree', 'remove', '--force', review).status !== 0) fs.rmSync(review, { recursive: true, force: true });
    console.log(`removed ${review}`);
  }
  for (const dir of [`/tmp/ikut-dd-${task}`, `/tmp/ikut-logs-${task}`]) {
    if (fs.existsSync(dir)) { fs.rmSync(dir, { recursive: true, force: true }); console.log(`removed ${dir}`); }
  }
  g('worktree', 'prune');
}
