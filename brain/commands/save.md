---
description: "Persist the current brain session: dated log, refresh hot.md, append the op log, sync changed graph mirrors, commit the allowlist."
---

# /brain:save

Execute the brain plugin's **save** workflow. Read `${CLAUDE_PLUGIN_ROOT}/skills/save/SKILL.md` and follow its steps verbatim — it is the authority for this command.

> `${CLAUDE_PLUGIN_ROOT}` above is already an absolute path (the harness expands it on invocation). When a step in the SKILL runs `${CLAUDE_PLUGIN_ROOT}/bin/<script>`, use that exact absolute base verbatim — never infer, reconstruct, or hard-code the plugin path.

Arguments: $ARGUMENTS
