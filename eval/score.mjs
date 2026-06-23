#!/usr/bin/env node
// score.mjs — aggregate eval results, optionally LLM-judge correctness, check the §10 threshold.
//
// Reads results/*.json from run-eval.mjs, medians the per-(task,condition) metrics over the
// 3 runs, computes baseline-vs-treatment deltas, and evaluates the §10 success threshold:
//   (1) >=20% median token reduction, (2) no correctness regression,
//   (3) >=1 cross-repo task the baseline fails and the treatment passes.
//
// Correctness: pass --judge for an LLM first pass (`claude -p` grades answer vs `expects`
// → PASS/FAIL). A human signs off the headline number regardless (§10).
//
// Usage:
//   node score.mjs --results results --out report.md            # metrics only (correctness blank)
//   node score.mjs --results results --out report.md --judge     # + LLM-judge correctness

import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const has = (f) => process.argv.includes(f);
const RESULTS = arg('--results', join(HERE, 'results'));
const OUT = arg('--out', join(HERE, 'report.md'));
const JUDGE = has('--judge');
const claudeBin = arg('--claude', 'claude');

const median = (xs) => { const s = xs.filter((x) => x != null).sort((a, b) => a - b); return s.length ? s[Math.floor((s.length - 1) / 2)] : null; };

const files = existsSync(RESULTS) ? readdirSync(RESULTS).filter((f) => f.endsWith('.json')) : [];
const rows = files.map((f) => JSON.parse(readFileSync(join(RESULTS, f), 'utf8')));
if (!rows.length) { console.error(`No result files in ${RESULTS}. Run run-eval.mjs first.`); process.exit(1); }

// LLM-judge a single result's answer vs its expected, → 1 (PASS) / 0 (FAIL) / null (unscored).
function judge(row) {
  if (row.correct != null) return row.correct;        // pre-scored by a human
  if (!JUDGE) return null;
  const text = row.raw?.result ?? '';
  const prompt = `Grade an agent answer strictly. The task EXPECTS:\n${row.expects}\n\nAGENT ANSWER:\n${text}\n\nReply with exactly one word: PASS or FAIL.`;
  const res = spawnSync(claudeBin, ['-p', prompt, '--output-format', 'json'], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  let p = null; try { p = JSON.parse(res.stdout); } catch { /* unscored on failure */ }
  return p ? (/\bPASS\b/i.test(p.result || '') ? 1 : 0) : null;
}

// group runs by task|condition
const byKey = new Map();
for (const r of rows) {
  const k = `${r.task}|${r.condition}`;
  if (!byKey.has(k)) byKey.set(k, { task: r.task, condition: r.condition, cross_repo: r.cross_repo, category: r.category, runs: [] });
  byKey.get(k).runs.push({ in: r.raw?.usage?.input_tokens, turns: r.raw?.num_turns, ms: r.raw?.duration_ms, correct: judge(r) });
}

const tasks = [...new Set(rows.map((r) => r.task))];
const L = ['# Eval report (POC §10)', '', `Tasks: ${tasks.length} · result files: ${rows.length}${JUDGE ? ' · correctness: LLM-judged (human sign-off pending)' : ' · correctness: UNSCORED (pass --judge)'}`, ''];
L.push('| task | category | x-repo | base tok | treat tok | Δtok | base ok | treat ok |');
L.push('|---|---|:--:|--:|--:|--:|:--:|:--:|');

const tokDeltas = [];
let regression = false, crossRepoUniqueWin = false;
for (const t of tasks) {
  const b = byKey.get(`${t}|baseline`), x = byKey.get(`${t}|treatment`);
  const bTok = median((b?.runs || []).map((r) => r.in)), xTok = median((x?.runs || []).map((r) => r.in));
  const bOk = median((b?.runs || []).map((r) => r.correct)), xOk = median((x?.runs || []).map((r) => r.correct));
  const dTok = (bTok && xTok) ? Math.round((100 * (bTok - xTok)) / bTok) : null;
  if (dTok != null) tokDeltas.push(dTok);
  if (bOk != null && xOk != null && xOk < bOk) regression = true;
  if ((b?.cross_repo || x?.cross_repo) && bOk === 0 && xOk === 1) crossRepoUniqueWin = true;
  const ok = (v) => (v == null ? '?' : v === 1 ? '✅' : v === 0 ? '❌' : v);
  L.push(`| ${t} | ${b?.category || x?.category || ''} | ${(b?.cross_repo || x?.cross_repo) ? '✓' : ''} | ${bTok ?? '?'} | ${xTok ?? '?'} | ${dTok != null ? dTok + '%' : '?'} | ${ok(bOk)} | ${ok(xOk)} |`);
}

const medTok = median(tokDeltas);
const c1 = medTok != null && medTok >= 20;
L.push('', '## Threshold (§10) — all three must hold');
L.push(`1. ≥20% median token reduction: **${medTok != null ? medTok + '%' : '?'}** → ${medTok == null ? '❓ incomplete' : c1 ? '✅' : '❌'}`);
L.push(`2. no correctness regression: ${JUDGE ? (regression ? '❌ regression found' : '✅') : '❓ unscored'}`);
L.push(`3. ≥1 cross-repo task baseline fails & treatment passes: ${JUDGE ? (crossRepoUniqueWin ? '✅' : '❌') : '❓ unscored'}`);
const pass = JUDGE && c1 && !regression && crossRepoUniqueWin;
L.push('', pass
  ? '## ✅ Threshold MET — go for team rollout (pending human sign-off on the correctness rubric)'
  : '## ⚠️ Threshold not met / incomplete — see ❓/❌ above');

writeFileSync(OUT, L.join('\n') + '\n');
console.log(`Wrote ${OUT}`);
if (!JUDGE) console.log('Correctness unscored — pass --judge for an LLM first pass (a human still signs off the headline).');
