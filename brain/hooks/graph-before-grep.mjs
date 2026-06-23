#!/usr/bin/env node
// graph-before-grep.mjs — PreToolUse hook (brain plugin).
//
// When an agent reaches for raw text search (the Grep tool, or a `grep`/`rg`/
// `ag`/`findstr` invocation via Bash) *inside a repo that has a graphify graph*,
// this nudges it to traverse the graph first — the "graph before grep" rule
// (POC §6.1 / §14.5). Guidance in CLAUDE.md is not enforcement; this hook is.
//
// SELF-GATING: it only speaks when `<cwd>/graphify-out/graph.json` exists. In any
// repo without a graph it stays completely silent (no-op, exit 0), so it adds zero
// noise to non-graphified projects. Non-blocking: it injects a reminder via
// additionalContext and always allows the tool to run.
//
// Registered via this plugin's hooks/hooks.json (matcher "Grep|Bash"). Reversible,
// no state. The `graphify-out/graph.json` presence test is the frozen detection
// contract that consumers (e.g. ai-agent-manager) also read — do not change it
// without a Track B handshake (POC §17.1).

import { existsSync } from 'node:fs';
import { join } from 'node:path';

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

const cwd = input.cwd || process.cwd();
const toolName = input.tool_name || '';
const toolInput = input.tool_input || {};

// Only care about text-search tools.
let isSearch = false;
if (toolName === 'Grep') {
  isSearch = true;
} else if (toolName === 'Bash') {
  const cmd = String(toolInput.command || '');
  // word-boundary match so we don't fire on e.g. "graphql" or "ripgrep-config"
  isSearch = /(^|[\s|&;(])(grep|rg|ag|findstr)(\s|$)/.test(cmd);
}
if (!isSearch) process.exit(0);

// Gate: a graph must exist for this repo.
if (!existsSync(join(cwd, 'graphify-out', 'graph.json'))) process.exit(0);

const reminder =
  'graph-before-grep: this repo has a graphify graph (graphify-out/graph.json). ' +
  'Per the brain\'s 3-step query rule, traverse the graph first for structural ' +
  'questions ("where does X live", "what calls Y", blast radius) — run ' +
  '`graphify query "<question>"` (the graphify skill auto-detects the local graph) ' +
  'before sweeping raw source. Raw search is fine once the graph + wiki come up ' +
  'empty, or to read a file you are about to edit. (This is a non-blocking reminder.)';

process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      additionalContext: reminder,
    },
  })
);
process.exit(0);
