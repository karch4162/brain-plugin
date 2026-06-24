# Brain plugin — session handover

> Distilled state for a fresh session or teammate picking this up. Last updated **2026-06-24**. Plugin version **0.2.0**.

## What this is
**brain** is a Claude Code plugin: a git-backed, agent-queryable **knowledge substrate** (Graphify
code graph + an Obsidian-style concept wiki + the graph→wiki→raw query rule). It packages what the
`personal-brain` pilot ran as hand-assembled global hooks/skills into one installable plugin.
The design spec ("the POC") is the source of truth: `AI-OS/personal-brain/docs/second-brain-poc.md`.

## Repos & locations
| What | Where |
|---|---|
| **Plugin (this repo)** | local `C:\Users\mason\Projects\brain-plugin` · remotes: `origin`=github.com/karch4162/brain-plugin (personal lineage), `vendsy`=github.com/vendsy/tray-brain-plugin (Tray-internal) — both **PRIVATE** |
| **Design spec (POC)** | `AI-OS/personal-brain/docs/second-brain-poc.md` (mirrored to Confluence "Innovation" space) |
| **Personal pilot vault** | `AI-OS/personal-brain` (git tag `pre-plugin-baseline` = pre-extraction state; `INSTALL_BASELINE.md` = out-of-repo scaffolding inventory) |
| **Tray team vault** | `AI-OS/tray-brain` → github.com/vendsy/tray-brain (PRIVATE); covers `Tray/tray_pos_flutter` (scope `lib/`) |
| **Eval harness** | `brain-plugin/eval/` (§10 with/without measurement; scaffolded, awaiting real-repo tasks) |

## Status
- Plugin **extracted, validated, and dogfooded end-to-end on a real proprietary repo** (`tray_pos_flutter`). **§17.1 checkbox 1 (packaging/isolation) MET.**
- `tray-brain` vault is **live**: scaffolding committed, `lib/`-scoped code graph built, wiki seeded (8 draft notes + 1 canonical link-note), graph-before-grep hook firing, `/doctor` clean of brain errors.
- **Next milestone:** the §10 eval on a real Tray repo (hub/POS) = **checkbox 2** = the go/no-go for team rollout.

## The plugin (what's inside `brain/`)
- `.claude-plugin/plugin.json` · `commands/` (save · resume · freshness · wiki-ingest · init · doctor → user-typed `/brain:*`) · `skills/` (same set, the authority each command reads; init's skill is `brain-init`) · `hooks/hooks.json` + `graph-before-grep.mjs` (auto-loaded) · `bin/` (sync-graph · freshness · build-community-notes · harvest-chats) · `templates/` (CLAUDE.brain.md = the policy, governance files, vault skeleton, registry example).
- Repo root also: `eval/`, `README.md` (user-facing, incl. the scenario grid + troubleshooting), this file.

## Locked decisions / frozen contracts (do NOT re-litigate)
- Plugin name `brain`; neutral env var **`BRAIN_ROOT`** = the consumer contract. Track B consumer (`ai-agent-manager`) reads `graphify-out/graph.json` → `BRAIN_ROOT` → its own memory.
- graphify is **delegated + pinned `==0.8.46`** (not vendored). It's fragile on Windows (reparse/upgrade churn) → `/brain:doctor` repairs it; the §6.1 grep fallback held under every real graphify failure (validates the delegate decision).
- **Graph scope = standard, not per-engineer** (POC §14 lesson 10): code graph = per-stack **app source roots, code-only (AST), tests OUT**, docs→wiki. Recorded in the vault CLAUDE.md repo table; `/brain:save` builds at that scope; engineers never run raw `/graphify`.
- **Docs→wiki (§15.6):** canonical/structured docs = **link-note** (point, don't copy); messy prose = **atomize to draft**. Drafts are low-trust → PR-promoted.
- Machine-specific config (`BRAIN_ROOT`/`REPOS_DIR`) → `.claude/settings.local.json` (gitignored), never the shared `settings.json`.

## Punch-list (open; none blocking)
**Plugin refinements (all sourced from real dogfood use):**
1. ✅ **DONE (2026-06-23)** — **Route the wiki concept-graph build through the host Claude session** so it builds keyless. `/brain:save` step 5c now delegates to the **`/graphify` _skill_** (`/graphify wiki --update`), whose host-session subagent dispatch does the prose semantic extraction with no GEMINI/ANTHROPIC key (graphify SKILL Step 3 Part B), instead of shelling out to the API-keyed `graphify` CLI binary. Same correction mirrored in `templates/CLAUDE.brain.md`. The keyless path already existed in graphify; the bug was brain calling the CLI not the skill.
2. ✅ **DONE (2026-06-23)** — **Offer the initial wiki seed at `/brain:init`.** Root cause was a latent gap: `/brain:save` step 5 only built repos that *already* had a `graphify/<repo>/` mirror, so a fresh vault had no covered repo and the first build never fired. Fixed in two coordinated edits: (a) `save` step 5 now treats a repo listed in the CLAUDE.md scope table with **no graph yet** as a first/full build (vs `--update` thereafter); (b) `brain-init` step 7 now **offers** "seed now?" via `AskUserQuestion` and, on yes, runs `/brain:save` to do the first build + first docs-ingest + keyless wiki graph + commit. Save's Notes document its dual role (seed + session-save).
3. **`/brain:init` remote handling:** match the user's git protocol (HTTPS vs SSH) + offer `gh repo create` (the SSH-remote headache).
4. **Backfill `personal-brain/CLAUDE.md`** with the scope policy + a Scope column (spawned as chip `task_85cb7ef2`); verify volleyball-stats' real source root (top-level showed `app/`, not `lib/`).
5. **`/brain:promote` helper — draft→trusted (spec'd 2026-06-24, build later).** New skill + thin `commands/promote.md`. Automates the mechanical toil the README "Promoting a draft → trusted" section now describes, **keeping the human as the gate** (never auto-promotes). Flow: (a) list `wiki/_drafts/` (optional arg = one draft or all); (b) **validate/complete frontmatter** — ensure `owner` (default to git user), a `source:` anchor, `last_verified`=today, `confidence`; flag anything missing for the human to confirm; (c) **pick the target** — `wiki/<area>/` from the note's id-prefix/tags, or `wiki/bridges/` for a cross-repo contract; ask if ambiguous; (d) move out of `_drafts/`, add a line to `wiki/index.md`, ensure a `Code:` `[[_COMMUNITY_*]]` link line (warn if absent); (e) **stage for a PR — do not commit** (trusted notes are intentionally off `.saveinclude`; the PR *is* the promotion, per the push guardrail). Complements `/brain:freshness` (rot review) — promote handles the draft lifecycle. Pairs with #8: #8 stops junk drafts at the source, promote graduates the good ones.
6. ✅ **DONE (2026-06-24)** — **Version-per-release discipline, single-source.** A *directory-marketplace* install is a cached **copy**; `claude plugin update` keys off the `version` string, so shipping behavior changes without bumping `version` silently freezes every install at its first-installed commit (`marketplace update` doesn't refresh the cache; `plugin update` reports "already at latest"). Now at **0.2.0**. **Version lives in ONE file:** Claude Code resolves version from `plugin.json` first (then marketplace entry, then commit SHA), so `marketplace.json` **omits** `version` — verified `plugin update` still resolves 0.2.0 from `plugin.json` alone. **Release flow: bump `plugin.json` version only → `claude plugin tag ./brain` → branch/PR → consumers `marketplace update` + `plugin update`.** No built-in bump command (`tag` tags, doesn't bump). Discovered when the install was found pinned to `1ec0d07`, 11 commits behind `main`, missing both features *and* `/brain:doctor`.
7. ✅ **DONE (2026-06-24)** — **Document the dev loop** in README: `claude --plugin-dir ./brain` + `/reload-plugins` for live iteration, and the `uninstall`+`install` fallback to force a stale cache current without a version bump.
8. **Docs-ingest allow-list — per-repo, heuristic fallback (spec'd 2026-06-24, build later; Mason's recollection from the sports-management pilot).** Today `/brain:save` step 5b ingests docs by a **fuzzy heuristic** ("`docs/` + `README` + top-level design docs"), which risks atomizing unrelated/random `.md` into drafts. Make the ingest set **explicit and curated per repo**: a `.brain-docs`-style allow-list file in the repo root (one path/glob per line, `#` comments — same format as `.saveinclude`/`.graphifyignore`; it **travels with the code** like `.graphifyignore`). Semantics: step 5b ingests **only** files matching the allow-list; the §15.6 split (canonical→link-note, prose→draft) is unchanged — the list only scopes *which* files are eligible. **Default when the file is absent: fall back to today's heuristic** (decided — gentle, no regression for repos that haven't adopted it). Build tasks: (a) ship `templates/brain-docs` example; (b) wire step 5b to resolve `<repo>/.brain-docs` (allowlist globs) → else heuristic; (c) optionally have `/brain:init` offer to scaffold a `.brain-docs` for the repo. Note: distinct lever from `.graphifyignore` (that's an *exclude* list for graphify's view; this is an *include* list for wiki docs-ingest) — don't conflate. Naming (`.brain-docs` vs `.docsinclude`) is a build-time call.

**Vault tasks (Mason):** promote the 8 `tray-brain` drafts → trusted `wiki/` via PR + `index.md`; fix the `owner:` placeholder; push `tray-brain` (`git push origin main` — remote is HTTPS now) and `brain-plugin` `origin` (the user's settings deny-rule blocks *agent* pushes to `origin main`).

## How to continue
- **Harden the plugin:** #1/#2/#6/#7 shipped (v0.2.0). Open: #3 (init remote handling), #4 (backfill personal-brain CLAUDE.md), #5 (`/brain:promote`), #8 (docs-ingest allow-list). #5 + #8 are the wiki-maintainability pair (spec'd, ready to build).
- **Advance to team rollout:** author the §10 eval tasks against hub/POS and run `brain-plugin/eval/` (see `eval/README.md`). That's checkbox 2 — the actual go/no-go for teams.

## Bugs already fixed in the dogfood (don't re-find these)
scaffolding-not-committed (`/brain:init` now does an initial commit) · docs-ingest first-run (was skipping never-ingested docs) · SSH-vs-HTTPS remote · docs-ingest gating · **dead hook** (`plugin.json` redundantly referenced `hooks/hooks.json` which auto-loads → hook-load failed; **`claude plugin validate` does NOT catch runtime hook-load dups — `/doctor` does**) · `REPOS_DIR` fixed-layout assumption.

## IP / ownership note
License is a placeholder `MIT` in the manifests; **no `LICENSE` file written** pending Mason's ownership clarification with Tray (he wants a personal productization lineage separate from the Tray-internal copy — MIT does NOT protect that; ownership/employment agreement is the real lever). Resolve before sharing with the team. Personal repo = `brain-plugin`, Tray repo = `tray-brain-plugin` (clean lineage split).
