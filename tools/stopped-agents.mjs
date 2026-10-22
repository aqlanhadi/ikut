#!/usr/bin/env node
// Lists this session's agents that the usage limit stopped, so the overseer can resume each one with SendMessage to
// its agent ID (CLAUDE.md, An agent stopped by the session limit). An agent that already carried on isn't listed.
//
//   tools/stopped-agents.mjs                 # this session ($CLAUDE_CODE_SESSION_ID)
//   tools/stopped-agents.mjs <session id>
//
// Exit 0 with "none" when no agent is stopped.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { tail, isLimit, resetsAt } from '../.claude/hooks/auto-resume.mjs';

const session = process.argv[2] ?? process.env.CLAUDE_CODE_SESSION_ID;
if (!session) { console.error('usage: tools/stopped-agents.mjs [session id]   (inside a session it defaults to that one)'); process.exit(64); }
const projects = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'projects');
const dir = fs.readdirSync(projects).map((p) => path.join(projects, p, session, 'subagents')).find((d) => fs.existsSync(d));
if (!dir) { console.log('none (this session has no agents)'); process.exit(0); }

const stopped = [];
for (const f of fs.readdirSync(dir).filter((n) => /^agent-.*\.jsonl$/.test(n))) {
  const entries = tail(path.join(dir, f));
  const last = entries.find((e) => (e.type === 'user' || e.type === 'assistant') && !e.isMeta);
  if (!isLimit(last)) continue;
  let meta = {};
  try { meta = JSON.parse(fs.readFileSync(path.join(dir, f.replace(/\.jsonl$/, '.meta.json')), 'utf8')); } catch {}
  // What it was doing: its last words or tool call before the limit.
  const before = entries.find((e) => e.type === 'assistant' && !e.isApiErrorMessage && Array.isArray(e.message?.content));
  const part = before?.message.content.findLast((c) => c.type === 'text' || c.type === 'tool_use');
  const doing = part?.type === 'text' ? part.text : part ? `${part.name} ${JSON.stringify(part.input).slice(0, 160)}` : '';
  stopped.push({ id: last.agentId ?? f.slice(6, -6), meta, at: last.timestamp, resets: resetsAt(last), doing });
}

if (!stopped.length) { console.log('none'); process.exit(0); }
const time = (ms) => new Date(ms).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
for (const a of stopped.sort((x, y) => x.at.localeCompare(y.at))) {
  console.log(`${a.id}  ${a.meta.agentType ?? 'agent'}  "${a.meta.description ?? ''}"`);
  console.log(`  stopped ${time(Date.parse(a.at))}${a.resets ? `, limit reset ${time(a.resets * 1000)}${a.resets * 1000 > Date.now() ? ' (not yet)' : ''}` : ''}`
    + `${a.meta.worktreePath ? `, worktree ${a.meta.worktreePath}` : ''}`);
  if (a.doing) console.log(`  last: ${a.doing.replace(/\s+/g, ' ').slice(0, 200)}`);
}
console.log(`\nResume each with SendMessage (to: the agent ID): "The usage limit stopped you; it has reset. Carry on where you left off."`);
