#!/usr/bin/env node
// freshness.mjs — deterministic health check for a brain wiki ("lint the wiki").
//
// Implements the POC §8 "weekly freshness agent" mechanical layer. It does NOT
// delete or edit anything — it produces a *review queue* (markdown) that a human
// or agent triages. Checks:
//
//   1. Dead [[wikilinks]]   — a link target that resolves to no note / stub / report
//   2. Orphan notes         — a note nothing links to (not in index.md, not linked)
//   3. Stale last_verified  — frontmatter date older than --stale-days (default 45)
//   4. Broken source anchors— a `source:` file path that no longer exists on disk
//   + missing/singleton tags, and whole-vault graph connectivity.
//
// The VAULT is resolved from $BRAIN_ROOT (→ $CLAUDE_PROJECT_DIR → cwd) or --vault;
// the script lives in the plugin, not the vault. Covered repos are auto-derived from
// the vault's graphify/<repo>/ mirror folders (no hardcoded repo list).
//
// Usage:
//   BRAIN_ROOT=<vault> node freshness.mjs                 # full report -> logs/freshness-<date>.md
//   node freshness.mjs --vault <path> --stale-days 30
//   node freshness.mjs --stdout                           # print instead of writing a file
//   REPOS_DIR=~/code BRAIN_ROOT=<vault> node freshness.mjs # where covered repos live (default vault/..)
//
// Pure Node, no deps. Read-only except for the report file it writes.

import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { join, basename, relative } from 'node:path';

const argv = process.argv.slice(2);
const argVal = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);

const VAULT = argVal('--vault') || process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
const HOME = process.env.HOME || process.env.USERPROFILE || '~';

const STALE_DAYS = Number(argVal('--stale-days')) || 45;
const TO_STDOUT = argv.includes('--stdout');

if (!existsSync(join(VAULT, 'wiki'))) {
  console.error(`error: no wiki/ under '${VAULT}'. Set BRAIN_ROOT or pass --vault <path>.`);
  process.exit(1);
}

// Covered repos = the mirror folders under graphify/ (was a hardcoded list in the pilot).
const COVERED = existsSync(join(VAULT, 'graphify'))
  ? readdirSync(join(VAULT, 'graphify'), { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)
  : [];

// Where the covered repos are checked out. Never assume a fixed layout: honor an
// explicit REPOS_DIR, else auto-detect the two common layouts (repos one or two levels
// above the vault) by checking which actually contains a covered repo. Persist a real
// REPOS_DIR via /brain:init for anything non-standard.
const REPOS_DIR = resolveReposDir(VAULT, COVERED);
function resolveReposDir(vault, covered) {
  if (process.env.REPOS_DIR) return process.env.REPOS_DIR.replace(/^~/, HOME);
  for (const c of [join(vault, '..'), join(vault, '..', '..')]) {
    if (covered.some((r) => existsSync(join(c, r)))) return c;
  }
  return join(vault, '..');
}

// Canonical repo names → local checkout folder, read from each checkout's git
// remote. A `source:` anchor's first segment is a *repo name*, not a folder name —
// devs check the same repo out under different folders (store-hub vs edge after a
// rename), and broken-source results must not depend on whose laptop runs the scan.
const repoByName = new Map();
if (existsSync(REPOS_DIR)) {
  for (const e of readdirSync(REPOS_DIR, { withFileTypes: true })) {
    if (!e.isDirectory()) continue;
    const dir = join(REPOS_DIR, e.name);
    if (!repoByName.has(e.name)) repoByName.set(e.name, dir); // folder name always resolves
    const cfg = join(dir, '.git', 'config');
    if (existsSync(cfg)) {
      const m = readFileSync(cfg, 'utf8').match(/^\s*url\s*=\s*\S*?([^\/:]+?)(?:\.git)?\s*$/m);
      if (m && !repoByName.has(m[1])) repoByName.set(m[1], dir);
    }
  }
}

// ---- collect markdown files --------------------------------------------------
function walk(dir, acc = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}

// Obsidian doesn't render [[wikilinks]] inside code — strip fenced + inline code
// before extracting links so illustrative `[[_COMMUNITY_<Name>]]` in docs isn't a
// false ghost.
const stripCode = (t) => t.replace(/```[\s\S]*?```/g, '').replace(/`[^`\n]*`/g, '');
const wikilinks = (t) => [...stripCode(t).matchAll(/\[\[([^\]]+)\]\]/g)].map((m) => m[1].split('|')[0].split('#')[0].trim());
// Markdown-style links to .md files count too — /init seeds index.md with
// [title](area/note.md) lines, so only crediting [[wikilinks]] falsely orphans
// every indexed note. External URLs are skipped.
const mdNoteLinks = (t) =>
  [...stripCode(t).matchAll(/\]\(([^)\s]+\.md)(?:#[^)]*)?\)/g)]
    .map((m) => m[1])
    .filter((p) => !/^https?:\/\//i.test(p))
    .map((p) => basename(p, '.md'));
const allLinks = (t) => [...wikilinks(t), ...mdNoteLinks(t)];

const META_FILES = new Set(['index.md', 'hot.md', 'log.md']);
const wikiFiles = walk(join(VAULT, 'wiki'));
// Notes = every wiki/*.md except the catalog/cache/log files and any freshness report.
const notes = wikiFiles.filter(
  (f) => !META_FILES.has(basename(f)) && !basename(f).startsWith('freshness-')
);

// Valid link targets: note basenames + community stubs + per-repo graph reports.
const targetSet = new Set(notes.map((f) => basename(f, '.md')));
for (const repo of COVERED) {
  const cdir = join(VAULT, 'graphify', repo, 'communities');
  if (existsSync(cdir))
    for (const f of readdirSync(cdir)) if (f.endsWith('.md')) targetSet.add(basename(f, '.md'));
  targetSet.add(`${repo}-GRAPH_REPORT`);
}

// ---- parse frontmatter -------------------------------------------------------
function parseNote(file) {
  // Normalize CRLF→LF: notes may be mixed (Windows/Unix), and the regex anchors on \n.
  const text = readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const fm = {};
  const m = text.match(/^---\n([\s\S]*?)\n---/);
  if (m) {
    for (const line of m[1].split('\n')) {
      const kv = line.match(/^(\w[\w-]*):\s*(.*)$/);
      if (kv) fm[kv[1]] = kv[2].trim();
    }
  }
  const links = wikilinks(text);
  // tags: [a, b, c]  → ['a','b','c']
  const tags = fm.tags
    ? fm.tags.replace(/^\[|\]$/g, '').split(',').map((t) => t.trim()).filter(Boolean)
    : [];
  return { file, text, fm, links, tags };
}

const parsed = notes.map(parseNote);

// index.md + hot.md links count as inbound references for orphan detection.
const inbound = new Set();
for (const meta of ['index.md', 'hot.md']) {
  const p = join(VAULT, 'wiki', meta);
  if (existsSync(p)) for (const t of allLinks(readFileSync(p, 'utf8'))) inbound.add(t);
}
for (const n of parsed) for (const l of n.links) inbound.add(l);

// ---- checks ------------------------------------------------------------------
const today = new Date();
const deadLinks = [];
const orphans = [];
const stale = [];
const brokenSources = [];
const noFrontmatter = [];
const noTags = [];
const tagCounts = new Map(); // tag → [note rel paths]

for (const n of parsed) {
  const id = basename(n.file, '.md');
  const rel = relative(VAULT, n.file).replace(/\\/g, '/');

  // 1. dead links
  for (const l of n.links) {
    if (!targetSet.has(l)) deadLinks.push({ from: rel, target: l });
  }

  // frontmatter presence
  if (!n.fm.last_verified && !n.fm.id) {
    noFrontmatter.push(rel);
    continue;
  }

  // 2. orphan (no inbound link from index/hot/any note, excluding self)
  if (!inbound.has(id)) orphans.push(rel);

  // tags: missing + vocabulary tracking
  if (!n.tags.length) noTags.push(rel);
  for (const t of n.tags) {
    if (!tagCounts.has(t)) tagCounts.set(t, []);
    tagCounts.get(t).push(rel);
  }

  // 3. stale last_verified
  if (n.fm.last_verified) {
    const d = new Date(n.fm.last_verified);
    if (!isNaN(d)) {
      const ageDays = Math.floor((today - d) / 86400000);
      if (ageDays > STALE_DAYS)
        stale.push({ from: rel, date: n.fm.last_verified, age: ageDays });
    }
  }

  // 4. broken source anchor (best-effort, file-path sources only)
  if (n.fm.source) {
    for (const srcRaw of n.fm.source.split(';')) {
      const src = srcRaw.trim().split('#')[0].trim().replace(/\s*\(.*$/, '');
      if (!src || /^https?:\/\//i.test(src) || !src.includes('/')) continue; // URLs/prose → skip
      // Resolve against a covered repo root, else against the vault.
      let resolved = null;
      const firstSeg = src.split('/')[0];
      if (repoByName.has(firstSeg)) {
        resolved = join(repoByName.get(firstSeg), src.split('/').slice(1).join('/'));
      } else if (COVERED.includes(firstSeg)) {
        resolved = join(REPOS_DIR, src);
      } else if (existsSync(join(VAULT, src))) {
        resolved = join(VAULT, src);
      } else {
        // try each covered repo as the implicit root
        for (const repo of COVERED) {
          if (existsSync(join(REPOS_DIR, repo, src))) { resolved = join(REPOS_DIR, repo, src); break; }
        }
      }
      if (resolved && !existsSync(resolved))
        brokenSources.push({ from: rel, source: src, looked: relative(VAULT, resolved).replace(/\\/g, '/') });
    }
  }
}

// ---- whole-vault graph connectivity ------------------------------------------
// Model the vault like Obsidian's graph view: every .md is a node, every resolved
// [[link]] an edge. Links resolve via basename OR a frontmatter alias (community
// stubs carry aliases for graphify's report-link spelling). Flags any detached
// cluster that contains a real wiki note — genuine knowledge disconnection.
const SKIP_DIRS = new Set(['.git', '.obsidian', 'node_modules']);
function walkAll(dir, acc = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) walkAll(p, acc); }
    else if (e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}
function fileAliases(text) {
  const fm = text.match(/^---\n([\s\S]*?)\n---/);
  if (!fm) return [];
  const am = fm[1].match(/^aliases:\s*\n((?:[ \t]*-[ \t]*.*\n?)+)/m);
  if (!am) return [];
  return [...am[1].matchAll(/^[ \t]*-[ \t]*(.*)$/gm)].map((x) => x[1].trim().replace(/^["']|["']$/g, ''));
}
const allFiles = walkAll(VAULT);
const allText = new Map(allFiles.map((f) => [f, readFileSync(f, 'utf8').replace(/\r\n/g, '\n')]));
const nameToFile = new Map();
for (const f of allFiles) {
  if (!nameToFile.has(basename(f, '.md'))) nameToFile.set(basename(f, '.md'), f);
  for (const a of fileAliases(allText.get(f))) if (!nameToFile.has(a)) nameToFile.set(a, f);
}
const cAdj = new Map(allFiles.map((f) => [f, new Set()]));
const ghostTargets = new Set();
for (const f of allFiles) {
  for (const t of allLinks(allText.get(f))) {
    const tf = nameToFile.get(t);
    if (tf && tf !== f) { cAdj.get(f).add(tf); cAdj.get(tf).add(f); }
    else if (!tf) ghostTargets.add(t);
  }
}
const cSeen = new Set();
const components = [];
for (const f of allFiles) {
  if (cSeen.has(f)) continue;
  const stack = [f], comp = [];
  cSeen.add(f);
  while (stack.length) {
    const n = stack.pop();
    comp.push(n);
    for (const nb of cAdj.get(n)) if (!cSeen.has(nb)) { cSeen.add(nb); stack.push(nb); }
  }
  components.push(comp);
}
components.sort((a, b) => b.length - a.length);
const isKnowledge = (f) => {
  const r = relative(VAULT, f).replace(/\\/g, '/');
  return r.startsWith('wiki/') && !META_FILES.has(basename(f));
};
const detachedKnowledge = components.slice(1).filter((c) => c.some(isKnowledge));
const commGhosts = [...ghostTargets].filter((t) => t.startsWith('_COMMUNITY_'));

// ---- report ------------------------------------------------------------------
// Local date (matches the `date +%F` convention for notes/logs), not UTC —
// otherwise an evening run names the report "tomorrow".
const pad = (n) => String(n).padStart(2, '0');
const date = `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())}`;
const L = [];
L.push(`# Wiki freshness report — ${date}`);
L.push('');
L.push(`_Generated by \`bin/freshness.mjs\` (stale threshold: ${STALE_DAYS} days). Review queue, not auto-applied._`);
L.push('');
L.push(
  `**Scanned ${parsed.length} notes.** ` +
    `Dead links: ${deadLinks.length} · Orphans: ${orphans.length} · ` +
    `Stale (>${STALE_DAYS}d): ${stale.length} · Broken sources: ${brokenSources.length}` +
    ` · No tags: ${noTags.length}` +
    ` · Detached wiki clusters: ${detachedKnowledge.length}` +
    (noFrontmatter.length ? ` · No frontmatter: ${noFrontmatter.length}` : '')
);
L.push('');

function section(title, items, render) {
  L.push(`## ${title} (${items.length})`);
  if (!items.length) L.push('_None._');
  else for (const it of items) L.push(`- ${render(it)}`);
  L.push('');
}

section('Dead `[[wikilinks]]`', deadLinks, (d) => `\`${d.target}\` — linked from [${d.from}](${d.from}), resolves to nothing`);
section('Orphan notes (nothing links here)', orphans, (o) => `[${o}](${o})`);
section(`Stale notes (last_verified > ${STALE_DAYS}d)`, stale, (s) => `[${s.from}](${s.from}) — last_verified ${s.date} (${s.age}d old)`);
section('Broken `source:` anchors', brokenSources, (b) => `[${b.from}](${b.from}) — source \`${b.source}\` not found (looked: \`${b.looked}\`)`);
section('Notes missing `tags:`', noTags, (f) => `[${f}](${f})`);
const singletons = [...tagCounts.entries()].filter(([, ns]) => ns.length === 1).sort();
section('Singleton tags (used by one note — fold into the shared vocab or drop)', singletons, ([t, ns]) => `\`${t}\` — only on [${ns[0]}](${ns[0]})`);
if (noFrontmatter.length) section('Notes missing frontmatter', noFrontmatter, (f) => `[${f}](${f})`);

// Graph connectivity (Obsidian-style, whole vault). Detached wiki clusters are
// real issues; ghost nodes + non-knowledge detachment are informational.
L.push('## Graph connectivity');
L.push(
  `${allFiles.length} files · ${components.length} components · ` +
    `largest ${components[0]?.length ?? 0} (${allFiles.length ? Math.round((100 * (components[0]?.length ?? 0)) / allFiles.length) : 0}%) · ` +
    `${ghostTargets.size} unresolved link targets` +
    (commGhosts.length ? ` (${commGhosts.length} \`_COMMUNITY_*\` — should be 0; check the stub generator)` : '')
);
if (detachedKnowledge.length) {
  L.push('');
  L.push(`⚠️ ${detachedKnowledge.length} detached cluster(s) containing a wiki note:`);
  for (const c of detachedKnowledge)
    L.push(`- [${c.length} files] ${c.filter(isKnowledge).map((f) => basename(f, '.md')).slice(0, 6).join(', ')}`);
} else {
  L.push('All wiki notes are in the main connected component. ✅');
}
L.push('');

// Tag landscape (informational, not an issue count).
const landscape = [...tagCounts.entries()].sort((a, b) => b[1].length - a[1].length);
L.push('## Tag landscape (cross-cutting first)');
L.push(landscape.length ? landscape.map(([t, ns]) => `\`${t}\`×${ns.length}`).join(' · ') : '_No tags._');
L.push('');

const total =
  deadLinks.length + orphans.length + stale.length + brokenSources.length +
  noFrontmatter.length + noTags.length + detachedKnowledge.length;
L.push('---');
L.push(total === 0 ? '✅ Clean — no issues found.' : `⚠️ ${total} item(s) to review.`);
const report = L.join('\n') + '\n';

if (TO_STDOUT) {
  process.stdout.write(report);
} else {
  const out = join(VAULT, 'logs', `freshness-${date}.md`);
  writeFileSync(out, report, 'utf8');
  console.log(`Freshness report written: ${relative(VAULT, out).replace(/\\/g, '/')}`);
  console.log(`  ${total} issue(s) — dead:${deadLinks.length} orphan:${orphans.length} stale:${stale.length} src:${brokenSources.length}`);
}
process.exit(0);
