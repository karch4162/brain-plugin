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
2. **CLI vs skill version** — compare `graphify --version` to `~/.claude/skills/graphify/.graphify_version`. Mismatch (CLI auto-upgraded, skill didn't) → R2.
3. **Vault binding** — `$BRAIN_ROOT` set and points at a dir containing `wiki/`? Unset/missing ⇒ tell the user to run `/brain:init` (don't guess).
4. **Registry health** — `~/.claude/brain/registry.json` parses as JSON; each vault `path` exists and is **OS-native absolute** (Windows `C:/...`, not git-bash `/c/...`, which `path.resolve` mangles). Bad form → R3.
5. **Local graph (cwd repo)** — `graphify-out/graph.json` present (so the hook fires) and, if `graphify-out/.graphify_python` exists, it points at an interpreter that still exists. Stale → R4.

## Repairs (ask before R1 — it reinstalls a global tool)

- **R1 — broken graphify launcher (the reparse-point case).** Clean-reinstall to the pinned version:
  ```bash
  uv tool uninstall graphifyy 2>/dev/null || true
  # Windows: if removal failed on a reparse point (os error 4395), force-clear the tool dir first:
  cmd //c "rmdir /s /q %APPDATA%\\uv\\tools\\graphifyy" 2>/dev/null || true
  uv tool install graphifyy==0.8.46
  graphify install        # re-sync the Claude skill to the CLI version
  ```
  Then verify `graphify --version` runs cleanly and `uv tool install graphifyy --reinstall` completes with **no** reparse error (proves the venv is consistent).
- **R2 — version mismatch.** `graphify install` (syncs the skill to the CLI). Non-destructive.
- **R3 — registry path not OS-native.** Rewrite the offending `path` / `repos_dir` to OS-native absolute form (Windows `C:/...`), matching `.claude/settings.json`. (See the brain-init "Path handling" rule.)
- **R4 — stale interpreter cache.** `rm <repo>/graphify-out/.graphify_python` — graphify re-resolves it on next use. Safe.

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
  CLI vs skill         ✅ 0.8.46 == 0.8.46
  BRAIN_ROOT           ✅ C:/.../personal-brain (wiki/ present)
  registry             ✅ 1 vault, paths valid + OS-native
  local graph (cwd)    ⚠️ graphify-out/ present · .graphify_python STALE → offer R4
<then apply confirmed repairs and re-check>
```
