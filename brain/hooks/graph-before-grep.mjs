#!/usr/bin/env node
// graph-before-grep.mjs — PreToolUse hook (brain plugin).
//
// When an agent reaches for raw text search (the Grep tool, or a `grep`/`rg`/
// `ag`/`findstr` invocation via Bash) *inside a repo that has a graphify graph*,
// this nudges it to try the graph first — "graph-first when fresh, advisory
// otherwise" (POC §6.1 / §14.5). Guidance in CLAUDE.md is not enforcement; this
// hook is.
//
// SELF-GATING: it only speaks when `<cwd>/graphify-out/graph.json` exists. In any
// repo without a graph it stays completely silent (no-op, exit 0). Non-blocking:
// it injects a reminder via additionalContext and always allows the tool to run.
//
// ONCE PER SESSION: the reminder fires at most once per Claude Code session
// (marker file keyed by session_id in the OS temp dir) — repeating a ~90-word
// reminder on every Grep/Bash call is noise, not enforcement.
//
// STALENESS-AWARE: the reminder reports the graph's built_at_commit vs the
// repo's current HEAD, so the agent can see whether graph answers are
// authoritative (fresh) or advisory (stale).
//
// Registered via this plugin's hooks/hooks.json (matcher "Grep|Bash"). The
// `graphify-out/graph.json` presence test is the frozen detection contract that
// consumers (e.g. ai-agent-manager) also read — do not change it without a
// Track B handshake (POC §17.1).

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve, relative, isAbsolute } from 'node:path';
import { createHash } from 'node:crypto';
import { graphStatus } from '../core/graph-inputs.mjs';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';

function readStdin() {
  return new Promise((resolve) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => (data += c));
    process.stdin.on('end', () => resolve(data));
    // If nothing arrives, don't hang the tool call.
    setTimeout(() => resolve(data), 1000);
  });
}

const raw = await readStdin();
let input;
try {
  input = JSON.parse(raw || '{}');
} catch {
  process.exit(0); // malformed payload → stay out of the way
}

const toolInput = input.tool_input || input.toolInput || {};
const cwd = resolve(toolInput.workdir || input.cwd || input.workspaceRoot || process.cwd());
const rawToolName = input.tool_name || input.toolName || '';
const toolName = /^(Bash|bash|exec_command|shell_command|shell)$/.test(rawToolName) ? 'Bash'
  : /^(Grep|grep)$/.test(rawToolName) ? 'Grep' : rawToolName;

// Only care about text-search tools.
let isSearch = false;
if (toolName === 'Grep') {
  isSearch = true;
} else if (toolName === 'Bash') {
  const cmd = String(toolInput.command || toolInput.cmd || '');
  // word-boundary match so we don't fire on e.g. "graphql" or "ripgrep-config"
  isSearch = /(^|[\s|&;(])(grep|rg|ag|findstr)(\s|$)/.test(cmd);
} else {
  process.exit(0);
}
if (!isSearch) process.exit(0);

// Gate 1: a graph must exist for the repo the tool is running in. Grep calls
// carry their own search path — if it points outside cwd, stay silent rather
// than nudging about a graph that doesn't cover the search target.
const graphPath = join(cwd, 'graphify-out', 'graph.json');
if (!existsSync(graphPath)) process.exit(0);
if (toolName === 'Grep' && toolInput.path) {
  const target = String(toolInput.path);
  if (/^([A-Za-z]:[\\/]|\/)/.test(target)) {
    const rel = relative(cwd, resolve(target));
    if (rel === '..' || rel.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) || isAbsolute(rel)) process.exit(0);
  }
}

// Gate 2: once per session. Marker in the OS temp dir keyed by session_id.
const sessionId = input.session_id || input.sessionId || process.env.BRAIN_SESSION_ID || process.env.GROK_SESSION_ID;
// A shared "unknown" marker would suppress every future unidentified session.
if (!sessionId) process.exit(0);
const markerId = createHash('sha256').update(`${sessionId}\0${cwd}`).digest('hex');
const marker = join(tmpdir(), `graph-before-grep-${markerId}`);
if (existsSync(marker)) process.exit(0);
try {
  writeFileSync(marker, new Date().toISOString(), { flag: 'wx' });
} catch {
  // Can't dedupe → better to stay silent than to spam every call.
  process.exit(0);
}

// Staleness: graph's built_at_commit vs the repo's HEAD.
let builtAt = null;
try {
  builtAt = JSON.parse(readFileSync(graphPath, 'utf8')).built_at_commit || null;
} catch {
  /* unreadable/huge graph → skip staleness detail */
}
let head = null;
try {
  head = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd,
    timeout: 3000,
    stdio: ['ignore', 'pipe', 'ignore'],
  })
    .toString()
    .trim();
} catch {
  /* not a git repo / git missing → skip staleness detail */
}

const short = (c) => (c ? c.slice(0, 8) : '?');
let freshness;
if (builtAt && head) {
  freshness =
    builtAt === head
      ? `Graph is FRESH (built at HEAD ${short(head)}) — treat graph answers as authoritative for committed structure.`
      : `Graph is STALE (built at ${short(builtAt)}, HEAD is ${short(head)}) — treat graph answers as advisory hints and verify against source.`;
} else {
  freshness = 'Graph freshness unknown — treat graph answers as advisory.';
}

const inputs = graphStatus(cwd);
if (inputs.state === 'stale') freshness = `Graph is STALE: ${inputs.reason}`;
else if (inputs.state === 'fresh') freshness = `Graph inputs match the recorded build (${inputs.files} files; ${inputs.extractor}).`;
else if (existsSync(join(cwd, 'graphify-out/brain-inputs.json'))) freshness = `Graph freshness unknown: ${inputs.reason}`;

const reminder =
  `graph-before-grep (once per session): this repo has a graphify graph. ${freshness} ` +
  'For structural questions ("where does X live", "what calls Y", blast radius) run ' +
  '`graphify query "<question>"` before sweeping raw source — graph-first when fresh, ' +
  'advisory otherwise. Raw search is fine when the graph comes up empty or to read a ' +
  'file you are about to edit. (Non-blocking.)';

process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      additionalContext: reminder,
    },
  })
);
process.exit(0);
