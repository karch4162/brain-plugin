#!/usr/bin/env node
// build-community-notes.mjs — materialize Obsidian stub notes for graph communities.
//
// A GRAPH_REPORT.md links communities as [[_COMMUNITY_<target>|<label>]], but those
// targets don't exist as files, so Obsidian renders them as unresolved ghost nodes
// and the wiki cluster stays disconnected from the code graph. This script writes one
// stub per community under <graph-dir>/communities/, giving every report link a real
// target to resolve to.
//
// Two subtleties it handles (both bit the pilot; both worsen at scale):
//   1. graphify's report sanitizes link <target>s differently than our filenames
//      ("ADR: X" → report target "ADR X", our file "ADR- X"). So each stub carries
//      Obsidian `aliases` for the report's exact target spelling AND the raw name.
//   2. The report LINKS more communities than it writes "### Community" headings for
//      (small/neighbor communities appear in lists only). We make a stub for every
//      linked target, not just the ones with a detail heading.
//
// Covers the per-repo code mirrors under <vault>/graphify/<repo>/ AND the vault's own
// wiki concept graph under <vault>/graphify-out/.
//
// Stub identity is stable across rebuilds: graphify re-mints community labels every
// run, so filenames derived naively from labels churn on each refresh (renames break
// hand-written [[links]] and flood git history). Each rich stub therefore records its
// member node names in frontmatter; on the next run we match new communities to prior
// stubs by member overlap (Jaccard >= 0.5, greedy best-first) and reuse the prior
// filename, carrying the new label as an alias.
//
// The VAULT is resolved from $BRAIN_ROOT (→ $CLAUDE_PROJECT_DIR → cwd); the script
// lives in the plugin, not the vault, so it can't use its own location.
//
// Usage:  BRAIN_ROOT=<vault> node build-community-notes.mjs [name ...]
//         (default names: all graphify/* + graphify-out)
// Output is fully regenerated each run — never hand-edit the stubs.

import { readFileSync, writeFileSync, readdirSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const VAULT = process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();

// Obsidian/Windows-illegal filename chars; trailing dots/spaces break Windows.
const safeName = (name) => name.replace(/[\\/:*?"<>|#^[\]]/g, '-').replace(/[. ]+$/, '').trim();

// Resolve a target name to its on-disk dir, report path, and the report's wikilink
// basename (per-repo reports are namespaced <name>-GRAPH_REPORT; graphify-out's is the
// generic GRAPH_REPORT, which is unique so it doesn't collide).
function targetFor(name) {
  const dir = name === 'graphify-out' ? join(VAULT, 'graphify-out') : join(VAULT, 'graphify', name);
  const namespaced = join(dir, `${name}-GRAPH_REPORT.md`);
  const hasNs = existsSync(namespaced);
  return {
    name,
    dir,
    reportPath: hasNs ? namespaced : join(dir, 'GRAPH_REPORT.md'),
    backlink: hasNs ? `${name}-GRAPH_REPORT` : 'GRAPH_REPORT',
    graphPath: join(dir, 'graph.json'),
  };
}

const argNames = process.argv.slice(2);
let names = argNames.length
  ? argNames
  : (existsSync(join(VAULT, 'graphify'))
      ? readdirSync(join(VAULT, 'graphify'), { withFileTypes: true })
          .filter((d) => d.isDirectory())
          .map((d) => d.name)
      : []);
// default (no-arg) run also covers the vault's own wiki concept graph
if (!argNames.length && existsSync(join(VAULT, 'graphify-out', 'GRAPH_REPORT.md'))) names.push('graphify-out');

for (const name of names) {
  const { dir, reportPath, backlink, graphPath } = targetFor(name);
  if (!existsSync(reportPath) || !existsSync(graphPath)) {
    console.error(`skip ${name}: missing report or graph.json`);
    continue;
  }

  const report = readFileSync(reportPath, 'utf8');

  // "### Community N - "Name"" detail headings.
  const sections = [...report.matchAll(/^### Community (\d+) - "(.+?)"\s*\n(?:Cohesion: ([\d.]+))?/gm)];

  // Every [[_COMMUNITY_<target>|<label>]] link the report emits → label → target(s).
  const labelToTargets = new Map();
  for (const m of report.matchAll(/\[\[_COMMUNITY_([^\]|]+)(?:\|([^\]]+))?\]\]/g)) {
    const target = m[1].trim();
    const label = (m[2] ?? m[1]).trim();
    if (!labelToTargets.has(label)) labelToTargets.set(label, new Set());
    labelToTargets.get(label).add(target);
  }

  // community id -> member nodes from graph.json.
  const graph = JSON.parse(readFileSync(graphPath, 'utf8'));
  const members = new Map();
  for (const n of graph.nodes ?? []) {
    if (n.community === undefined || n.community === null) continue;
    if (!members.has(n.community)) members.set(n.community, []);
    members.get(n.community).push(n);
  }

  // Same name can label several community ids — merge into one note.
  const byName = new Map();
  for (const [, id, nm] of sections) {
    if (!byName.has(nm)) byName.set(nm, []);
    byName.get(nm).push({ id: Number(id) });
  }

  const outDir = join(dir, 'communities');

  // Prior stub identities: fileBase -> {label, members} read back from last run's
  // frontmatter, so this run can keep filenames stable under label churn.
  const prior = new Map();
  if (existsSync(outDir)) {
    for (const f of readdirSync(outDir)) {
      if (!f.endsWith('.md')) continue;
      const text = readFileSync(join(outDir, f), 'utf8');
      const fmMatch = text.match(/^---\n([\s\S]*?)\n---/);
      if (!fmMatch) continue;
      const listOf = (key) => {
        const m = fmMatch[1].match(new RegExp(`^${key}:\\s*\\n((?:[ \\t]*-[ \\t]*.*\\n?)+)`, 'm'));
        return m ? [...m[1].matchAll(/^[ \t]*-[ \t]*(.*)$/gm)].map((x) => x[1].trim().replace(/^"|"$/g, '')) : [];
      };
      const label = text.match(/^# (.+)$/m)?.[1]?.trim();
      prior.set(f.replace(/\.md$/, ''), { label, members: new Set(listOf('members')) });
    }
  }

  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });

  const nodeKey = (n) => String(n.name ?? n.label ?? n.id ?? '');
  const jaccard = (a, b) => {
    if (!a.size || !b.size) return 0;
    let hit = 0;
    for (const x of a) if (b.has(x)) hit++;
    return hit / (a.size + b.size - hit);
  };

  // Greedy best-first assignment of new communities to prior fileBases.
  const memberSets = new Map(); // rawName -> Set of member node keys
  for (const [rawName, ids] of byName) {
    memberSets.set(rawName, new Set(ids.flatMap(({ id }) => members.get(id) ?? []).map(nodeKey).filter(Boolean)));
  }
  const candidates = [];
  for (const [rawName, set] of memberSets)
    for (const [base, p] of prior) {
      const score = jaccard(set, p.members);
      if (score >= 0.5) candidates.push({ rawName, base, score, priorLabel: p.label });
    }
  candidates.sort((a, b) => b.score - a.score);
  const assigned = new Map(); // rawName -> {base, priorLabel}
  const usedBases = new Set();
  for (const c of candidates) {
    if (assigned.has(c.rawName) || usedBases.has(c.base)) continue;
    assigned.set(c.rawName, c);
    usedBases.add(c.base);
  }

  // resolvable = every name (filename basename + aliases) that an emitted stub answers to.
  const resolvable = new Set();
  let written = 0;

  const aliasesFor = (rawName, fileBase) => {
    const s = new Set();
    for (const t of labelToTargets.get(rawName) ?? []) s.add(`_COMMUNITY_${t}`);
    s.add(`_COMMUNITY_${rawName}`);
    s.delete(fileBase);
    return [...s];
  };
  const fmBlock = (ids, nodeCount, aliases, memberKeys = []) =>
    [
      '---', 'generated: true', 'generator: bin/build-community-notes.mjs',
      `repo: ${name}`, `community_ids: [${ids.join(', ')}]`, `node_count: ${nodeCount}`,
      ...(aliases.length ? ['aliases:', ...aliases.map((a) => `  - ${JSON.stringify(a)}`)] : []),
      ...(memberKeys.length ? ['members:', ...memberKeys.map((m) => `  - ${JSON.stringify(m)}`)] : []),
      '---',
    ].join('\n');
  // tiny alias re-reader so resolvable stays in sync with what we wrote
  const fmAliases = (fm) => {
    const m = fm.match(/^aliases:\s*\n((?:[ \t]*-[ \t]*.*\n?)+)/m);
    return m ? [...m[1].matchAll(/^[ \t]*-[ \t]*(.*)$/gm)].map((x) => x[1].trim().replace(/^"|"$/g, '')) : [];
  };
  const writeStub = (rawName, fileBase, fm, bodyMid) => {
    writeFileSync(join(outDir, `${fileBase}.md`), `${fm}\n\n# ${rawName}\n${bodyMid}\nSee [[${backlink}]] for the full graph picture.\n`);
    resolvable.add(fileBase);
    for (const a of fmAliases(fm)) resolvable.add(a);
    written++;
  };

  const graphRel = name === 'graphify-out' ? 'graphify-out/graph.json' : `graphify/${name}/graph.json`;

  // 1) rich stubs from detail headings
  for (const [rawName, ids] of byName) {
    const nodes = ids.flatMap(({ id }) => members.get(id) ?? []);
    const fileCounts = new Map();
    for (const n of nodes) if (n.source_file) fileCounts.set(n.source_file, (fileCounts.get(n.source_file) ?? 0) + 1);
    const topFiles = [...fileCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12);
    const match = assigned.get(rawName);
    const defaultBase = `_COMMUNITY_${safeName(rawName)}`;
    const fileBase = match ? match.base : defaultBase;
    const aliases = aliasesFor(rawName, fileBase);
    if (match) {
      // Keep the prior filename; the new label (and the naive base it would have
      // produced) resolve via aliases, as does the prior label if it changed.
      if (defaultBase !== fileBase && !aliases.includes(defaultBase)) aliases.push(defaultBase);
      if (match.priorLabel && match.priorLabel !== rawName) {
        const a = `_COMMUNITY_${match.priorLabel}`;
        if (a !== fileBase && !aliases.includes(a)) aliases.push(a);
      }
    }
    const fm = fmBlock(ids.map((i) => i.id), nodes.length, aliases, [...memberSets.get(rawName)].sort());
    const mid = `
> Auto-generated stub for graph community "${rawName}" (${name}). Do not hand-edit —
> regenerated by \`bin/build-community-notes.mjs\`. Source of truth: \`${graphRel}\`.

**Member nodes:** ${nodes.length} across ${fileCounts.size} files.

## Top files
${topFiles.map(([f, c]) => `- \`${f}\` (${c} nodes)`).join('\n') || '- (no file-backed members)'}
`;
    writeStub(rawName, fileBase, fm, mid);
  }

  // 2) minimal stubs for communities the report LINKS but never gave a heading
  let minimal = 0;
  for (const [label, targets] of labelToTargets) {
    if (byName.has(label)) continue; // already has a rich stub
    const fileBase = `_COMMUNITY_${safeName(label)}`;
    if (resolvable.has(fileBase) || existsSync(join(outDir, `${fileBase}.md`))) continue;
    const aliases = [...new Set([...[...targets].map((t) => `_COMMUNITY_${t}`), `_COMMUNITY_${label}`])].filter((a) => a !== fileBase);
    const fm = fmBlock([], 0, aliases);
    writeStub(label, fileBase, fm, `\n> Auto-generated stub for graph community "${label}" (${name}) — linked from the report without a detail section.\n`);
    minimal++;
  }

  console.log(`${name}: ${written} community notes (${byName.size} detailed + ${minimal} link-only)`);
}
