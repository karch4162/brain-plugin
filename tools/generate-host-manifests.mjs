#!/usr/bin/env node
// Claude manifest remains the release-version source; host artifacts are generated.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../brain/', import.meta.url));
const source = JSON.parse(readFileSync(join(root, '.claude-plugin/plugin.json'), 'utf8'));
const common = { name: source.name, version: source.version, description: 'Shared Git-backed knowledge, session continuity, graph context, and wiki maintenance for coding agents.', author: source.author };
const outputs = {
  '.codex-plugin/plugin.json': { ...common, skills: './skills/', interface: { displayName: 'Brain', shortDescription: 'Shared knowledge and session continuity.', longDescription: common.description, developerName: source.author.name, category: 'Productivity', capabilities: [], defaultPrompt: 'Use Brain to resume context and preserve the decisions from this task.' } },
  'plugin.json': { $schema: 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json', ...common },
};
for (const [name, payload] of Object.entries(outputs)) {
  const path = join(root, name); const text = JSON.stringify(payload, null, 2) + '\n';
  if (process.argv.includes('--check')) {
    if (readFileSync(path, 'utf8').replace(/\r\n/g, '\n') !== text) throw new Error(`Generated manifest is stale: ${name}`);
  } else { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, text); }
}
console.log('Host manifests are synchronized.');
