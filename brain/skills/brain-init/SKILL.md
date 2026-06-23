---
name: brain-init
description: "Set up the brain for a project: ensure graphify is installed, pick (or register) the target vault from the brain registry, scaffold a new vault if needed, and wire this project to it. Trigger: /brain:init, or 'set up the brain here' / 'connect this repo to a brain'."
---

# /brain:init — connect a project to a brain vault

Wires the current project to a knowledge vault. Two routing questions exist (POC §16.2) — **do not conflate them**:

- **Query-time routing** ("which brain does the agent *read*?") is automatic — cwd + the 3-step rule. Not this skill.
- **Sync-time routing** ("which vault does this project *write its mirror + wiki into*?") is resolved **once, here, by explicit selection.** That is this skill.

> **This is a governance guardrail, not just convenience.** Routing a proprietary repo into a personal/public vault — or personal projects into a shared team vault — is a governance incident. Make the target **explicit and hard to get wrong**: show the chosen vault, confirm, and warn on git-remote mismatch.

## The brain registry

A user/org-level list of known vaults at **`~/.claude/brain/registry.json`** (create if missing). Format — see `${CLAUDE_PLUGIN_ROOT}/templates/brain-registry.example.json`:

```json
{
  "vaults": [
    {
      "name": "personal",
      "path": "/c/Users/me/Projects/AI-OS/personal-brain",
      "governance": { "egress": "off", "access": "private", "graphifyignore": "default" }
    },
    {
      "name": "tray-brain",
      "remote": "git@github.com:vendsy/tray-brain.git",
      "path": "/c/Users/me/Projects/tray-brain",
      "governance": { "egress": "off", "access": "eng-only", "graphifyignore": "strict" }
    }
  ]
}
```

## What to do when invoked

1. **Ensure graphify is installed** (delegated — the brain does not vendor it, POC §16.1):
   ```bash
   command -v graphify || uv tool install graphifyy
   ```
   If `uv` is absent, tell the user to install it (or `pip install graphifyy`) and stop.

2. **Load the registry** (`~/.claude/brain/registry.json`). If it doesn't exist, create it from the template with an empty `vaults: []`.

3. **Determine the default target and check for mismatch.** Read this project's git remote (`git remote get-url origin`). Infer a sensible default:
   - org/work remote (e.g. `vendsy/…`) → the team vault (`tray-brain`);
   - personal remote or none → the personal vault.
   Hold this as a *suggestion*, not an auto-apply.

4. **Select the vault — explicitly, via `AskUserQuestion`.** Present the registry vaults plus "register a new vault". Put the inferred default first, labeled `(suggested)`. **If the user's pick disagrees with the git-remote inference, surface the mismatch and re-confirm** ("This repo's remote is `vendsy/…` but you picked the personal vault — proprietary code would sync into a personal brain. Continue?"). This warning is the whole point of the step.

5. **If registering a new vault:** ask for a name, a path, and (optional) a remote, then scaffold it:
   ```bash
   # copy the skeleton + governance templates into the new vault path
   cp -r "${CLAUDE_PLUGIN_ROOT}/templates/vault-skeleton/." "<vault>/"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/graphifyignore" "<vault>/.graphifyignore"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/saveinclude"     "<vault>/.saveinclude"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/gitignore"       "<vault>/.gitignore"
   ```
   Then substitute the skeleton placeholders (`{{VAULT_NAME}}`, `{{DATE}}`, `{{area}}`) with real values.
   Then write the **3-step query rule** into the vault's `CLAUDE.md`: if `<vault>/CLAUDE.md` is absent, copy `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.brain.md` to it; if present, **merge** the rule section in idempotently (don't duplicate an existing "## The 3-step query rule" block). `git init` the vault if it isn't a repo. Append the new vault to the registry with its governance profile.

6. **Wire this project to the vault.** Persist the binding so every session here resolves it — merge into this project's `.claude/settings.json` (create if missing), preserving any existing keys:
   ```json
   { "env": { "BRAIN_ROOT": "<absolute vault path>" } }
   ```
   `BRAIN_ROOT` is the **neutral** contract var (POC §16.1) — the scripts, skills, and any consumer read it. Do not use a consumer-namespaced name.

7. **Confirm.** Print: the chosen vault (name + path), its governance profile, that `BRAIN_ROOT` is now set for this project, and the next step (`/graphify .` to build this repo's local graph, then `/brain:save` to sync a mirror).

## Notes

- The graph-before-grep hook ships **with this plugin** (`hooks/hooks.json`) — enabling the plugin is enough; `/brain:init` does **not** edit the global `~/.claude/settings.json` (a change from the hand-assembled pilot, which installed the hook globally).
- Reconfigurable later: re-run `/brain:init` to point a project at a different vault.
- Selecting a vault **applies its governance profile** to that project's sync (egress policy, `.graphifyignore` defaults, access tier).
