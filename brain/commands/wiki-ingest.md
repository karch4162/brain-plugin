---
description: "Distill harvested session digests (chats/) into DRAFT wiki notes for review (stays in staging until PR-promoted)."
---

# /brain:wiki-ingest

Execute the brain plugin's **wiki-ingest** workflow. Read `${CLAUDE_PLUGIN_ROOT}/skills/wiki-ingest/SKILL.md` and follow its steps verbatim — it is the authority for this command.

> `${CLAUDE_PLUGIN_ROOT}` above is already an absolute path (the harness expands it on invocation). When a step in the SKILL runs `${CLAUDE_PLUGIN_ROOT}/bin/<script>`, use that exact absolute base verbatim — never infer, reconstruct, or hard-code the plugin path.

Arguments (optional, a file/repo to scope to): $ARGUMENTS
