# brain — Claude Code plugin

A git-backed, **agent-queryable knowledge substrate**. The brain makes every agent
session reason from accumulated decisions, gotchas, and cross-repo contracts instead
of re-deriving them from raw files each time.

It packages, as one installable plugin, what the personal-brain pilot ran as a
hand-assembled set of global hooks + skills + a hand-written query rule (POC §16):

| Piece | Path | What it does |
|---|---|---|
| **3-step query rule** | `templates/CLAUDE.brain.md` | graph → wiki → raw. Written into the vault's `CLAUDE.md` by `/brain:init` (plugins can't ship an always-on `CLAUDE.md`). |
| **Session continuity** | `skills/save`, `skills/resume` | `/brain:save` writes a dated log + refreshes `hot.md`; `/brain:resume` rehydrates it. |
| **Wiki health** | `skills/freshness` + `bin/freshness.mjs` | orphans / dead links / stale `last_verified` / broken `source:` → a review queue (never auto-edits). POC §8. |
| **Harvest → draft** | `skills/wiki-ingest` + `bin/harvest-chats.mjs` | distill session transcripts into *draft* notes; promotion is a separate PR step. |
| **Graph sync** | `bin/sync-graph.sh` + `bin/build-community-notes.mjs` | publish per-repo graph mirrors into the vault, namespaced, with community stubs. |
| **graph-before-grep** | `hooks/` | self-gating PreToolUse nudge (fires only where `graphify-out/graph.json` exists). |
| **Multi-vault registry** | `skills/brain-init` + `templates/brain-registry.example.json` | route a project's mirror+wiki to the right vault (personal vs team). POC §16.2. |
| **Health/repair** | `skills/doctor` | `/brain:doctor` diagnoses + repairs graphify launcher/version drift, the vault binding, the registry, and stale interpreter caches. |

## Setup & usage — by scenario (start here)

Find your situation, run the commands in order. Legend: **`/brain:*`** = this plugin · **`/graphify`** = the delegated graphify skill · **`/plugin …`** = built-in Claude Code.

### Prerequisites — once per machine
1. Install **`uv`** (https://docs.astral.sh/uv/). The brain installs graphify (pinned) through it on first `/brain:init`.
2. Install the plugin (needs access to the repo):
   ```
   /plugin marketplace add https://github.com/vendsy/tray-brain-plugin
   /plugin install brain@brain-marketplace
   ```
   Then restart Claude Code (or `/reload-plugins`).

### Scenarios

| Your situation | Run, in order | Notes |
|---|---|---|
| **A · New code repo, not yet in a brain** | `/brain:init` → *(work)* → `/brain:save` | `init` picks/registers the vault, wires `BRAIN_ROOT`, and **records the graph scope** (per-stack — you don't pick). `save` builds the code graph **at that scope**, ingests changed docs into the wiki, and syncs the mirror. **Don't run raw `/graphify`** — the brain owns the scoped build. |
| **B · Repo already linked, but you're on a new machine** | *(prereqs)* → clone the vault locally → `/brain:init` → `/graphify .` *(if no `graphify-out/`)* | Re-run `init`: the binding (`BRAIN_ROOT`) and registry are **per-machine** — `init` writes them to the gitignored `.claude/settings.local.json`, so this never conflicts with the shared repo. |
| **C · The vault repo itself, on a new machine** | clone the vault → `cd` into it → `/brain:init` | Registers the vault + binds it to itself. Detects the existing `CLAUDE.md`/`wiki/` and **won't overwrite** them. |
| **D · No vault exists yet (first time ever)** | `/brain:init` → choose **"register a new vault"** → give it a path | Scaffolds the skeleton + query-rule `CLAUDE.md` + governance files. Then onboard code repos via scenario A. |
| **E · Daily work in a linked repo** | `/brain:resume` *(start)* → *(work — just ask structural questions)* → `/brain:save` *(end)* | Graph-before-grep fires automatically; you don't run a command to "use" the graph. |
| **F · Tending the vault** | `/brain:freshness` · `/brain:wiki-ingest` | Run from the vault. `freshness` = rot review queue (orphans/dead links/stale); `wiki-ingest` = distill harvested chats → draft notes. |
| **G · Graph / graphify acting broken** | `/brain:doctor` | Diagnoses + repairs the graphify launcher/version, the vault binding, the registry, and stale interpreter caches. |

> **Per-machine, not per-clone:** the vault binding and registry (`~/.claude/brain/registry.json`) are machine-specific. Cloning a linked repo onto a new laptop always needs one `/brain:init` re-run (scenario B) — it's quick, non-destructive, and writes only to the gitignored local override.

## Dependencies

- **graphify CLI** — *delegated, not vendored* (POC §16.1 one-installer rule). `/brain:init`
  ensures it via `uv tool install graphifyy==0.8.46` (**pinned** — see Troubleshooting); the
  separately-installed graphify skill provides `graphify query/path/explain`.
- Node (for the `bin/*.mjs` scripts and the hook), Bash (for `sync-graph.sh`), git.

## Troubleshooting

**Graph queries fail / "graphify launcher points at a venv that no longer exists" / `ModuleNotFoundError: graphify.__main__` / "failed to canonicalize script path".**
This is graphify's (the delegated tool's) fragility, not the brain's — the §6.1 grep fallback keeps the
agent answering, but the graph is unavailable until fixed. Root cause: graphify's skill auto-runs
`uv tool install --upgrade graphifyy`, and on Windows a mid-upgrade venv rebuild can leave a
reparse-point/locked file (`os error 4395`) so the next removal fails and the launcher breaks — and it
**loops** (broken → import fails → re-upgrade → breaks again), worsened by multiple Claude sessions
upgrading concurrently. **Fix: `/brain:doctor`** (clean-reinstalls to the pinned version + re-syncs the
skill). Manual equivalent, from a single session with others closed:
```bash
uv tool uninstall graphifyy 2>/dev/null || true
cmd //c "rmdir /s /q %APPDATA%\\uv\\tools\\graphifyy" 2>/dev/null || true   # Windows: clear the stuck dir
uv tool install graphifyy==0.8.46
graphify install
```
Avoid by keeping graphify **pinned** (so its import stays healthy and the auto-upgrade never fires).

## Contracts (frozen — consumers depend on these)

- **`BRAIN_ROOT`** — the neutral env var pointing at a project's target vault. Scripts resolve the
  vault from `$BRAIN_ROOT` (→ `$CLAUDE_PROJECT_DIR` → cwd). A consumer-namespaced name
  (e.g. `AI_AGENT_MANAGER_BRAIN_ROOT`) is the inverted-ownership anti-pattern (§16.1).
- **`graphify-out/graph.json` presence** — the detection signal the graph-before-grep hook and any
  consumer's read-path key off. Don't change without a Track B handshake (§17.1).

## Status

v0.1.0 — **extracted from the pilot, not yet cold-install-validated** (POC §17.2 step 3). The cold
install + structural diff against the `pre-plugin-baseline` tag is what hardens this; expect the
script-invocation path resolution and the registry/init flow to need iteration. See
`../AI-OS/personal-brain/INSTALL_BASELINE.md` for the acceptance checklist.

## Commands vs skills

User-typed slash commands live in `commands/` (`/brain:save` `/brain:resume` `/brain:freshness`
`/brain:wiki-ingest` `/brain:init` `/brain:doctor`); each is a thin entry point that reads its `skills/<name>/SKILL.md`
as the authority. The skills also carry natural-language triggers (e.g. "lint the wiki" → freshness)
for model auto-invocation. (Plugin `skills/` alone are not user-typed slash commands — that's what
`commands/` is for.)

## Local testing

```bash
claude --plugin-dir <your-checkout>/brain   # the dir containing .claude-plugin/plugin.json
# restart the session (or /reload-plugins) after adding/changing commands
/brain:init                          # scaffold/select a vault
/brain:freshness                     # run the wiki health check
```
