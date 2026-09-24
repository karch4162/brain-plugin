#!/usr/bin/env node
// check-anchors.mjs — can this note's `source:` anchor be VERIFIED on THIS machine?
//
// The /brain:promote gate. Promotion turns a draft into a trusted note, and the
// whole claim to trust is the `source:` anchor: the file, PR or commit that makes
// the fact true. On 2026-08-04 nine notes were promoted to trusted with
// `source: repo-b/docs/…` anchors that could not resolve on the promoting machine.
// Nothing stopped it, because "verify the anchor resolves" was PROSE in a skill
// file — and prose drifts. This script is the mechanical form of that rule.
//
// It does NOT hard-block on an anchor it merely could not check. The point is to
// make promoting an unverifiable note a CONSCIOUS CHOICE rather than an accident:
// the count is printed, the notes are named, the repos they need are named, and
// the human decides. A genuinely BROKEN anchor is different — the repo is right
// here and the file is not — so that one is a stop.
//
// The classification is NOT implemented here. It is imported verbatim from
// anchors.mjs, which brain/bin/freshness.mjs also uses, so the promote gate and
// the weekly freshness report can never disagree about whether an anchor
// resolves. Two implementations of one resolver is the defect.
//
// The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
// falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in
// the plugin, NOT inside the vault, so it cannot derive the vault from its own
// location.
//
// Usage:
//   BRAIN_ROOT=<vault> node check-anchors.mjs                     # defaults to wiki/_drafts/
//   BRAIN_ROOT=<vault> node check-anchors.mjs wiki/_drafts/a.md wiki/_drafts/b.md
//   node check-anchors.mjs --vault <path> wiki/sports-management/
//   REPOS_DIR=~/code BRAIN_ROOT=<vault> node check-anchors.mjs    # where covered repos live
//
// Paths may be files or directories (directories are walked for *.md), absolute
// or vault-relative.
//
// Contract (the /brain:promote skill and its tests depend on exactly this):
//   exit 0  => ANCHORS: OK          — every anchor checked verified. Promote freely.
//   exit 1  => ANCHORS: BROKEN      — at least one anchor is rot: its repo IS here
//                                     and the file is NOT, or it resolves into a
//                                     different repo than the note's own area.
//                                     Re-anchor the note; do not promote it as is.
//   exit 2  => ANCHORS: UNVERIFIABLE — nothing is broken, but at least one anchor
//                                     could not be checked here (no checkout,
//                                     unknown repo prefix, unfetched pinned rev,
//                                     off-machine PR/URL) or a note carries no
//                                     `source:` at all. ADVISORY: promote may
//                                     proceed once the user says so.
// The FIRST line of output always starts with `ANCHORS: OK` (stdout) or
// `ANCHORS: BROKEN` / `ANCHORS: UNVERIFIABLE` (stderr), so a caller can branch on
// it without parsing prose. ALL FOUR COUNTS APPEAR ON EVERY PATH — verified,
// broken, unverifiable, no-source — so the numbers are visible whether or not
// anyone reads past the first line.
//
// Missing preconditions are never failures (same stance as check-freshness.sh
// and check-hot-budget.sh): no wiki/, no wiki/_drafts/, a path that does not
// exist, or zero notes to check all report OK and exit 0. This is a gate against
// promoting unverifiable claims, not a file-existence assertion.
//
// Pure Node, no deps. Read-only: it never edits a note, never writes a file,
// never commits, never reaches the network.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, relative, isAbsolute, resolve } from 'node:path';
import { buildAnchorContext, classifyAnchors, parseFrontmatter } from './anchors.mjs';

const argv = process.argv.slice(2);
const argVal = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);

const VAULT = argVal('--vault') || process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
const targets = argv.filter((a, i) => !a.startsWith('--') && argv[i - 1] !== '--vault');

const ok = (line, extra = []) => {
  console.log(line);
  for (const l of extra) console.log(l);
  process.exit(0);
};

// ---- collect the notes to check ---------------------------------------------
function walk(dir, acc = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}

const roots = (targets.length ? targets : ['wiki/_drafts']).map((t) =>
  isAbsolute(t) ? resolve(t) : resolve(join(VAULT, t))
);

const files = [];
const missingPaths = [];
for (const r of roots) {
  if (!existsSync(r)) { missingPaths.push(r); continue; }
  if (statSync(r).isDirectory()) files.push(...walk(r));
  else if (r.endsWith('.md')) files.push(r);
}
const notes = [...new Set(files)].sort();

if (!notes.length)
  ok(
    `ANCHORS: OK - 0 note(s), 0 anchor(s): 0 verified, 0 broken, 0 unverifiable, 0 note(s) with no source: — nothing to check`,
    missingPaths.length
      ? [`  note: no such path: ${missingPaths.map((p) => rel(p)).join(', ')} (a vault with no drafts is not a failure)`]
      : []
  );

function rel(p) {
  const r = relative(VAULT, p).replace(/\\/g, '/');
  return r.startsWith('..') ? p.replace(/\\/g, '/') : r;
}

// ---- classify ----------------------------------------------------------------
const ctx = buildAnchorContext(VAULT);

const verified = [];
const broken = [];       // rot: the repo is here, the file is not
const mismatch = [];     // resolves into a different repo than the note's area
const unresolvable = []; // could not check, either way
const untracked = [];    // `source_untracked: true` — absence is the documented fact
const noSource = [];     // no `source:` line at all

for (const f of notes) {
  const r = rel(f);
  const fm = parseFrontmatter(readFileSync(f, 'utf8'));
  const results = classifyAnchors(ctx, { rel: r, source: fm.source, sourceUntracked: fm.source_untracked });
  if (!results.length) { noSource.push(r); continue; }
  for (const a of results) {
    if (a.state === 'verified') verified.push(a);
    else if (a.state === 'broken') broken.push(a);
    else if (a.state === 'mismatch') mismatch.push(a);
    else if (a.state === 'untracked') untracked.push(a);
    else unresolvable.push(a);
  }
}

const anchorCount = verified.length + broken.length + mismatch.length + unresolvable.length + untracked.length;
const counts =
  `${notes.length} note(s), ${anchorCount} anchor(s): ` +
  `${verified.length} verified, ${broken.length + mismatch.length} broken, ` +
  `${unresolvable.length} unverifiable, ${noSource.length} note(s) with no source:` +
  (untracked.length ? ` (+${untracked.length} declared source_untracked)` : '');

// ---- detail blocks -----------------------------------------------------------
// Named notes and named repos, always — "N unverifiable" with no names is a
// number nobody can act on, and acting on it is the entire point.
const REASON_FIX = {
  'no-checkout': 'claimed by this vault (a graphify/ mirror and/or a repos.json entry) but not checked out here — clone it, or run resolve-repos.mjs --write with REPOS_DIR pointed at where it lives',
  unknown: 'names no graphify/ mirror and no repos.json entry — add a repos.json entry for the prefix, or re-anchor to a repo name the vault knows',
  rev: 'pins a commit or branch this clone does not have (never fetched, or pruned) — git fetch the remote and re-run',
  external: 'points off this machine (a PR or URL) — nothing local can judge it; check it by hand before trusting the note',
};

function unresolvableBlock() {
  const lines = [];
  const byReason = new Map();
  for (const u of unresolvable) (byReason.get(u.reason) ?? byReason.set(u.reason, []).get(u.reason)).push(u);
  for (const [reason, items] of byReason) {
    const repos = [...new Set(items.map((u) => u.repo).filter(Boolean))].sort();
    lines.push(`  ${items.length} unverifiable (${reason}): ${REASON_FIX[reason] || reason}`);
    if (repos.length) lines.push(`    repo(s) needed: ${repos.join(', ')}`);
    for (const u of items) lines.push(`    - ${u.from} — source: ${u.source}`);
  }
  return lines;
}

function brokenBlock() {
  const lines = [];
  for (const b of broken) lines.push(`  - ${b.from} — source: ${b.source} (looked: ${rel(b.looked)})`);
  for (const m of mismatch)
    lines.push(
      `  - ${m.from} — source: ${m.source} resolves into '${m.repo}'s repo, but the note lives in wiki/${m.area}/ ` +
        `(qualify the anchor as <repo>/<path>; the file was NOT checked either way)`
    );
  return lines;
}

const noSourceBlock = () => noSource.map((n) => `  - ${n} — no source: anchor at all`);

// ---- verdict — the counts are printed on EVERY path --------------------------
if (!broken.length && !mismatch.length && !unresolvable.length && !noSource.length)
  ok(`ANCHORS: OK - ${counts}`);

if (broken.length || mismatch.length) {
  const out = [`ANCHORS: BROKEN - ${counts}`];
  out.push(`  These anchors are rot: the repo IS present on this machine and the file is not.`);
  out.push(...brokenBlock());
  if (unresolvable.length) { out.push(`  Also could not be checked here:`); out.push(...unresolvableBlock()); }
  if (noSource.length) { out.push(`  Also carrying no anchor at all:`); out.push(...noSourceBlock()); }
  out.push(`  Remedy: re-anchor each note to where the fact actually lives now, then re-run:`);
  out.push(`    BRAIN_ROOT="${VAULT}" node check-anchors.mjs ${targets.join(' ')}`.trimEnd());
  out.push(`  Do not promote a note whose anchor is broken — the trusted tier's only claim to trust is the anchor.`);
  console.error(out.join('\n'));
  process.exit(1);
}

{
  const out = [`ANCHORS: UNVERIFIABLE - ${counts}`];
  out.push(`  Nothing is broken. These could not be checked on THIS machine, either way —`);
  out.push(`  absence of a local checkout is evidence of nothing, so none of this is rot.`);
  if (unresolvable.length) out.push(...unresolvableBlock());
  if (noSource.length) { out.push(`  Notes with no anchor at all (promote requires one):`); out.push(...noSourceBlock()); }
  out.push(`  Promoting these is allowed — but say so out loud first: it is a choice, not an oversight.`);
  console.error(out.join('\n'));
  process.exit(2);
}
