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
//   - An existing report is transformed IN PLACE: only generic headings, STALE
//     headings (a name whose stated members no longer match graph.json's cluster
//     for that id — see isStale) plus their member lines, and hub links change;
//     every other line survives byte-identical. Communities the report omitted
//     (thin ones) are appended in their own section.
//   - Deterministic: same graph + same labels file → same report.
//
// Usage:
//   BRAIN_ROOT=<vault> node label-communities.mjs --digest [repo ...] [--top N]
//   BRAIN_ROOT=<vault> node label-communities.mjs --apply <repo> --labels <file.json> [--force]
//
// --digest prints a JSON work order per repo:
//   { repo, total, preserved: {id: label}, derived: {id: name},
//     batches: [[ "Community <id> (<n> nodes): lbl1, lbl2 | files: f1, f2" ]],
//     labels_key_form, labels_template: {id: ""} }
// The top K unnamed communities (by node count, default 100) go to the agent in
// batches of <=100 (graphify's own label batch size); the tail gets a derived
// name here — dominant source file/dir — so no placeholder is left behind.
//
// THE LABELS FILE IS KEYED ON THE RAW COMMUNITY ID (INNOV-263)
// A batch line reads `Community 11 (95 nodes): ...` — its DISPLAY form. Keying
// the labels file on that display string used to be silently ignored: --apply
// looked up `agent[11]`/`agent["11"]` only, found nothing, and wrote derived
// filler names while REPORTING SUCCESS. On the next run classify() then saw
// those filler names as non-generic and marked them "preserved", so the real
// labels could never land — the mistake became load-bearing on run two.
// Three things prevent that now: both key forms are accepted, a labels file
// whose keys match NOTHING is a loud non-zero failure that writes nothing, and
// derived names are recorded as derived (see PROVENANCE below) so they are
// never mistaken for a human's work.
//
// PROVENANCE (INNOV-263 d)
// `.community-labels.json` next to the report records, per id, the final label
// and how it was chosen: preserved | agent | derived. classify() consults it so
// a name this script auto-derived is re-namable on a later run, while anything
// else — including every label written before this sidecar existed — keeps
// being treated as preserved. Absence of a record is always read the safe way.
//
// Pure Node, no deps.

import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { foldLabel, nameKey } from './community-name.mjs';
// INNOV-274: "what counts as a named label" is NOT defined here any more — it is
// defined once in label-guard.mjs and shared with sync-graph.sh's copy-time
// guard, which used to carry its own grep-shaped copy of the same idea.
import { isNamedLabel, readReportLabels, countNamedLabels } from './label-guard.mjs';

const argv = process.argv.slice(2);
const argVal = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);
const VAULT = process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();

const TOP_K = Number(argVal('--top')) || 100;
const BATCH = 100; // graphify _LABEL_BATCH_SIZE — sized for one naming pass per response
const PROV_FILE = '.community-labels.json'; // provenance sidecar, next to the report

// A labels-file key: the raw id ("11"), or its digest display form
// ("Community 11", and tolerantly "Community 11 (95 nodes): ..."), with any
// surrounding whitespace. Both normalize to the raw id before merging.
const KEY_FORM = /^\s*(?:community\s*#?\s*)?(\d+)\s*(?:[(:].*)?$/is;
const LABELS_KEY_FORM =
  'Keys are the raw community id as a string, e.g. "11". The digest display form ' +
  '"Community 11" is also accepted. Fill labels_template and pass it to --apply --labels.';

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
  // id (number) → label as written. Parsed by the shared module so this script
  // and sync-graph.sh cannot disagree about which lines are community headings.
  const reportLabels = report !== null ? readReportLabels(report) : new Map();
  const reportMembers = report !== null ? readReportMembers(report) : new Map();
  return {
    dir, reportPath, report, reportLabels, reportMembers, members, degree,
    provenance: readProvenance(dir),
    nodeCount: nodes.length, linkCount: links.length,
  };
}

// id → { name, provenance } from the sidecar. A missing/!unreadable/partial
// sidecar yields an empty map, which every caller must read as "no information",
// never as "auto-derived" — see isPreserved().
function readProvenance(dir) {
  const out = new Map();
  const p = join(dir, PROV_FILE);
  if (!existsSync(p)) return out;
  try {
    const data = JSON.parse(readFileSync(p, 'utf8'));
    for (const [k, v] of Object.entries(data?.labels ?? {})) {
      const id = Number(k);
      if (!Number.isFinite(id)) continue;
      out.set(id, typeof v === 'string' ? { name: undefined, provenance: v } : { name: v?.name, provenance: v?.provenance });
    }
  } catch {
    /* a corrupt sidecar must never lose labels: fall back to the safe reading */
  }
  return out;
}

// id (number) → the member names the report STATES for that id, from the
// `Nodes (n): a, b, c (+k more)` line under each heading. Line-scanned rather
// than regex-paired because graphify slips a `Cohesion:` line in between.
function readReportMembers(text) {
  const out = new Map();
  if (typeof text !== 'string') return out;
  let id = null;
  for (const line of text.split(/\r?\n/)) {
    const h = /^### Community (\d+) - "/.exec(line);
    if (h) { id = Number(h[1]); continue; }
    if (id === null) continue;
    const n = /^Nodes \(\d+\): (.*)$/.exec(line);
    if (!n) continue;
    out.set(id, n[1].replace(/\s*\(\+\d+ more\)\s*$/, '').split(',').map((x) => x.trim()).filter(Boolean));
    id = null;
  }
  return out;
}

// Fraction of a heading's stated members that must still be in graph.json's
// cluster of that id for the heading's name to describe a cluster that exists.
// ponytail: flat 0.5 over the <=12 members a report samples. Measured across 19
// real mirrors: current ones score 1.0 almost everywhere, the known-stale
// tray_pos_flutter scores below 0.5 on 418 of 433 headings — nothing sits near
// the line. Make it a per-mirror knob only if a mirror ever lands there.
const STALE_OVERLAP = 0.5;

// Does this id's heading still describe the cluster graph.json holds?
//
// THE PROBLEM (2026-08-19): graphify re-mints community ids on every rebuild, so
// a report can be FULLY non-generic while every name describes a cluster that no
// longer exists — measured: 470 headings vs 185 communities, 285 headings naming
// ids absent from graph.json, and community 34 named "route.test & related (3)"
// over a completely different node set. Genericness cannot see any of that, so
// /brain:label answered "already labeled, 0 batches" in exactly the state its own
// refusal message tells you to fix. Identity can see it: compare the members the
// heading states against the members the id actually holds now.
//
// Fail-safe: a heading with no parseable member line is NOT called stale (we know
// nothing about it, and the standing rule is to preserve).
function isStale(m, id) {
  const stated = m.reportMembers.get(id);
  if (!stated || stated.length === 0) return false;
  const actual = m.members.get(id);
  if (!actual) return true; // id no longer exists in graph.json
  const now = new Set(actual.map(nodeKey));
  const hit = stated.filter((s) => now.has(s)).length;
  return hit / stated.length < STALE_OVERLAP;
}

// Is this id's existing report label off-limits?
//
// The old rule was "any non-generic label is preserved", which cannot tell a
// human's name from filler this script derived — so one bad --apply run's filler
// became permanent (INNOV-263 d). The sidecar supplies the missing bit:
//   - no record at all      → PRESERVED. Backward compatible, and the safe
//                             reading: labels written before the sidecar existed
//                             were human/agent work.
//   - recorded 'derived'    → not preserved, but only while the report still
//                             carries that exact derived string. A hand-edit
//                             makes it a human label again, and it is preserved.
//   - anything else         → PRESERVED.
function isPreserved(m, id, existing) {
  // "Is this a name at all?" is the shared question (label-guard.isNamedLabel).
  // "Is that name off-limits?" is this script's own, provenance-aware answer.
  if (!isNamedLabel(existing)) return false;
  // A name for a cluster that no longer exists is not work worth preserving,
  // whatever the sidecar says about who wrote it.
  if (isStale(m, id)) return false;
  const rec = m.provenance.get(id);
  if (!rec || rec.provenance !== 'derived') return true;
  return nameKey(rec.name ?? '') !== nameKey(existing);
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
    if (isPreserved(m, id, existing)) preserved[id] = existing;
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
  // The batch STRINGS stay human-readable prose for the naming agent, so they
  // keep the `Community <id> (<n> nodes): ...` display form. The KEY the agent
  // must write is therefore stated separately, and handed over pre-filled:
  // labels_template is the labels file, minus the values (INNOV-263 c).
  const labels_template = {};
  for (const { id } of llm) labels_template[id] = '';
  // Headings for ids graph.json no longer has. They are stale by definition, but
  // there is nothing left to name — reported, not batched. Deliberately NOT
  // deleted from the report: dropping them would push the named count below the
  // one the INNOV-274 write-time invariant compares against, and the write would
  // refuse. They fall out on the next repo-side rebuild.
  const stale_headings = [...m.reportLabels.keys()].filter((id) => !m.members.has(id)).sort((a, b) => a - b);
  return { repo, total: m.members.size, preserved, derived, batches, stale_headings, labels_key_form: LABELS_KEY_FORM, labels_template };
}

// ---- report writing ----------------------------------------------------------

const hubLink = (label) => `[[_COMMUNITY_${label}|${label}]]`; // raw label — build-community-notes aliases it to the sanitized filename

// The member line under a community heading — one definition, because a stale
// heading's line is REWRITTEN from it and must come out in the same shape the
// appended/generated ones go in.
const nodesLine = (nodes) =>
  `Nodes (${nodes.length}): ${nodes.slice(0, 12).map(nodeKey).join(', ')}${nodes.length > 12 ? ` (+${nodes.length - 12} more)` : ''}`;

function transformReport(m, finalLabels, preservedIds) {
  // In-place: rename renamable headings + their hub links; append omitted ids.
  let text = m.report;
  const appended = [];
  for (const [idStr, label] of Object.entries(finalLabels)) {
    const id = Number(idStr);
    if (preservedIds.has(id)) continue; // preserved — never touched
    const existing = m.reportLabels.get(id);
    if (existing === undefined) { appended.push([id, label]); continue; } // thin/omitted → appended section
    if (existing === label) continue;
    text = text.replaceAll(`### Community ${id} - "${existing}"`, `### Community ${id} - "${label}"`);
    text = text.replaceAll(`[[_COMMUNITY_${existing}|${existing}]]`, hubLink(label));
  }
  if (appended.length) {
    appended.sort((a, b) => (m.members.get(b[0])?.length ?? 0) - (m.members.get(a[0])?.length ?? 0));
    const L = ['', '## Additional communities (labeled vault-side)', ''];
    for (const [id, label] of appended) {
      const nodes = m.members.get(id) ?? [];
      L.push(`### Community ${id} - "${label}"`);
      L.push(nodesLine(nodes));
      L.push('');
    }
    text = text.replace(/\n*$/, '\n') + L.join('\n') + '\n';
  }

  // A stale heading was just renamed for the cluster graph.json holds NOW, but it
  // still lists the members of the clustering it came from — wrong documentation,
  // and worse, the next --digest would read those old members, score the overlap
  // at zero again and re-flag the name this run just minted. So refresh the member
  // line for stale ids only; every other line stays byte-identical.
  const staleIds = new Set([...m.members.keys()].filter((id) => !preservedIds.has(id) && isStale(m, id)));
  if (staleIds.size) {
    const lines = text.split('\n');
    let cur = null;
    for (let i = 0; i < lines.length; i++) {
      const h = /^### Community (\d+) - "/.exec(lines[i]);
      if (h) { cur = staleIds.has(Number(h[1])) ? Number(h[1]) : null; continue; }
      if (cur === null) continue;
      if (!/^Nodes \(\d+\): /.test(lines[i])) continue;
      lines[i] = nodesLine(m.members.get(cur) ?? []) + (lines[i].endsWith('\r') ? '\r' : '');
      cur = null;
    }
    text = lines.join('\n');
  }

  // ---- INNOV-264: rewrite the LINK LIST, not just the detail headings -------
  // Renaming `### Community 42 - "Community 42"` fixes the detail section but
  // leaves every `[[_COMMUNITY_Community 42|Community 42]]` entry elsewhere in
  // the report (hub navigation, neighbor lists, per-community cross-links) still
  // pointing at the placeholder target. build-community-notes.mjs then dutifully
  // manufactures a generic link-only stub for each dangling target — so the
  // command that exists to CLEAR "all-generic community labels" reports success
  // while re-creating it. Measured residue 2026-08-04: hub-dw-service 3,
  // hub-gateway 11, hub-core-service 43, hub-frontend 68 (68 of 158 communities
  // — the majority of that report's links) = 125 total.
  //
  // The headings are the authority on each id's final name, and by now they are
  // final: renamed above, appended above, preserved ones deliberately untouched.
  // So re-read them out of the text we are about to write and point every
  // placeholder link entry at the name its own heading carries. Runs LAST, and
  // inside transformReport, so no caller can forget it and no post-pass can see
  // a half-rewritten report.
  // Re-parsed with the SHARED heading regex (label-guard.mjs), not a local copy.
  const headingNow = new Map(); // id (string) → final heading label
  for (const [id, label] of readReportLabels(text)) headingNow.set(String(id), label);
  text = text.replace(/\[\[_COMMUNITY_Community (\d+)(?:\|Community \1)?\]\]/g, (whole, id) => {
    // Fall back to finalLabels for an id the report links but never gave a
    // heading to; leave a link to an id absent from graph.json alone (nothing
    // here knows what it should be called).
    const name = headingNow.get(id) ?? finalLabels[id];
    return isNamedLabel(name) ? hubLink(name) : whole;
  });
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
    L.push(nodesLine(nodes));
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
  const force = argv.includes('--force');
  if (!repo || repo.startsWith('--') || !labelsFile) {
    console.error('usage: label-communities.mjs --apply <repo> --labels <file.json> [--force]');
    process.exit(1);
  }
  const m = readMirror(repo);
  const supplied = JSON.parse(readFileSync(labelsFile, 'utf8'));
  if (supplied === null || typeof supplied !== 'object' || Array.isArray(supplied)) {
    console.error(`error: ${labelsFile} must be a JSON object of {"<community id>": "<label>"}.`);
    process.exit(1);
  }

  // ---- key normalization + match check (INNOV-263 a/b) ----------------------
  // Accept the raw id and the digest's display form, then REFUSE to run when
  // nothing matched. Silently deriving filler for a labels file that was merely
  // mis-keyed is what made the original mistake load-bearing: the run reported
  // success, and run two treated its own filler as human labels.
  const knownIds = new Set([...m.members.keys()].map(String));
  const agent = {};
  const matchedKeys = [], unmatchedKeys = [];
  for (const [k, v] of Object.entries(supplied)) {
    const hit = String(k).match(KEY_FORM);
    if (hit && knownIds.has(hit[1])) { agent[hit[1]] = v; matchedKeys.push(k); }
    else unmatchedKeys.push(k);
  }
  const sample = (a, n = 5) =>
    a.slice(0, n).map((x) => JSON.stringify(x)).join(', ') + (a.length > n ? `, … (+${a.length - n} more)` : '');
  const idRange = knownIds.size
    ? `${Math.min(...m.members.keys())}..${Math.max(...m.members.keys())}`
    : '(none)';
  if (matchedKeys.length === 0) {
    console.error('');
    console.error('  ############################################################');
    console.error('  ##  LABELS NOT APPLIED — NO KEY MATCHED A COMMUNITY ID    ##');
    console.error('  ############################################################');
    console.error(`  labels file : ${labelsFile}`);
    console.error(`  repo        : ${repo} (${knownIds.size} communities, ids ${idRange})`);
    console.error(`  keys given  : ${Object.keys(supplied).length}${unmatchedKeys.length ? ` — ${sample(unmatchedKeys)}` : ' — (file is empty)'}`);
    console.error('  expected    : the raw community id, e.g. "11"  (display form "Community 11" also accepted)');
    console.error('  NOTHING WAS WRITTEN. Re-key the labels file and re-run.');
    console.error('  (--force derives names for every community anyway — only if that is genuinely what you want.)');
    console.error('');
    if (!force) process.exit(2);
  } else if (unmatchedKeys.length) {
    console.error(
      `warn ${repo}: ${unmatchedKeys.length} of ${Object.keys(supplied).length} label key(s) ` +
        `did not match a community id and were IGNORED: ${sample(unmatchedKeys)} ` +
        `(known ids ${idRange}; expected form "11" or "Community 11")`
    );
  }

  // Merge preserved > agent > derived. Preserved labels are re-read fresh from
  // the report (never trusted from a stale digest); any unnamed id the agent
  // didn't cover — the tail, or an invalid entry — gets a derived name here,
  // deterministically, largest community first.
  const { preserved } = classify(repo, m);
  const preservedIds = new Set(Object.keys(preserved).map(Number));
  const finalLabels = {};
  const origin = {}; // id → 'preserved' | 'agent' | 'derived'  (persisted; see PROVENANCE)
  const taken = new Set(Object.values(preserved).map((l) => nameKey(l)));
  let named = 0, invalid = 0, collided = 0;
  const bySize = [...m.members.keys()].sort((a, b) => m.members.get(b).length - m.members.get(a).length);
  for (const id of bySize) {
    if (preserved[id] !== undefined) { finalLabels[id] = preserved[id]; origin[id] = 'preserved'; continue; }
    const raw = agent[String(id)];
    const clean = sanitizeLabel(raw);
    if (isNamedLabel(clean)) {
      // Case-insensitive: an agent label that only differs in case from one
      // already taken is the same stub filename, so it must be disambiguated.
      const uniqued = uniqueLabel(clean, taken);
      if (uniqued !== clean) collided++;
      finalLabels[id] = uniqued;
      origin[id] = 'agent';
      named++;
    } else {
      if (raw !== undefined) invalid++;
      finalLabels[id] = deriveName(m.members.get(id), taken);
      origin[id] = 'derived';
    }
  }
  const pad = (n) => String(n).padStart(2, '0');
  const today = new Date();
  const date = `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())}`;
  const text = m.report !== null ? transformReport(m, finalLabels, preservedIds) : generateReport(repo, m, finalLabels, date);

  // INNOV-274 write-time invariant, using the SAME rule sync-graph.sh applies at
  // copy time (label-guard.mjs): a report we are about to write must never name
  // FEWER communities than the one it replaces. By construction it cannot —
  // preserved headings are untouched and every rewritten heading gets a
  // non-generic name — so a violation here means a bug in this script, and the
  // fail-closed answer is identical to the sync guard's: write nothing.
  const existingNamed = m.report !== null ? countNamedLabels(m.report) : 0;
  const nextNamed = countNamedLabels(text);
  if (nextNamed < existingNamed) {
    console.error(
      `error ${repo}: refusing to write a LESS-labeled report (${nextNamed} named vs ${existingNamed} existing). ` +
        'Nothing was written; this is a bug in label-communities.mjs, not in your labels file.'
    );
    process.exit(3);
  }
  writeFileSync(m.reportPath, text, 'utf8');
  // Provenance sidecar: which of these names a human/agent chose and which this
  // script invented. Without it, the next classify() cannot tell them apart and
  // reads its own filler as a name worth preserving.
  const provOut = { version: 1, repo, updated: date, labels: {} };
  for (const id of bySize) provOut.labels[id] = { name: finalLabels[id], provenance: origin[id] };
  writeFileSync(join(m.dir, PROV_FILE), JSON.stringify(provOut, null, 2) + '\n', 'utf8');
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

console.error('usage: label-communities.mjs --digest [repo ...] [--top N] | --apply <repo> --labels <file.json> [--force]');
process.exit(1);
