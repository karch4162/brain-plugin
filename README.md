# tray-brain-plugin

> **Status:** extracted (POC §17.2 step 2 done) — **not yet cold-install-validated** (step 3).
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
tray-brain-plugin/                  # this repo (marketplace wrapper)
├── .claude-plugin/marketplace.json # marketplace manifest
└── brain/                          # the plugin (name: "brain")
    ├── .claude-plugin/plugin.json
    ├── skills/{save,resume,freshness,wiki-ingest,brain-init}/SKILL.md
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
| Plugin name | **`brain`** (neutral, not Tray-branded) | serves the personal pilot *and* `tray-brain` from one install (§16.2) |
| Vault location contract | env var **`BRAIN_ROOT`** (→ `$CLAUDE_PROJECT_DIR` → cwd) | neutral name the consumer reads (§16.1); scripts live outside the vault now, so they can't self-locate it |
| graphify | **delegated** (`uv tool install graphifyy`), not vendored | one-installer rule (§16.1) |
| Always-on query rule | shipped as `templates/CLAUDE.brain.md`, written into the vault `CLAUDE.md` by `/brain:init` | plugins can't ship an always-on `CLAUDE.md`; matches the pilot + the §17.2 diff target |
| grep-before-grep hook | shipped in the plugin (`hooks/hooks.json`) | replaces the pilot's **global** `~/.claude/settings.json` hook — `/brain:init` no longer edits global config |
| Covered repos | auto-derived from `graphify/<repo>/` mirror folders | removes the pilot's hardcoded volleyball repo list |

## Maps to the baseline acceptance checklist

See `../AI-OS/personal-brain/INSTALL_BASELINE.md` §D. Reproduced here: **A** (skills/bin/templates/dir
skeleton), **B1/B2** (hook now plugin-shipped), **B6** (registry format + `/brain:init` flow). Still
delegated/external: **B3** graphify skill, **B4** graphify CLI. **B5** `BRAIN_ROOT` named + emitted.

## Open validation items (for step 3 cold-install + structural diff)

1. **Script-invocation path** — skills call `node "${CLAUDE_PLUGIN_ROOT}/bin/…"`; confirm `${CLAUDE_PLUGIN_ROOT}` expands in the Bash tool when a plugin skill runs (vs. needing PATH/an absolute path).
2. **`harvest-chats.mjs` path encoding** — the generic `path→projects-dir` encoding (`[:\\/]`→`-`) must match Claude Code's real folder names on the target OS; most environment-coupled script.
3. **`/brain:init` registry + vault selection** — the §16.2 "least-proven piece"; exercise against a throwaway `tray-brain-test` vault.
4. **Global-hook isolation gotcha (§17.2)** — verify the now-plugin-shipped hook removes the pilot's global-config-mutation problem.
5. **Track B handshake** — confirm `BRAIN_ROOT` + the `graphify-out/graph.json` detection signal match what `ai-agent-manager` reads.

Will be committed to vendsy git when validation clears.
