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
