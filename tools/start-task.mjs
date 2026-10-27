#!/usr/bin/env node
// Sets up one piece of work the way CLAUDE.md (Branches, Simulators) wants it, and prints where everything is:
//
//   tools/start-task.mjs D21 stop-sounds        # branch d21-stop-sounds, worktree .claude/worktrees/d21-stop-sounds
//   tools/start-task.mjs D21 stop-sounds --no-board
//
// - The branch `<id>-<what>`, cut from local main, in its own worktree. Run from a `worktree-agent-…` worktree (an
//   agent started with isolation "worktree"), it renames that branch instead, and moves it onto main if it has no
//   commits yet.
// - The task's build folder /tmp/ikut-dd-<id>, with SourcePackages cloned from the newest other build folder (an
//   APFS clone: instant, and no extra disk until files change), so the first build doesn't fetch the packages
//   (its workspace-state.json is rewritten to this folder's paths).
// - A log folder /tmp/ikut-logs-<id> for this task's run logs (tools/finish-task.mjs --last removes both).
// - The task marked `doing` on the board (not with --no-board).

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const [id, what] = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const noBoard = process.argv.includes('--no-board');
if (!/^[A-Za-z]+\d+[a-z]?$/.test(id ?? '') || !/^[a-z0-9]+(-[a-z0-9]+)*$/.test(what ?? '')) {
  console.error('usage: tools/start-task.mjs <task id, e.g. D21> <what, lower-case-words> [--no-board]');
  process.exit(64);
}
const task = id.toLowerCase();
const branch = `${task}-${what}`;
const git = (...args) => spawnSync('git', args, { encoding: 'utf8' });
const must = (r, what) => { if (r.status !== 0) { console.error(`${what} failed: ${(r.stderr || r.stdout).trim()}`); process.exit(1); } return r.stdout.trim(); };
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(path.resolve(here, git('-C', here, 'rev-parse', '--git-common-dir').stdout.trim()));
const main = must(git('-C', repo, 'rev-parse', 'main'), 'reading main');

// ---- branch and worktree
let worktree;
const current = git('rev-parse', '--abbrev-ref', 'HEAD').stdout.trim();
if (current.startsWith('worktree-agent-')) {
  worktree = must(git('rev-parse', '--show-toplevel'), 'finding this worktree');
  must(git('branch', '-m', branch), `renaming ${current}`);
  const own = git('rev-list', '--count', `${main}..HEAD`).stdout.trim();
  const clean = git('status', '--porcelain').stdout.trim() === '';
  if (own === '0' && clean && git('rev-parse', 'HEAD').stdout.trim() !== main) {
    must(git('reset', '--hard', main), 'moving onto main');
    console.log(`renamed ${current} to ${branch} and moved it onto local main`);
  } else {
    console.log(`renamed ${current} to ${branch}${own === '0' ? '' : ` (it has ${own} commit(s); rebase on main before reporting)`}`);
  }
} else {
  const porcelain = git('-C', repo, 'worktree', 'list', '--porcelain').stdout;
  const existing = porcelain.split('\n\n').find((b) => b.includes(`branch refs/heads/${branch}\n`) || b.endsWith(`branch refs/heads/${branch}`));
  if (existing) {
    worktree = /^worktree (.*)$/m.exec(existing)[1];
    console.log(`${branch} already has a worktree`);
  } else {
    worktree = path.join(repo, '.claude', 'worktrees', branch);
    const hasBranch = git('-C', repo, 'rev-parse', '--verify', '--quiet', `refs/heads/${branch}`).status === 0;
    must(hasBranch ? git('-C', repo, 'worktree', 'add', worktree, branch) : git('-C', repo, 'worktree', 'add', '-b', branch, worktree, main), 'creating the worktree');
    console.log(hasBranch ? `checked out the existing ${branch}` : `created ${branch} from local main (${main.slice(0, 7)})`);
  }
}

// ---- build and log folders
const dd = `/tmp/ikut-dd-${task}`;
const logs = `/tmp/ikut-logs-${task}`;
fs.mkdirSync(logs, { recursive: true });
if (!fs.existsSync(path.join(dd, 'SourcePackages'))) {
  fs.mkdirSync(dd, { recursive: true });
  const donors = fs.readdirSync('/tmp')
    .filter((d) => /^ikut-dd-/.test(d) && `/tmp/${d}` !== dd && fs.existsSync(`/tmp/${d}/SourcePackages/checkouts`))
    .map((d) => ({ d: `/tmp/${d}/SourcePackages`, t: fs.statSync(`/tmp/${d}/SourcePackages`).mtimeMs }))
    .sort((a, b) => b.t - a.t);
  if (donors.length) {
    const r = spawnSync('cp', ['-cR', donors[0].d, path.join(dd, 'SourcePackages')], { encoding: 'utf8' });
    // workspace-state.json records each checkout and artifact by absolute path inside the donor's folder; left as it
    // is, SwiftPM would look for them there. Point the paths at this folder rather than deleting the file: without
    // it SwiftPM forgets the binary artifacts (their checksums) and downloads them again.
    const state = path.join(dd, 'SourcePackages', 'workspace-state.json');
    if (r.status === 0 && fs.existsSync(state)) {
      // Any build folder's path, not only the donor's: a donor seeded by an older copy can still name a third folder.
      const own = path.join(dd, 'SourcePackages');
      fs.writeFileSync(state, fs.readFileSync(state, 'utf8').replace(/(\/private)?\/tmp\/ikut-dd-[^/"]+\/SourcePackages/g, own));
    }
    console.log(r.status === 0 ? `seeded ${dd}/SourcePackages from ${donors[0].d}` : `couldn't seed the packages (${r.stderr.trim()}); the first build fetches them`);
  } else {
    console.log(`no build folder to seed the packages from; the first build fetches them into ${dd}`);
  }
}

// ---- board
if (!noBoard) {
  const r = spawnSync('node', [path.join(repo, 'planning', 'task.mjs'), id, '{"status":"doing"}'], { encoding: 'utf8' });
  console.log(r.status === 0 ? `board: ${id} doing` : `board: couldn't mark ${id} doing (${(r.stderr || r.stdout).trim()})`);
}

console.log(`
branch       ${branch}
worktree     ${worktree}
build folder ${dd}   (-derivedDataPath ${dd})
logs         ${logs}/
simulator    iPhone 17 #1  C0A40D2A-0607-4B95-A1BE-F8C9190D81C1 (unless the brief says otherwise)`);
