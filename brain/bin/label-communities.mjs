#!/usr/bin/env node
// label-communities.mjs — vault-side community labeling, the mechanical halves.
//
// THE PROBLEM THIS SOLVES (INNOV-251 Part B)
// A mirror's graph.json carries a numeric `community` on every node, but names
// live only in <repo>-GRAPH_REPORT.md — and most mirrors were seeded keyless,
// so their communities are "Community N" placeholders (or there is no report at
// all, which is strictly worse: no community stubs, nothing queryable). The old
// remediation — relabel in the repo, then resync the mirror — required every
// covered repo checked out AND was destructive: a keyless resync replaces named
// stubs with placeholders (the documented tray_pos_flutter incident).
//
// Naming a community is a pure function of mirror data: the node labels and
// source_file paths in each cluster. No checkout needed. But the naming itself
// is LLM work, so it follows the brain's host-session split (see save 5c):
//
//   THIS SCRIPT (mechanical)          THE /brain:label SKILL (LLM, host session)
//   --digest → work order JSON    →   agent names each batch, 2-5 words each
//   --apply  ← {id: label} JSON   ←   writes the labels file
//
// `graphify label` is deliberately NOT used: it has no host-session mode — with
// no API key it silently degrades to placeholders, i.e. it reproduces the
// incident this feature exists to prevent. It also re-clusters as a side effect
// and writes to <path>/graphify-out/, never in place.
//
// GUARANTEES
//   - An existing non-generic label is never changed (preserved > agent > derived).
//   - graph.json is never written. communities/ is never written — that dir is
//     owned (and wholesale-regenerated) by build-community-notes.mjs.
//   - An existing report is transformed IN PLACE: only generic headings and hub
//     links change; every other line survives byte-identical. Communities the
//     report omitted (thin ones) are appended in their own section.
//   - Deterministic: same graph + same labels file → same report.
//
// Usage:
//   BRAIN_ROOT=<vault> node label-communities.mjs --digest [repo ...] [--top N]
//   BRAIN_ROOT=<vault> node label-communities.mjs --apply <repo> --labels <file.json>
//
// --digest prints a JSON work order per repo:
//   { repo, total, preserved: {id: label}, derived: {id: name},
//     batches: [[ "Community <id> (<n> nodes): lbl1, lbl2 | files: f1, f2" ]] }
// The top K unnamed communities (by node count, default 100) go to the agent in
// batches of <=100 (graphify's own label batch size); the tail gets a derived
// name here — dominant source file/dir — so no placeholder is left behind.
//
// Pure Node, no deps.

import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { foldLabel, nameKey } from './community-name.mjs';

const argv = process.argv.slice(2);
const argVal = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);
const VAULT = process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();

const TOP_K = Number(argVal('--top')) || 100;
const BATCH = 100; // graphify _LABEL_BATCH_SIZE — sized for one naming pass per response
const GENERIC = /^Community \d+$/;
const HEADING = /^### Community (\d+) - "(.+?)"/gm; // same regex as build-community-notes + freshness

// Labels must survive the fold that build-community-notes applies to filenames,
// and the heading's `"…"` delimiters. Both scripts import the SAME fold from
// community-name.mjs — see that file for why a local copy is a bug factory.
const sanitizeLabel = foldLabel;

// A label is also an identity: build-community-notes MERGES every community
// sharing a label into one stub note, and the filesystem/Obsidian treat names
// that differ only by case as the same name. So a minted label that collides
// with one already taken must be made distinct HERE, in the report — by the time
// the stub generator sees two case-colliding labels the ambiguity is already
// baked into the report's [[links]] and cannot be undone downstream.
// (This is how "Close Day BLoC" and "Close Day Bloc" ended up as two communities
// whose report links both pointed at one note.)
function uniqueLabel(label, taken) {
  let cand = label, i = 2;
  while (taken.has(nameKey(cand))) cand = `${label} (${i++})`;
  taken.add(nameKey(cand));
  return cand;
}

// ---- mirror reading ----------------------------------------------------------

function mirrorNames() {
  const dir = join(VAULT, 'graphify');
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isDirectory() && existsSync(join(dir, d.name, 'graph.json')))
    .map((d) => d.name);
}

function readMirror(repo) {
  const dir = join(VAULT, 'graphify', repo);
  const graph = JSON.parse(readFileSync(join(dir, 'graph.json'), 'utf8'));
  const nodes = graph.nodes ?? [];
  const links = graph.links ?? []; // NetworkX node-link: edges live under `links`
  const members = new Map(); // community id (number) → node[]
  for (const n of nodes) {
    if (n.community === undefined || n.community === null) continue;
    if (!members.has(n.community)) members.set(n.community, []);
    members.get(n.community).push(n);
  }
  // Degree ranks a community's member labels for the naming prompt — hubs first,
  // the same idea as graphify's god-nodes-first ordering.
  const degree = new Map();
  for (const l of links) {
    degree.set(l.source, (degree.get(l.source) ?? 0) + 1);
    degree.set(l.target, (degree.get(l.target) ?? 0) + 1);
  }
  const reportPath = join(dir, `${repo}-GRAPH_REPORT.md`);
  const report = existsSync(reportPath) ? readFileSync(reportPath, 'utf8') : null;
  const reportLabels = new Map(); // id (number) → label as written
  if (report !== null)
    for (const m of report.matchAll(HEADING)) reportLabels.set(Number(m[1]), m[2]);
  return { dir, reportPath, report, reportLabels, members, degree, nodeCount: nodes.length, linkCount: links.length };
}

// ---- naming inputs -----------------------------------------------------------

const nodeKey = (n) => String(n.name ?? n.label ?? n.id ?? ''); // same identity as build-community-notes

function topFiles(nodes, k = 3) {
  const byFile = new Map();
  for (const n of nodes) {
    const f = n.source_file;
    if (!f) continue;
    byFile.set(f, (byFile.get(f) ?? 0) + 1);
  }
  return [...byFile.entries()].sort((a, b) => b[1] - a[1]).slice(0, k).map(([f]) => f);
}

function promptLine(id, nodes, degree) {
  const seen = new Set();
  const labels = [];
  for (const n of [...nodes].sort((a, b) => (degree.get(b.id) ?? 0) - (degree.get(a.id) ?? 0))) {
    const l = String(n.label ?? n.id ?? '').slice(0, 60);
    const key = l.toLowerCase();
    if (!l || seen.has(key)) continue;
    seen.add(key);
    labels.push(l);
    if (labels.length >= 12) break;
  }
  const files = topFiles(nodes);
  return `Community ${id} (${nodes.length} nodes): ${labels.join(', ')}` + (files.length ? ` | files: ${files.join(', ')}` : '');
}

// Derived name for the tail: the dominant source file's basename (sans
// extension), else its directory — deduped case-insensitively against every
// label already taken, so a derived name never silently merges into an
// existing community note (build-community-notes merges same-label ids).
function deriveName(nodes, taken) {
  const files = topFiles(nodes, 1);
  let base = '';
  if (files.length) {
    const parts = files[0].replace(/\\/g, '/').split('/');
    base = parts[parts.length - 1].replace(/\.[^.]+$/, '');
    if (!base) base = parts[parts.length - 2] ?? '';
    const uniq = (c) => !taken.has(nameKey(c));
    if (!uniq(sanitizeLabel(base)) && parts.length > 1) base = `${parts[parts.length - 2]} ${base}`;
  }
  if (!base) base = nodeKey(nodes[0]) || 'cluster';
  return uniqueLabel(sanitizeLabel(base) || 'cluster', taken);
}

// Split one mirror's communities into preserved / to-name / derived.
function classify(repo, m) {
  const preserved = {}; // id → existing non-generic label (never touched)
  const unnamed = [];   // ids needing a label (generic heading, or absent from report)
  for (const [id, nodes] of m.members) {
    const existing = m.reportLabels.get(id);
    if (existing !== undefined && !GENERIC.test(existing)) preserved[id] = existing;
    else unnamed.push({ id, nodes });
  }
  unnamed.sort((a, b) => b.nodes.length - a.nodes.length);
  const llm = unnamed.slice(0, TOP_K);
  const tail = unnamed.slice(TOP_K);
  const taken = new Set(Object.values(preserved).map((l) => nameKey(l)));
  const derived = {};
  for (const { id, nodes } of tail) derived[id] = deriveName(nodes, taken);
  const batches = [];
  for (let i = 0; i < llm.length; i += BATCH)
    batches.push(llm.slice(i, i + BATCH).map(({ id, nodes }) => promptLine(id, nodes, m.degree)));
  return { repo, total: m.members.size, preserved, derived, batches };
}

// ---- report writing ----------------------------------------------------------

const hubLink = (label) => `[[_COMMUNITY_${label}|${label}]]`; // raw label — build-community-notes aliases it to the sanitized filename

function transformReport(m, finalLabels) {
  // In-place: rename generic headings + their hub links; append omitted ids.
  let text = m.report;
  const appended = [];
  for (const [idStr, label] of Object.entries(finalLabels)) {
    const id = Number(idStr);
    const existing = m.reportLabels.get(id);
    if (existing !== undefined && !GENERIC.test(existing)) continue; // preserved — never touched
    if (existing === undefined) { appended.push([id, label]); continue; } // thin/omitted → appended section
    const old = `Community ${id}`;
    text = text.replaceAll(`### ${old} - "${old}"`, `### ${old} - "${label}"`);
    text = text.replaceAll(`[[_COMMUNITY_${old}|${old}]]`, hubLink(label));
  }
  if (appended.length) {
    appended.sort((a, b) => (m.members.get(b[0])?.length ?? 0) - (m.members.get(a[0])?.length ?? 0));
    const L = ['', '## Additional communities (labeled vault-side)', ''];
    for (const [id, label] of appended) {
      const nodes = m.members.get(id) ?? [];
      L.push(`### Community ${id} - "${label}"`);
      L.push(`Nodes (${nodes.length}): ${nodes.slice(0, 12).map(nodeKey).join(', ')}${nodes.length > 12 ? ` (+${nodes.length - 12} more)` : ''}`);
      L.push('');
    }
    text = text.replace(/\n*$/, '\n') + L.join('\n') + '\n';
  }
  return text;
}

function generateReport(repo, m, finalLabels, date) {
  const ids = [...m.members.keys()].sort((a, b) => m.members.get(b).length - m.members.get(a).length);
  const L = [];
  L.push(`# Graph Report - graphify/${repo}/graph.json  (labeled vault-side ${date})`);
  L.push('## Summary');
  L.push(`- ${m.nodeCount} nodes · ${m.linkCount} edges · ${m.members.size} communities`);
  L.push('## Community Hubs (Navigation)');
  for (const id of ids.slice(0, 30)) L.push(`- ${hubLink(finalLabels[id])}`);
  L.push('## Communities');
  for (const id of ids) {
    const nodes = m.members.get(id);
    L.push(`### Community ${id} - "${finalLabels[id]}"`);
    L.push(`Nodes (${nodes.length}): ${nodes.slice(0, 12).map(nodeKey).join(', ')}${nodes.length > 12 ? ` (+${nodes.length - 12} more)` : ''}`);
    L.push('');
  }
  return L.join('\n') + '\n';
}

// ---- CLI ---------------------------------------------------------------------

if (!existsSync(join(VAULT, 'graphify'))) {
  console.error(`error: no graphify/ under '${VAULT}'. Set BRAIN_ROOT or run from the vault.`);
  process.exit(1);
}

if (argv.includes('--digest')) {
  const names = argv.filter((a) => !a.startsWith('--') && a !== argVal('--top'));
  const repos = names.length ? names : mirrorNames();
  const out = [];
  for (const repo of repos) {
    if (!existsSync(join(VAULT, 'graphify', repo, 'graph.json'))) {
      console.error(`skip ${repo}: no graph.json`);
      continue;
    }
    out.push(classify(repo, readMirror(repo)));
  }
  console.log(JSON.stringify(out, null, 2));
  process.exit(0);
}

if (argv.includes('--apply')) {
  const repo = argv[argv.indexOf('--apply') + 1];
  const labelsFile = argVal('--labels');
  if (!repo || repo.startsWith('--') || !labelsFile) {
    console.error('usage: label-communities.mjs --apply <repo> --labels <file.json>');
    process.exit(1);
  }
  const m = readMirror(repo);
  const agent = JSON.parse(readFileSync(labelsFile, 'utf8'));
  // Merge preserved > agent > derived. Preserved labels are re-read fresh from
  // the report (never trusted from a stale digest); any unnamed id the agent
  // didn't cover — the tail, or an invalid entry — gets a derived name here,
  // deterministically, largest community first.
  const { preserved } = classify(repo, m);
  const finalLabels = {};
  const taken = new Set(Object.values(preserved).map((l) => nameKey(l)));
  let named = 0, invalid = 0, collided = 0;
  const bySize = [...m.members.keys()].sort((a, b) => m.members.get(b).length - m.members.get(a).length);
  for (const id of bySize) {
    if (preserved[id] !== undefined) { finalLabels[id] = preserved[id]; continue; }
    const raw = agent[id] ?? agent[String(id)];
    const clean = sanitizeLabel(raw);
    if (clean && !GENERIC.test(clean)) {
      // Case-insensitive: an agent label that only differs in case from one
      // already taken is the same stub filename, so it must be disambiguated.
      const uniqued = uniqueLabel(clean, taken);
      if (uniqued !== clean) collided++;
      finalLabels[id] = uniqued;
      named++;
    } else {
      if (raw !== undefined) invalid++;
      finalLabels[id] = deriveName(m.members.get(id), taken);
    }
  }
  const pad = (n) => String(n).padStart(2, '0');
  const today = new Date();
  const date = `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())}`;
  const text = m.report !== null ? transformReport(m, finalLabels) : generateReport(repo, m, finalLabels, date);
  writeFileSync(m.reportPath, text, 'utf8');
  console.log(
    `${repo}: ${m.members.size} communities — ${Object.keys(preserved).length} preserved, ` +
      `${named} agent-named, ${m.members.size - Object.keys(preserved).length - named} derived` +
      (invalid ? ` (${invalid} agent label(s) invalid/generic → derived fallback)` : '') +
      (collided ? ` (${collided} agent label(s) collided case-insensitively → suffixed)` : '') +
      ` → ${m.reportPath.replace(/\\/g, '/')}`
  );
  console.log(`next: BRAIN_ROOT="${VAULT}" node build-community-notes.mjs ${repo}   # regenerate stubs`);
  process.exit(0);
}

console.error('usage: label-communities.mjs --digest [repo ...] [--top N] | --apply <repo> --labels <file.json>');
process.exit(1);
