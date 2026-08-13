---
name: doctor
description: "Diagnose and repair brain health — graphify install/launcher/version drift, the vault binding (BRAIN_ROOT), the registry, and stale interpreter caches. Trigger: /brain:doctor, or 'the graph/graphify is broken', 'check brain health', 'fix graphify'."
---

# /brain:doctor — diagnose & repair brain health

The brain delegates the graph engine to **graphify** (POC §16.1), so it inherits graphify's
operational fragility. The signature failure on Windows: a half-finished `uv tool install --upgrade
graphifyy` leaves the tool venv with a reparse-point / locked file, so a later removal fails (`os
error 4395`) and the launcher breaks — "points at a venv that no longer exists" / `ModuleNotFoundError:
graphify.__main__` / "failed to canonicalize script path". The §6.1 grep fallback keeps the agent
answering, but the graph's value is lost until repaired. This command finds and fixes that class.

Resolve the vault as `$BRAIN_ROOT` (else cwd). **Pinned graphify version: `0.8.46`** (bump deliberately; keep in sync with `/brain:init`).

## Checks — run all, print a ✅/⚠️/❌ table, then offer the matching repair per ❌

1. **graphify CLI present & runnable** — `command -v graphify` and `graphify --version` exits 0 with a version. A traceback / `ModuleNotFoundError` / "failed to canonicalize" ⇒ **broken launcher** → R1.
2. **`/graphify` skill registered** — `~/.claude/skills/graphify/SKILL.md` exists. The CLI and skill install separately; a CLI-only machine passes check 1 but `/brain:save` can't build the wiki concept graph (its keyless path runs through the *skill*). Missing → R2.
3. **CLI vs skill version** — compare `graphify --version` to `~/.claude/skills/graphify/.graphify_version`. Mismatch (CLI auto-upgraded, skill didn't) → R2. (Skip if check 2 failed — register first.)
4. **Vault binding** — `$BRAIN_ROOT` set and points at a dir containing `wiki/`? Unset/missing ⇒ tell the user to run `/brain:init` (don't guess).
4b. **Vault self-binding** — does the **vault's own** `.claude/settings.local.json` carry an `env` block with `BRAIN_ROOT` + `REPOS_DIR`? `/brain:init` binds the *project*; the vault needs the same block, because `/brain:freshness`, `/brain:tidy` and `/brain:save` are typically run **from the vault**, where the project's settings don't apply. Missing ⇒ the freshness scan silently auto-detects (probing only `vault/..` and `vault/../..`) and mis-resolves every `source:` anchor — it reports a plausible number with no error, so this failure is invisible until someone acts on the bad queue. Missing or pointing at a dir that contains none of the `graphify/` mirror names → **R5**.
4c. **Sub-path aliases in `repos.json`** — entries that have a `subPath` **and** no matching `graphify/` mirror folder are *aliases* (a directory inside some repo), not repos. Each alias **globally reserves its first segment**: every anchor in the vault starting with that segment resolves into the alias's repo, whatever area the note lives in — and if a same-named file exists there, it verifies GREEN against the wrong repo. **List them** with the repo they point into (e.g. `docs/ → tray-architecture`, `lib/ → tray_pos_flutter`) so the operator knows which segments are reserved; call out generic ones every repo has (`lib`, `docs`, `scripts`, `src`). ⚠️ **informational, no repair** — aliases are load-bearing (they make anchors machine-independent) and freshness cross-checks each note's area against the resolved repo's remote; the point is that new aliases get added *deliberately*, knowing the reserved segment.
5. **Registry health** — `~/.claude/brain/registry.json` parses as JSON; each vault `path` exists and is **OS-native absolute** (Windows `C:/...`, not git-bash `/c/...`, which `path.resolve` mangles). Bad form → R3.
6. **Local graph (cwd repo)** — `graphify-out/graph.json` present (so the hook fires) and, if `graphify-out/.graphify_python` exists, it points at an interpreter that still exists. Stale → R4.
7. **Brain plugin version drift** — check 3 does exactly this for graphify; this turns it on ourselves. **Run the script, don't reason about it:**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-plugin-version.sh"
   ```
   - **Exit `0` (`PLUGIN-VERSION: OK`) →** ✅, quote the line **including its qualifier** — it says either `(clone current with remote)` (the clone was fetch-verified) or `(remote not checked: <reason>; clone last refreshed <age>)` (offline / no git repo / fetch timed out — still ✅, never fail for being offline). Don't trim the qualifier; it is what was actually compared.
   - **Exit `1` (`PLUGIN-VERSION: DRIFTED`) →** ❌ → **R6**. Relay the line **verbatim** — it names both versions and the install path.
   - **Exit `1` (`PLUGIN-VERSION: STALE-CLONE`) →** ❌ → **R6**. Install matches the clone, but a successful fetch proved the clone is N commit(s) behind its remote — the trap where `claude plugin update` reports success and changes nothing. Relay verbatim. **The remedy ORDER matters:** `claude plugin marketplace update <mp>` FIRST, then `claude plugin update <key>`, then restart/reload.
   - **`PLUGIN-VERSION: SKIPPED` (exit `0`) →** ⚠️ **"skipped — <reason>", never ✅.** A machine running from source (`--plugin-dir`) legitimately skips. A false ✅ here is what this check exists to prevent.

   Why it matters: measured 2026-08-06, the author's own install was **0.2.19 against a 0.2.22 source** — missing `vault-commit.sh`, `write-hot.sh`, `check-hot-budget.sh`, `label-guard.mjs` and `check-anchors.mjs`. **Nine shipped fixes were not running**, and INNOV-265 was very likely filed against an already-fixed defect for exactly this reason. A stale install doesn't misbehave; it behaves like an older, worse version of itself, silently.
8. **Vault allowlist covers the write set** — a `.saveinclude` missing a path a shipped command commits means that command does its file work and then `vault-commit.sh` refuses to commit it: the work lands on disk, the commit never happens. Every vault created before `0.2.22` has this (`graphify/` was never allowlisted, because `sync-graph.sh` used to run its own `git add`).
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-allowlist.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **Exit `0` (`ALLOWLIST: OK`) →** ✅.
   - **Exit `1` (`ALLOWLIST: INCOMPLETE`) →** ❌ → **R7**. The script names each missing path *and which command needs it*; relay that, don't re-derive it.
   - Skip if check 4 failed — bind a vault first. A non-vault dir reports OK/skipped.

   **The required set is not listed here, deliberately.** It comes from `vault-commit.sh --print-required`, which is where the enforcement lives. A second copy in this skill would be the INNOV-274 defect, drifting in the most useless direction: this checker would go stale exactly when a newly-committed path made it matter.
9. **Vault .gitignore carries the plugin's entries** — `/brain:init` only creates governance files that are *missing* (correctly — they carry user content), so a vault's `.gitignore` is frozen at scaffold time and never receives template additions. Concrete instance: the template gained `.brain/` in `0.2.24`, but every vault scaffolded before then shows machine-local session state as untracked — or gets it committed and shared between machines.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-gitignore.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **Exit `0` (`GITIGNORE: OK`) →** ✅.
   - **Exit `1` (`GITIGNORE: INCOMPLETE`) →** ❌ → **R8**. The script names each missing entry *and why the plugin needs it*; relay that, don't re-derive it.
   - Skip if check 4 failed — bind a vault first. A non-vault dir reports OK/skipped.

   **The required set is not listed here, deliberately.** It is parsed from the `# doctor:required` markers in `templates/gitignore` — the template IS the one definition (check 8's rule, same rationale).

## Repairs (ask before R1 — it reinstalls a global tool)

- **R1 — broken graphify launcher (the reparse-point case).** Clean-reinstall to the pinned version:
  ```bash
  uv tool uninstall graphifyy 2>/dev/null || true
  # Windows: if removal failed on a reparse point (os error 4395), force-clear the tool dir first:
  cmd //c "rmdir /s /q %APPDATA%\\uv\\tools\\graphifyy" 2>/dev/null || true
  uv tool install graphifyy==0.8.46
  graphify install --platform claude   # re-register the Claude skill at the CLI version
  ```
  Then verify `graphify --version` runs cleanly and `uv tool install graphifyy --reinstall` completes with **no** reparse error (proves the venv is consistent).
- **R2 — skill missing or version mismatch.** `graphify install --platform claude` (registers/syncs the `~/.claude/skills/graphify/` skill to the CLI version). Non-destructive; if newly registered, the skill shows up after a session restart or `/reload-plugins`.
- **R3 — registry path not OS-native.** Rewrite the offending `path` / `repos_dir` to OS-native absolute form (Windows `C:/...`), matching `.claude/settings.json`. (See the brain-init "Path handling" rule.)
- **R4 — stale interpreter cache.** `rm <repo>/graphify-out/.graphify_python` — graphify re-resolves it on next use. Safe.
- **R5 — vault not self-bound.** Write (or merge into) the vault's `.claude/settings.local.json`:
  ```json
  { "env": { "BRAIN_ROOT": "<vault path>", "REPOS_DIR": "<where the mirrored repos are checked out>" } }
  ```
  Preserve any existing keys; use OS-native absolute paths (R3's rule). Derive `REPOS_DIR` from the registry entry's `repos_dir` when present; otherwise find the directory that actually contains the `graphify/` mirror names and **confirm it with the user** rather than guessing. Ensure the file is gitignored in the vault. Non-destructive, but it only takes effect in a **new** session — the `env` block is injected at session start, so re-run `/brain:freshness` afterwards in a fresh session to confirm.

- **R6 — stale brain plugin install.** **Two commands, in this order.** Verified 2026-08-06 by running them against a real 0.2.19 → 0.2.22 drift:
  ```bash
  claude plugin marketplace update <marketplace>     # refresh the local clone
  claude plugin update <plugin>@<marketplace>        # install what the clone now offers
  ```
  **The second alone is not enough, and this is the trap.** `claude plugin update` reads the *local marketplace clone*, so when that clone is itself stale it finds nothing new and reports success-shaped output while changing nothing. Both were stale on the machine this was written on. Confirm with `check-plugin-version.sh`, then **restart the session (or `/reload-plugins`)** — an updated copy is not live until then. Non-destructive: the cache is version-keyed (`cache/<mp>/<plugin>/<version>/`), so the previous version stays on disk and is available to roll back to.
- **R7 — vault allowlist missing required paths.** Append them:
  ```bash
  BRAIN_ROOT=<vault> bash "${CLAUDE_PLUGIN_ROOT}/bin/check-allowlist.sh" --fix
  ```
  **Appends only** — never overwrites, reorders, or removes, and never re-seeds from the template. A vault's `.saveinclude` is customized (one real vault carries `wiki/_drafts/`), and a template overwrite would silently drop those entries. Each appended line is commented with which command needs it. Show the diff and confirm before running — this is a governance file. Afterwards it must be **committed deliberately**: `.saveinclude` is not in the allowlist, so no brain command will ever commit it for you.
- **R8 — vault .gitignore missing plugin-required entries.** Append them:
  ```bash
  BRAIN_ROOT=<vault> bash "${CLAUDE_PLUGIN_ROOT}/bin/check-gitignore.sh" --fix
  ```
  **Appends only** — never overwrites, reorders, or removes, and never re-seeds from the template. A vault's `.gitignore` is customized (users add their own private patterns), and a template overwrite would silently drop them. Each appended line is commented with why the plugin needs it. Show the diff and confirm before running — this is a governance file. Afterwards commit it **deliberately**: `.gitignore` is not in the allowlist, so no brain command will ever commit it for you.

## Prevention (why pinning matters)

The churn is driven by graphify's own skill auto-running `uv tool install --upgrade graphifyy` whenever
its import fails — which, once a venv is half-broken on Windows, **loops** (broken → import fails →
upgrade → breaks again). Keeping graphify **pinned and healthy** so import never fails stops the cycle.
`/brain:init` installs the pinned version; run `/brain:doctor` after any graphify hiccup to reset to a
clean, consistent state.

## Output format

```
Brain doctor — <vault name or path>
  graphify CLI         ✅ 0.8.46 runnable
  /graphify skill      ✅ registered (~/.claude/skills/graphify)
  CLI vs skill         ✅ 0.8.46 == 0.8.46
  BRAIN_ROOT           ✅ C:/.../personal-brain (wiki/ present)
  vault self-binding   ❌ vault .claude/settings.local.json has no env block → offer R5
  repo aliases         ⚠️ 6 sub-path aliases reserve: android/ docs/ groovy/ lib/ scripts/ terraform/
  registry             ✅ 1 vault, paths valid + OS-native
  local graph (cwd)    ⚠️ graphify-out/ present · .graphify_python STALE → offer R4
  brain plugin         ❌ installed 0.2.19, marketplace offers 0.2.22 → offer R6
  vault allowlist      ❌ .saveinclude missing 1 of 7: graphify/ (bin/sync-graph.sh) → offer R7
  vault gitignore      ❌ .gitignore missing 1 of 6: .brain/ (machine-local session state) → offer R8
<then apply confirmed repairs and re-check>
```
