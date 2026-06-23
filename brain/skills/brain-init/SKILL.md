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

> **Path handling — do this for EVERY path you persist.** Normalize paths to **OS-native absolute form** before writing them to the registry *or* `.claude/settings.json`, and use the **same** form in both files. On Windows, convert a git-bash `/c/Users/...` to `C:/Users/...` (forward slashes are fine for Node); resolve `~` and relative paths to absolute up front. **Why it matters:** the registry and settings must agree, because a later re-init that reads `registry.repos_dir` back into a settings `REPOS_DIR` would otherwise persist a git-bash path — and `path.resolve('/c/Users/...')` on Windows resolves to `C:\c\Users\...`, which breaks harvest's project-dir encoding (and any script that joins `REPOS_DIR`). When in doubt, mirror the OS-native style the user's `BRAIN_ROOT` ends up in.

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

5. **If registering a vault** (the "register a new vault" choice): ask for a name, a path, and (optional) a remote. Then **branch on whether that path is already a populated vault — do NOT scaffold over existing content.**

   **First detect:** treat the path as an **existing vault** if it already contains a `CLAUDE.md` *or* a `wiki/` directory. Otherwise it's a **new vault**.

   **(a) Existing vault → register + fill gaps non-destructively. NEVER overwrite.**
   - Do **not** run the skeleton/template `cp` commands over it — that would clobber the user's `CLAUDE.md`, `wiki/`, `.graphifyignore`, etc.
   - Create only **missing** governance files from templates (skip any that exist): e.g. `[ -f "<vault>/.saveinclude" ] || cp "${CLAUDE_PLUGIN_ROOT}/templates/saveinclude" "<vault>/.saveinclude"` (same pattern for `.gitignore`). **Leave `CLAUDE.md` and `.graphifyignore` untouched** — they're user content.
   - If `CLAUDE.md` has **no** "3-step query rule" section, *offer* to merge one in from `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.brain.md` — **ask first via AskUserQuestion, never auto-edit** an existing CLAUDE.md.
   - Register it in the registry; skip all scaffolding.

   **(b) New / empty vault → full scaffold:**
   ```bash
   cp -r "${CLAUDE_PLUGIN_ROOT}/templates/vault-skeleton/." "<vault>/"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/graphifyignore" "<vault>/.graphifyignore"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/saveinclude"     "<vault>/.saveinclude"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/gitignore"       "<vault>/.gitignore"
   ```
   Substitute the skeleton placeholders (`{{VAULT_NAME}}`, `{{DATE}}`, `{{area}}`). Write the **3-step query rule** into `CLAUDE.md` by copying `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.brain.md` (it's absent in a new vault). `git init` if not a repo.

   In **both** cases, append the vault to the registry with its governance profile.

6. **Wire this project to the vault.** Persist the binding so every session here resolves it — merge into this project's `.claude/settings.json` (create if missing), preserving any existing keys:
   ```json
   { "env": { "BRAIN_ROOT": "<absolute vault path>", "REPOS_DIR": "<where the vault's mirrored repos are checked out>" } }
   ```
   - `BRAIN_ROOT` is the **neutral** contract var (POC §16.1) — the scripts, skills, and any consumer read it. Do not use a consumer-namespaced name.
   - `REPOS_DIR` tells the sync/harvest/freshness scripts where the *code repos* live. **Do not assume a fixed layout** — infer a default (the parent dir of the project being wired, or the vault's parent), **show it, and let the user correct it**, then persist. The scripts also auto-detect repos one or two levels above the vault, so `REPOS_DIR` is only required when checkouts live somewhere non-standard — but persisting it removes the guess. Store it on the vault's registry entry too (`repos_dir`).

7. **Confirm.** Print: the chosen vault (name + path), its governance profile, that `BRAIN_ROOT` is now set for this project, and the next step (`/graphify .` to build this repo's local graph, then `/brain:save` to sync a mirror).

## Notes

- The graph-before-grep hook ships **with this plugin** (`hooks/hooks.json`) — enabling the plugin is enough; `/brain:init` does **not** edit the global `~/.claude/settings.json` (a change from the hand-assembled pilot, which installed the hook globally).
- Reconfigurable later: re-run `/brain:init` to point a project at a different vault.
- Selecting a vault **applies its governance profile** to that project's sync (egress policy, `.graphifyignore` defaults, access tier).
