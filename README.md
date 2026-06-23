# brain-plugin

> **Status:** extracted + cold-install-validated (POC §17.2 steps 2–3). **§17.1 checkbox 1 (packaging/isolation) MET** — `/brain:freshness` ran end-to-end through a live `--plugin-dir` install (slash command → skill → bundled `bin/` script → report). Remaining gate: §10 eval on a real  repo (checkbox 2 = the go/no-go for teams).
> **Folder/repo name is provisional** — confirm before the first push to vendsy git.

Development repo for the standalone Claude Code **brain plugin** (POC §16): the knowledge
*substrate* — the 3-step graph→wiki→raw query rule, the `/save` `/resume` `/freshness` `/wiki-ingest`
skills, a self-gating graph-before-grep hook, the vault scaffolding + `bin/` scripts, and a
multi-vault registry. Packaged so it installs in one command instead of the hand-assembled global
`settings.json` hook + `~/.claude/skills/` + hand-written query rule the pilot runs today.

**Dependency direction (§16.1):** the brain is infrastructure; orchestrators (e.g. `ai-agent-manager`)
are *consumers* that depend on it, never the reverse.

## Layout

```
-brain-plugin/                  # this repo (marketplace wrapper)
├── .claude-plugin/marketplace.json # marketplace manifest
└── brain/                          # the plugin (name: "brain")
    ├── .claude-plugin/plugin.json
    ├── commands/{save,resume,freshness,wiki-ingest,init}.md   # user-typed /brain:* slash entry points
    ├── skills/{save,resume,freshness,wiki-ingest,brain-init}/SKILL.md   # authority + model-invoked
    ├── hooks/{hooks.json, graph-before-grep.mjs}
    ├── bin/{sync-graph.sh, freshness.mjs, build-community-notes.mjs, harvest-chats.mjs}
    └── templates/{CLAUDE.brain.md, graphifyignore, saveinclude, gitignore,
                   brain-registry.example.json, vault-skeleton/}
```

Mirrors the `ai-agent-manager` plugin (the reference consumer): marketplace wrapper + nested plugin,
`${CLAUDE_PLUGIN_ROOT}` for runtime paths. `claude plugin validate ./brain` passes.

## Design decisions taken in extraction

| Decision | Choice | Why |
|---|---|---|
| Plugin name | **`brain`** (neutral, not -branded) | serves the personal pilot *and* `-brain` from one install (§16.2) |
| Vault location contract | env var **`BRAIN_ROOT`** (→ `$CLAUDE_PROJECT_DIR` → cwd) | neutral name the consumer reads (§16.1); scripts live outside the vault now, so they can't self-locate it |
| graphify | **delegated** (`uv tool install graphifyy`), not vendored | one-installer rule (§16.1) |
| Always-on query rule | shipped as `templates/CLAUDE.brain.md`, written into the vault `CLAUDE.md` by `/brain:init` | plugins can't ship an always-on `CLAUDE.md`; matches the pilot + the §17.2 diff target |
| grep-before-grep hook | shipped in the plugin (`hooks/hooks.json`) | replaces the pilot's **global** `~/.claude/settings.json` hook — `/brain:init` no longer edits global config |
| Covered repos | auto-derived from `graphify/<repo>/` mirror folders | removes the pilot's hardcoded volleyball repo list |

## Maps to the baseline acceptance checklist

See `../AI-OS/personal-brain/INSTALL_BASELINE.md` §D. Reproduced here: **A** (skills/bin/templates/dir
skeleton), **B1/B2** (hook now plugin-shipped), **B6** (registry format + `/brain:init` flow). Still
delegated/external: **B3** graphify skill, **B4** graphify CLI. **B5** `BRAIN_ROOT` named + emitted.

## Step-3 validation status (cold-install + structural diff)

| # | Item | Status |
|---|---|---|
| 0 | **User-typed `/brain:*` slash invocation** | ✅ **verified live** — `/brain:freshness` ran end-to-end against the vault (47 notes, report written). Fix was adding `commands/` delegating to the skills (`skills/`-only entries returned "Unknown command"). |
| 1 | **`${CLAUDE_PLUGIN_ROOT}` expansion** in command/skill bodies | ✅ confirmed — substituted inline in command/skill/hook content (docs + reference plugin) |
| 2 | **`harvest-chats.mjs` path→projects-dir encoding** matches the OS | ✅ validated — identical real harvest results to the pilot on Windows |
| 3 | **Genericized bin scripts preserve behavior** | ✅ validated — `freshness` output byte-identical to the pilot (with + without explicit `REPOS_DIR`) |
| 4 | **No fixed-layout assumption** (repos location) | ✅ fixed + validated — auto-detects repos 1–2 levels above the vault; `REPOS_DIR` override persisted by `/brain:init`. Caught a 0→35 false-positive on the original guess. |
| 5 | **Vault scaffold reproduction** (skeleton + governance files) | ✅ validated — structural diff vs pilot is clean; vault `.gitignore` keeps `chats/` private |
| 6 | **Global-hook isolation gotcha (§17.2)** | ✅ resolved by design — hook is plugin-shipped, no global `settings.json` mutation |
| 7 | **Track B handshake** | ✅ simplified — consumer does graphify-detection first, `BRAIN_ROOT` second, its own memory as fallback; this plugin emits both signals |

Remaining before vendsy push: a live plugin install to close item #1, and the expensive full graph-content regen (explicitly **not** a diff target — content is user-owned, §17.2).
