#!/usr/bin/env node
// run-eval.mjs — execute each eval task under each condition N times, capture metrics.
//
// For every task × condition × run it launches a headless Claude Code session
// (`claude -p "<prompt>" --output-format json`) in the task's repo, with the
// condition's launch args/env (baseline = raw repo; treatment = brain loaded), and
// records the result JSON (usage tokens, num_turns, duration) into results/.
//
// Usage:
//   node run-eval.mjs                      # uses tasks.jsonl + config.json (dry-run if no config.json)
//   node run-eval.mjs --runs 3 --out results
//   node run-eval.mjs --dry-run            # print the commands it WOULD run, invoke nothing
//
// No deps. Correctness is scored separately by score.mjs (this only captures runs).

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { invocation, normalizeResult } from './hosts.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const has = (f) => process.argv.includes(f);

const tasksPath = arg('--tasks', join(HERE, 'tasks.jsonl'));
const configPath = arg('--config', join(HERE, 'config.json'));
const RUNS = Number(arg('--runs', '3'));
const OUT = arg('--out', join(HERE, 'results'));
const DRY = has('--dry-run') || !existsSync(configPath);

const config = existsSync(configPath)
  ? JSON.parse(readFileSync(configPath, 'utf8'))
  : { claudeBin: 'claude', repos: {}, conditions: { baseline: { claudeArgs: [], env: {} }, treatment: { claudeArgs: [], env: {} } } };

const tasks = readFileSync(tasksPath, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
if (!DRY) mkdirSync(OUT, { recursive: true });

let planned = 0;
for (const task of tasks) {
  const repoPath = config.repos?.[task.repo];
  for (const [cond, spec] of Object.entries(config.conditions)) {
    for (let r = 1; r <= RUNS; r++) {
      planned++;
      const provider = spec.provider || config.provider || 'claude';
      const { command: cmd, args } = invocation(provider, task.prompt, { ...spec, command: spec.command || config.command || (provider === 'claude' ? config.claudeBin : undefined) });
      if (DRY || !repoPath) {
        console.log(`[dry] ${task.id}/${cond}/${r}  cwd=${repoPath || '<repo path TODO>'}  ${cmd} ${args.map((a) => JSON.stringify(a)).join(' ')}`);
        continue;
      }
      const started = Date.now();
      const res = spawnSync(cmd, args, {
        cwd: repoPath,
        env: { ...process.env, ...(spec.env || {}) },
        encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
        timeout: config.timeoutMs || 600000,
        windowsHide: true,
      });
      const parsed = normalizeResult(res.stdout || '', Date.now() - started);
      const outFile = join(OUT, `${provider}-${task.id}-${cond}-${r}.json`);
      writeFileSync(outFile, JSON.stringify({
        task: task.id, category: task.category, condition: cond, run: r, provider,
        cross_repo: !!task.cross_repo, expects: task.expects,
        raw: parsed, stderr: (res.stderr || '').slice(0, 2000), exit: res.status, error: res.error?.code || null,
      }, null, 2));
      const u = parsed?.usage || {};
      console.log(`${task.id}/${cond}/${r}: in=${u.input_tokens ?? '?'} out=${u.output_tokens ?? '?'} turns=${parsed?.num_turns ?? '?'} ${parsed?.duration_ms ?? '?'}ms`);
    }
  }
}
console.log(
  DRY
    ? `\n[dry-run] planned ${planned} runs, invoked nothing. Copy config.example.json → config.json, fill repo paths + condition launch specs, then re-run.`
    : `\nDone — ${planned} runs → ${OUT}. Next: node score.mjs --results ${OUT} --judge`
);
