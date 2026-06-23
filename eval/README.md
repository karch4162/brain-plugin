# Brain eval harness (POC §10)

The defensible **with/without measurement** that decides whether the brain earns a team rollout.
This is **§17.1 checkbox 2** — the actual go/no-go for teams (checkbox 1, packaging/isolation, is met).

> Not part of the distributable plugin — only `../brain/` is installed (marketplace `source: ./brain`).
> This harness lives in the repo for convenience; its task content references internal Tray systems
> and stays in the vendsy-internal repo.

## The question

> Does a shared, structured, provenance-tracked brain measurably improve agent output (correctness),
> reduce token/time cost, and surface cross-repo knowledge the agent otherwise misses — on **real Tray
> tasks**?

## Why a *real* repo (not the volleyball pilots) — §14.3

Below ~100 notes a depth-2 graph query reaches almost everything (≈ "just read the index"), so the win
is muted. The separation from grep shows at **hundreds+ of notes** and specifically on **cross-repo**
and **code→rationale** tasks. **Run this on `hub` or `tray_pos_flutter`, not the small repos** — the
pilot already proves the mechanics; this proves the *value*.

## Conditions

| Condition | Setup |
|---|---|
| **baseline** | agent + the raw repo only. No plugin, no vault, no graph. |
| **treatment** | agent + the brain: repo graphified (`graphify-out/`), the `brain` plugin loaded, the target vault present with this repo's mirror + wiki notes + `bridges/`. |

Each task runs **3× per condition** (variance). See `run-eval.mjs` for how each condition is launched.

## Task set (8–10 tasks) — §10 categories

Authored in `tasks.jsonl` (one JSON object per line). The categories that must be represented:

| Category | Count | Why |
|---|---|---|
| `bug-fix` | ≥1 | a real INNOV bug fix — concrete, scoreable against what merged |
| `payload-shape` | ≥1 | a payload/field-shape change (POS↔hub contract surface) |
| `offline-sync` | ≥1 | an offline-sync question (rationale the wiki holds, code can't tell you) |
| `onboarding` | ≥1 | "how does X work" — the onboarding question |
| `cross-repo` | **≥2** | the questions the brain should **uniquely win** (POS↔hub via `bridges/`). The headline result. |

Task schema (`tasks.jsonl`):
```json
{
  "id": "innov-1234-fix",
  "category": "bug-fix",
  "repo": "hub",
  "prompt": "…the task as a user would ask it…",
  "expects": "…known-good answer, or a 0–3 rubric, or the PR/commit that actually merged…",
  "brain_should_win": false,
  "cross_repo": false
}
```
> **TODO (needs the real repo):** author the 8–10 tasks against hub/POS. Pick tasks with a *known-good*
> answer (a merged PR, a documented contract) so correctness is scoreable, not vibes.

## Metrics — §10

| Metric | How captured |
|---|---|
| **Correctness** | human rubric 0–3, or pass/fail vs the known-good `expects`. `score.mjs` supports an LLM-judge first pass (`claude -p`), but a human signs off the headline number. |
| **Token cost** | input tokens to first correct answer — from `claude -p --output-format json` `usage`. |
| **Time / tool-calls** | wall-clock + number of file reads/greps — from the run JSON (`num_turns`, duration) + transcript parse. |
| **Human-edit-distance** | for code tasks: lines changed between the agent's output and what actually merged. |

## Success threshold (proposed — tune in review, §13 Q5)

**All three** must hold:
1. **≥20% token reduction** (treatment vs baseline, median to first correct answer), **and**
2. **no correctness regression**, **and**
3. **≥1 cross-repo task the baseline fails that the treatment passes** (the unique win).

## Running it

```bash
# 1. Author tasks.jsonl against the real repo (the TODO above).
# 2. Stand up the treatment brain (graph the repo, load the plugin, point at the vault).
node run-eval.mjs --tasks tasks.jsonl --runs 3        # → results/<id>-<condition>-<run>.json
node score.mjs   --results results/ --out report.md   # aggregate, threshold check, markdown report
```

## Status

Harness **scaffolding** built (this dir). Blocked on: the real-repo task authoring + a graphified
hub/POS treatment brain. The runner/scorer are repo-agnostic and ready.
