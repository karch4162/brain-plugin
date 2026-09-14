import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const hook = fileURLToPath(new URL('../brain/hooks/graph-before-grep.mjs', import.meta.url));
test('hook recognizes Claude, Codex and Grok events without conflating repos', t => {
  const base = mkdtempSync(join(tmpdir(), 'brain-hooks-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const roots = ['one', 'two'].map(name => join(base, name));
  for (const root of roots) { mkdirSync(join(root, 'graphify-out'), { recursive: true }); writeFileSync(join(root, 'graphify-out/graph.json'), '{}'); }
  const call = input => spawnSync(process.execPath, [hook], { input: JSON.stringify(input), encoding: 'utf8' }).stdout;
  const id = randomUUID();
  assert.match(call({ cwd: roots[0], session_id: id, tool_name: 'Bash', tool_input: { command: 'rg hello' } }), /graph-before-grep/);
  assert.equal(call({ cwd: roots[0], session_id: id, tool_name: 'Bash', tool_input: { command: 'rg hello' } }), '');
  assert.match(call({ cwd: roots[1], session_id: id, tool_name: 'exec_command', tool_input: { cmd: 'rg hello' } }), /graph-before-grep/);
  assert.match(call({ cwd: roots[0], sessionId: randomUUID(), toolName: 'Bash', toolInput: { command: 'rg hello' } }), /graph-before-grep/);
  assert.equal(call({ cwd: roots[0], session_id: randomUUID(), tool_name: 'Grep', tool_input: { path: roots[0] + '-outside' } }), '');
});
