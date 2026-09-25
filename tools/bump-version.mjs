#!/usr/bin/env node
// Release step (INNOV-311): turn .bumps/<plugin>/* fragments into one version bump.
// Feature branches only add fragments, so parallel PRs never touch the version literal.
// Usage: node tools/bump-version.mjs <plugin-dir>   e.g. brain, wave
import { readFileSync, writeFileSync, readdirSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const dir = process.argv[2];
if (!dir) { console.error('usage: bump-version.mjs <plugin-dir>'); process.exit(2); }
const manifest = join(root, dir, '.claude-plugin/plugin.json');
if (!/^[\w-]+$/.test(dir) || !existsSync(manifest)) { console.error(`bump-version: '${dir}' is not a plugin dir (no ${dir}/.claude-plugin/plugin.json).`); process.exit(2); }
const fragDir = join(root, '.bumps', dir);
const frags = existsSync(fragDir) ? readdirSync(fragDir) : [];
if (!frags.length) { console.error(`bump-version: no fragments in .bumps/${dir}/ — nothing to release.`); process.exit(1); }
const kinds = ['patch', 'minor', 'major'];
const rank = Math.max(...frags.map((f) => {
  const kind = readFileSync(join(fragDir, f), 'utf8').trim() || 'patch';
  if (!kinds.includes(kind)) throw new Error(`.bumps/${dir}/${f}: '${kind}' is not patch|minor|major`);
  return kinds.indexOf(kind);
}));
const text = readFileSync(manifest, 'utf8');
const json = JSON.parse(text);
const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(json.version);
if (!m) throw new Error(`${dir}: version '${json.version}' is not x.y.z`);
let [maj, min, pat] = m.slice(1).map(Number);
if (rank === 2) [maj, min, pat] = [maj + 1, 0, 0];
else if (rank === 1) [min, pat] = [min + 1, 0];
else pat += 1;
const next = `${maj}.${min}.${pat}`;
// Rewrite only the version line so key order, formatting and CRLF survive.
writeFileSync(manifest, text.replace(/("version"\s*:\s*")[^"]*"/, `$1${next}"`));
// Consume fragments BEFORE regenerating: if the generator throws, a retry finds
// none and refuses instead of stepping the version twice. Rerun the generator.
for (const f of frags) rmSync(join(fragDir, f));
if (dir === 'brain') await import('./generate-host-manifests.mjs');
console.log(`bump-version: ${dir} ${json.version} -> ${next} (${frags.length} fragment(s) applied).`);
