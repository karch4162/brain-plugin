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
//   5. hot.md over budget   — the rolling cache exceeds its word budget (accretion)
//   + missing/singleton tags, whole-vault graph connectivity (detached wiki
//     clusters + mirror islands), and all-generic community labels per mirror.
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
import { resolveRepos } from './resolve-repos.mjs';
import { execFileSync } from 'node:child_process';

/**
 * Does `path` exist at `rev` in the repo at `root`?
 *   true  — present at that revision
 *   false — revision is known, path is not in it
 *   null  — cannot tell (rev not fetched, git unavailable, not a repo)
 * The three-way return is the point: "I don't have that commit" must never be
 * reported as "that file is missing".
 */
function gitHas(root, rev, path) {
  const run = (args) => {
    try {
      execFileSync('git', ['-C', root, ...args], { stdio: 'ignore', timeout: 10000 });
      return true;
    } catch {
      return false;
    }
  };
  if (!run(['cat-file', '-e', `${rev}^{commit}`])) return null; // rev unknown locally
  return run(['cat-file', '-e', `${rev}:${path}`]);
}

const argv = process.argv.slice(2);
const argVal = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);

const VAULT = argVal('--vault') || process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
const HOME = process.env.HOME || process.env.USERPROFILE || '~';

const STALE_DAYS = Number(argVal('--stale-days')) || 45;
// hot.md targets ~500 words (see the save skill); flag past 1.5x so a slightly
// long-but-honest cache doesn't nag, while real accretion always trips it.
const HOT_MAX_WORDS = Number(argVal('--hot-max-words')) || 750;
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

// Preferred: the vault's repos.json identity map (name → remote + subPath),
// resolved per-repo against this machine. Handles repos that live at a sub-path
// of a shared checkout, and repos that do not share a parent directory at all —
// neither of which the REPOS_DIR-relative scan below can express. Read-only
// here: /brain:init and /brain:doctor own writing repos.local.json, so a scan
// never mutates the vault outside its own report.
const identity = resolveRepos(VAULT, [REPOS_DIR, join(VAULT, '..')]);
for (const [name, dir] of identity.paths) repoByName.set(name, dir);

// Fallback for vaults with no repos.json: the original REPOS_DIR-relative scan,
// keyed by folder name and by git remote. Kept so existing vaults keep working
// unchanged until they are seeded.
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

// Repos the vault claims to cover: graphify/ mirrors plus anything named in
// repos.json. A name here that did not resolve above is *unverifiable*, not rot.
const CLAIMED = [...new Set([...COVERED, ...Object.keys(identity.identity || {})])];

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
const unverifiableSources = [];
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

  // 4. source anchor — split "broken" (repo is here, file is gone) from
  //    "unverifiable" (no local checkout, so we genuinely cannot tell).
  //    Conflating the two makes an engineer who simply hasn't cloned a repo see
  //    every note for it reported as rot, and acting on that queue means
  //    re-anchoring notes that were already correct.
  // A note may assert that its source is intentionally not in git (a scratch
  // dir, a local-only config, a path the repo's .graphifyignore excludes as
  // secret-shaped). Absence is the documented fact, so checking it is wrong.
  const untracked = /^(true|yes)$/i.test(n.fm.source_untracked || '');
  if (n.fm.source && !untracked) {
    for (const srcRaw of n.fm.source.split(';')) {
      let src = srcRaw.trim().split('#')[0].trim().replace(/\s*\(.*$/, '');
      // Strip location suffixes that are NOT part of the filename:
      //   path@<rev>  a pinned commit/branch — verified against git below
      //   path:123    a line number in colon form (the #L123 form is already gone)
      // Without this they are stat'd as literal filenames and always "missing".
      let rev = null;
      const revM = src.match(/@([0-9a-fA-F]{7,40}|(?:refs\/|origin\/)[\w./-]+)$/);
      if (revM) { rev = revM[1]; src = src.slice(0, -revM[0].length); }
      src = src.replace(/:\d+(-\d+)?$/, '');
      // URLs (with or without a scheme — `github.com/org/repo/...` is a link, not
      // a path), and prose → skip.
      if (!src || /^https?:\/\//i.test(src) || /^[\w-]+(\.[\w-]+)+\//.test(src) || !src.includes('/')) continue;
      // Resolve against a covered repo root, else against the vault.
      let resolved = null;
      const firstSeg = src.split('/')[0];
      if (repoByName.has(firstSeg)) {
        resolved = join(repoByName.get(firstSeg), src.split('/').slice(1).join('/'));
      } else if (CLAIMED.includes(firstSeg)) {
        // The vault claims this repo (a graphify/ mirror and/or a repos.json
        // entry) but no checkout of it resolved on this machine. The mirror and
        // the identity map travel with the vault; the checkout does not. Absence
        // of the file here is evidence of nothing — do not call it rot.
        unverifiableSources.push({ from: rel, source: src, repo: firstSeg });
        continue;
      } else if (existsSync(join(VAULT, src))) {
        resolved = join(VAULT, src);
      } else {
        // try each covered repo as the implicit root
        for (const repo of COVERED) {
          if (existsSync(join(REPOS_DIR, repo, src))) { resolved = join(REPOS_DIR, repo, src); break; }
        }
      }
      if (!resolved) {
        // Nothing claimed this anchor's first segment — it names a repo the vault
        // has no mirror and no repos.json entry for. Previously this was dropped
        // in silence, so a report could look clean while anchors went unchecked.
        // Surface it: unverifiable, with the fix being a repos.json entry.
        unverifiableSources.push({ from: rel, source: src, repo: firstSeg, reason: 'unknown' });
        continue;
      }
      if (rev) {
        // A pinned revision is a claim about git history, not the working tree —
        // the file may legitimately be absent from the current branch (an
        // unmerged feature branch is exactly why anchors get pinned). Ask git.
        const m = identity.meta.get(firstSeg);
        if (!m) { unverifiableSources.push({ from: rel, source: srcRaw.trim(), repo: firstSeg, reason: 'unknown' }); continue; }
        const inRepo = [m.subPath, src.split('/').slice(1).join('/')].filter(Boolean).join('/');
        const seen = gitHas(m.root, rev, inRepo);
        if (seen === null)
          // Rev not present locally (never fetched, or pruned). Cannot be judged.
          unverifiableSources.push({ from: rel, source: srcRaw.trim(), repo: firstSeg, reason: 'rev' });
        else if (!seen)
          brokenSources.push({ from: rel, source: srcRaw.trim(), looked: `${inRepo} @ ${rev}` });
        continue;
      }
      if (!existsSync(resolved))
        brokenSources.push({ from: rel, source: src, looked: relative(VAULT, resolved).replace(/\\/g, '/') });
    }
  }
}

// ---- hot.md word budget --------------------------------------------------------
// hot.md is a *rolling* cache: /brain:save must replace stale bullets, not append.
// A vault where saves accrete "prior session" bullets balloons the file, and every
// save re-extracts it into the wiki concept graph — so bloat taxes every session.
const hotBloat = [];
{
  const hotPath = join(VAULT, 'wiki', 'hot.md');
  if (existsSync(hotPath)) {
    const words = readFileSync(hotPath, 'utf8').split(/\s+/).filter(Boolean).length;
    if (words > HOT_MAX_WORDS) hotBloat.push({ words, max: HOT_MAX_WORDS });
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
// The "main" component is the largest one that actually contains a wiki note —
// NOT simply the largest. A graph mirror can out-size the wiki (400+ community
// stubs) while containing zero knowledge; treating it as main flagged the entire
// wiki as a "detached cluster" on 2026-07-25. If the overall-largest component
// has no wiki notes it's a mirror island: report that as its own finding.
const mainIdx = components.findIndex((c) => c.some(isKnowledge));
const detachedKnowledge = components.filter((c, i) => i !== mainIdx && c.some(isKnowledge));
const mirrorIslands = mainIdx > 0 ? components.slice(0, mainIdx) : [];
const commGhosts = [...ghostTargets].filter((t) => t.startsWith('_COMMUNITY_'));

// ---- generic community labels -------------------------------------------------
// A mirror whose report headings are all "Community N" means the graph was only
// ever built by the no-LLM hook and the labeling pass never ran — the stubs are
// unreadable and the mirror can't bridge into the wiki. Flag per repo.
const genericLabelRepos = [];
for (const repo of COVERED) {
  const rp = join(VAULT, 'graphify', repo, `${repo}-GRAPH_REPORT.md`);
  if (!existsSync(rp)) continue;
  const labels = [...readFileSync(rp, 'utf8').matchAll(/^### Community \d+ - "(.+?)"/gm)].map((m) => m[1]);
  if (labels.length && labels.every((l) => /^Community \d+$/.test(l)))
    genericLabelRepos.push({ repo, count: labels.length });
}

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
    (unverifiableSources.length ? ` · Unverifiable sources: ${unverifiableSources.length}` : '') +
    ` · No tags: ${noTags.length}` +
    ` · Detached wiki clusters: ${detachedKnowledge.length}` +
    (mirrorIslands.length ? ` · Mirror islands: ${mirrorIslands.length}` : '') +
    (genericLabelRepos.length ? ` · Unlabeled graphs: ${genericLabelRepos.length}` : '') +
    (hotBloat.length ? ` · hot.md over budget: ${hotBloat[0].words}w` : '') +
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
if (unverifiableSources.length) {
  const notCloned = unverifiableSources.filter((u) => !u.reason);
  const unknown = unverifiableSources.filter((u) => u.reason === 'unknown');
  const noRev = unverifiableSources.filter((u) => u.reason === 'rev');
  const names = (list) => [...new Set(list.map((u) => u.repo))].sort().map((r) => `\`${r}\``).join(', ');
  L.push(`## Unverifiable \`source:\` anchors (${unverifiableSources.length})`);
  L.push('');
  L.push(
    `_Not rot, and **not counted** in the review total — these could not be checked either way. ` +
      `Never resolve one by editing the note; fix the resolution and re-run._`
  );
  L.push('');
  if (notCloned.length) {
    L.push(
      `**No local checkout (${notCloned.length})** — ${names(notCloned)} ` +
        `${notCloned.length === 1 ? 'is' : 'are'} claimed by this vault (a \`graphify/\` mirror and/or a \`repos.json\` ` +
        `entry) but no checkout resolved on this machine. The mirror and the identity map travel with the vault; the ` +
        `checkout does not. Clone the repo, or run \`resolve-repos.mjs --write\` with \`REPOS_DIR\` pointed at where it lives.`
    );
    L.push('');
    for (const u of notCloned) L.push(`- [${u.from}](${u.from}) — \`${u.source}\` (repo \`${u.repo}\` not checked out)`);
    L.push('');
  }
  if (noRev.length) {
    L.push(
      `**Pinned revision not available locally (${noRev.length})** — the anchor pins a commit or branch this ` +
        `checkout does not have (never fetched, or pruned). The file may well exist at that revision, so this is ` +
        `**not** rot. \`git fetch\` the relevant remote and re-run to have these judged.`
    );
    L.push('');
    for (const u of noRev) L.push(`- [${u.from}](${u.from}) — \`${u.source}\``);
    L.push('');
  }
  if (unknown.length) {
    // Grouped, not enumerated: this bucket is usually a handful of *conventions*
    // affecting many notes at once, and a per-note dump of hundreds of lines is
    // the same unusable queue this whole split exists to prevent.
    const byPrefix = new Map();
    for (const u of unknown) (byPrefix.get(u.repo) ?? byPrefix.set(u.repo, []).get(u.repo)).push(u);
    L.push(
      `**Unrecognized repo prefix (${unknown.length} anchor(s), ${byPrefix.size} prefix(es))** — these name no ` +
        `\`graphify/\` mirror and no \`repos.json\` entry, so there is nothing to resolve them against. They were ` +
        `previously dropped in **silence**: never checked, never reported, so a clean-looking report could hide them. ` +
        `Fix by adding a \`repos.json\` entry for the prefix, or re-anchoring to a repo name the vault knows.`
    );
    L.push('');
    for (const [prefix, items] of [...byPrefix.entries()].sort((a, b) => b[1].length - a[1].length)) {
      L.push(`- \`${prefix}/…\` — **${items.length}** anchor(s), e.g. [${items[0].from}](${items[0].from}) → \`${items[0].source}\``);
    }
    L.push('');
  }
}
section('Notes missing `tags:`', noTags, (f) => `[${f}](${f})`);
const singletons = [...tagCounts.entries()].filter(([, ns]) => ns.length === 1).sort();
section('Singleton tags (used by one note — fold into the shared vocab or drop)', singletons, ([t, ns]) => `\`${t}\` — only on [${ns[0]}](${ns[0]})`);
if (noFrontmatter.length) section('Notes missing frontmatter', noFrontmatter, (f) => `[${f}](${f})`);
if (genericLabelRepos.length)
  section('Graph mirrors with all-generic community labels (labeling pass never ran)', genericLabelRepos, (g) =>
    `\`graphify/${g.repo}/\` — all ${g.count} communities are named "Community N". ` +
    `Run the \`/graphify\` skill's labeling pass in that repo (the no-LLM post-commit hook never labels), ` +
    `then resync the mirror and regenerate stubs.`);
if (hotBloat.length)
  section('`hot.md` over word budget', hotBloat, (h) =>
    `[wiki/hot.md](wiki/hot.md) is **${h.words} words** — target ≤ ~500 (flagged above ${h.max}). ` +
    `It has been accreting: rewrite "Current focus" down to what is actually current and drop prior-session bullets ` +
    `(they live in \`logs/\`). Bloat here re-extracts into the concept graph on every \`/brain:save\`.`);

// Graph connectivity (Obsidian-style, whole vault). Detached wiki clusters are
// real issues; ghost nodes + non-knowledge detachment are informational.
L.push('## Graph connectivity');
L.push(
  `${allFiles.length} files · ${components.length} components · ` +
    `largest ${components[0]?.length ?? 0} (${allFiles.length ? Math.round((100 * (components[0]?.length ?? 0)) / allFiles.length) : 0}%) · ` +
    `${ghostTargets.size} unresolved link targets` +
    (commGhosts.length ? ` (${commGhosts.length} \`_COMMUNITY_*\` — should be 0; check the stub generator)` : '')
);
if (mirrorIslands.length) {
  L.push('');
  L.push(
    `⚠️ ${mirrorIslands.length} mirror island(s): component(s) larger than the wiki's that contain zero wiki notes. ` +
    `The mirror isn't bridged into the knowledge graph — usually generic community labels (see above) or missing ` +
    `\`Code:\` bridge links in the repo's stack-overview note.`
  );
  for (const c of mirrorIslands) {
    const sample = c.map((f) => relative(VAULT, f).replace(/\\/g, '/')).slice(0, 3).join(', ');
    L.push(`- [${c.length} files] e.g. ${sample}`);
  }
}
if (detachedKnowledge.length) {
  L.push('');
  L.push(`⚠️ ${detachedKnowledge.length} detached cluster(s) containing a wiki note:`);
  for (const c of detachedKnowledge)
    L.push(`- [${c.length} files] ${c.filter(isKnowledge).map((f) => basename(f, '.md')).slice(0, 6).join(', ')}`);
} else if (!mirrorIslands.length) {
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
  noFrontmatter.length + noTags.length + detachedKnowledge.length + hotBloat.length +
  mirrorIslands.length + genericLabelRepos.length;
L.push('---');
L.push(total === 0 ? '✅ Clean — no issues found.' : `⚠️ ${total} item(s) to review.`);
const report = L.join('\n') + '\n';

if (TO_STDOUT) {
  process.stdout.write(report);
} else {
  const out = join(VAULT, 'logs', `freshness-${date}.md`);
  writeFileSync(out, report, 'utf8');
  console.log(`Freshness report written: ${relative(VAULT, out).replace(/\\/g, '/')}`);
  console.log(
    `  ${total} issue(s) — dead:${deadLinks.length} orphan:${orphans.length} stale:${stale.length} src:${brokenSources.length}` +
      (unverifiableSources.length ? ` (+${unverifiableSources.length} unverifiable, no checkout)` : '')
  );
}
process.exit(0);
