# tray-brain-plugin

> **Status:** scaffolding / pre-extraction (POC §17.2 step 0 done — baseline tagged).
> **Folder/repo name is provisional** — confirm before the first push to vendsy git.

The standalone Claude Code **brain plugin** from the Tray "Second Brain" POC (§16): the knowledge
*substrate* — 3-step query-rule `CLAUDE.md` fragment, the `/save` `/freshness` `/wiki-ingest` `/resume`
skills, the graph-before-grep PreToolUse hook, the `bin/` scripts, the vault directory skeleton, and
the brain registry / init-time vault selection. Packaged so it installs in one command instead of the
hand-assembled global `settings.json` hook + `~/.claude/skills/` + hand-written query rule the pilot
runs today.

**Dependency direction (§16.1):** the brain is infrastructure; orchestrators (e.g. `ai-agent-manager`)
are *consumers* that depend on it, never the reverse. Installs alone; survives uninstalling any consumer.

## Source of truth

| What | Where |
|---|---|
| Design spec | `../AI-OS/personal-brain/docs/second-brain-poc.md` §16 (packaging) + §17 (rollout/validation) |
| Pilot baseline (what a cold install must reproduce) | `personal-brain` git tag **`pre-plugin-baseline`** |
| Out-of-repo scaffolding inventory + install acceptance checklist | `../AI-OS/personal-brain/INSTALL_BASELINE.md` |

## Next steps (not yet done)

1. **Extract** the plugin from the pilot: `.claude-plugin/plugin.json`, `skills/`, `hooks/`, the
   `CLAUDE.md` query-rule template, `bin/`, the dir skeleton, `.graphifyignore`/`.saveinclude` templates.
2. **Build** the net-new surface: brain registry + init-time vault selection (§16.2 — the least-proven piece).
3. **Validate** via cold install + structural diff against `pre-plugin-baseline` (§17.2), incl. the
   global-hook isolation gotcha and the Track B (`ai-agent-manager`) detection-contract handshake.

Will be committed to vendsy git when the extraction is ready.
