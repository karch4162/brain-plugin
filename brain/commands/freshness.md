---
description: "Run the brain wiki health check (orphans, dead [[links]], stale last_verified, broken source anchors) → a review queue, never auto-deletes. POC §8."
---

# /brain:freshness

Execute the brain plugin's **freshness** workflow. Read `${CLAUDE_PLUGIN_ROOT}/skills/freshness/SKILL.md` and follow its steps verbatim — it is the authority for this command.

> `${CLAUDE_PLUGIN_ROOT}` above is already an absolute path (the harness expands it on invocation). When a step in the SKILL runs `${CLAUDE_PLUGIN_ROOT}/bin/<script>`, use that exact absolute base verbatim — never infer, reconstruct, or hard-code the plugin path.

Arguments (optional, e.g. `--stale-days 30`): $ARGUMENTS
