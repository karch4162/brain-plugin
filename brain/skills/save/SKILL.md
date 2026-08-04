---
name: save
description: "Persist the current brain working session: write a dated session log, refresh the hot.md cache, append to the operation log, and sync any changed graph mirrors. Trigger: /brain:save (when working in a brain vault)."
---

# /brain:save — persist brain session context

Run at the **end** of a working session in a brain vault. This is the write half of the session-continuity loop; [[resume]] reads back what this writes.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd). All paths below are relative to it. Bundled scripts live at `${CLAUDE_PLUGIN_ROOT}/bin/`.

## What to do when invoked

0. **Check branch freshness before touching `wiki/hot.md`.** Step 3 **rewrites** hot.md, so a stale base silently reverts whatever anyone else landed on it. Measure the gap first:
   ```bash
   git fetch --prune                                   # refs only — does not touch the working tree
   git rev-list --count HEAD..origin/main              # commits this branch is behind
   git status --porcelain wiki/hot.md                  # uncommitted local edits to hot.md?
   ```
   - **Count `0` →** proceed normally.
   - **Count `> 0` → refuse to rewrite `wiki/hot.md` from this base.** There is no safe merge for a full-file rewrite: **bring the branch up to date first (`git rebase origin/main` or `git merge origin/main`), then re-run `/brain:save`.** Do not "carefully merge by hand" and do not rewrite anyway — say plainly that the branch is `<n>` commits behind and stop at step 3.
   - **`wiki/hot.md` already has uncommitted changes →** they are about to be overwritten by the rewrite. Show them (`git diff wiki/hot.md`) and ask the user before continuing; if they're this session's own work in progress, continue.
   - **`origin/main` unreachable** (offline, no remote, fetch fails) → say so in **one line** ("freshness check skipped — origin unreachable") and continue. This is a guard, not a network dependency.
   - **Only the hot.md rewrite is blocked.** The session log (step 2), the `wiki/log.md` line (step 4), and the graph builds/sync (steps 5–5c) are **append-only or additive** — a stale base cannot revert anything through them. On a stale branch, do every other step, skip step 3, and report it in the output.

1. **Get today's date** (do not guess):
   ```bash
   date +%F
   ```
   Use it for the log filename and the `last_verified` / log-line dates below.

2. **Write the session log** to `logs/<date>-<slug>.md`, where `<slug>` is a short kebab-case summary of the session's theme. Use this structure (mirror existing logs in `logs/` for tone):
   ```markdown
   # <date> — <Title>

   ## What happened
   <2-4 sentences>

   ## Decisions
   - <decision>, with the why and any [[wiki-note]] it created or changed

   ## Pending / next steps
   - <open item>  ·  mark resolved ones ✅ DONE
   - **Open decision for the user (if any):** <question>

   ## Files touched
   - <path> — <what changed>
   ```
   Be honest in "Pending" — this is what `/brain:resume` surfaces next time. Don't claim things are done that aren't.

3. **Refresh `wiki/hot.md` — rewrite, never append.** This is a *rolling cache*, not a log; the session history already lives in `logs/` (step 2), so nothing is lost by deleting from here. Concretely:
   - Update the `_Last refreshed:_` date.
   - **Rewrite** "Current focus" to only what is actually in flight *now*. **Delete** any bullet describing a prior session or work that's finished — do not add "Prior session:" bullets, ever.
   - **Hard budget: after your edit, the whole file must be ≤ ~500 words.** If it's over, keep cutting — oldest/stalest bullets first — until it isn't. Roughly: if a bullet wouldn't change what the next session does, it goes.
   - **Measure it — don't eyeball it.** After every edit to the file, run `wc -w wiki/hot.md`; if the count is over 500, cut and re-run until it isn't. The budget is not met until the command says so.
   - Why this is enforced: `/brain:resume` reads this file first every session, and step 5c re-extracts it into the wiki concept graph on every save — a bloated hot.md makes *every* future save slower and noisier. `/brain:freshness` flags the file when it exceeds ~750 words; treat that finding as "this step was skipped."

4. **Append one line to `wiki/log.md`** (append-only operation log), e.g.:
   ```
   - <date> — <one-line summary of what this session changed in the vault>.
   ```

5. **Build repo graphs at the standard scope, then sync mirrors.** A *covered repo* is any repo that has a mirror folder under `graphify/<repo>/` **or** is listed in the vault `CLAUDE.md` "Repos this brain covers" table — the latter catches a freshly-`/brain:init`-ed repo whose **first** graph hasn't been built yet (this is the seed `/brain:init` offers; `/brain:save` is the one place builds actually run). Build a covered repo when its **source changed this session** *or* it has **no graph yet** (first build / seed):
   - **Build at the recorded scope, code-only (AST), never prompt for scope.** Read the repo's scope from the vault `CLAUDE.md` "Repos this brain covers" table (e.g. `lib/`) and build over exactly those source roots. Do a **full build on the first run** (no `graphify-out/graph.json` in the repo yet) and an **incremental `--update`** every time after:
     ```bash
     ( cd "$REPOS_DIR/<repo>" && graphify <source-roots> )            # FIRST build (no graphify-out/ yet): full AST extraction, creates the graph
     ( cd "$REPOS_DIR/<repo>" && graphify <source-roots> --update )   # thereafter: incremental ⇒ pure AST, free/fast, no subagents, no scope prompt
     ```
     The scope is predetermined (CLAUDE.md) — do **not** ask the user to choose, and do **not** run `graphify .` (that pulls in tests/docs/platform/deps and triggers the "pick a subfolder" prompt). Tests/docs/platform/deps are excluded simply by being outside the source roots. Both forms are code-only (AST): free, fast, keyless.
   - **Sync the mirrors:**
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/bin/sync-graph.sh"      # copies each repo's graphify-out → graphify/<repo>/ (creates the mirror on first sync)
     ```
   (Run from the vault root, or with `BRAIN_ROOT=<vault>` set. Sync is a no-op for unchanged repos and writes its own `log.md` line + commit.) Skip if no covered repo's source changed **and** every covered repo already has a graph.

5b. **Ingest changed repo docs into the wiki (§15.6 split) — incremental, the standard docs→wiki path (no separate command).** For each covered repo, check its `docs/` + `README` + top-level design docs for files changed since the last save. By type:
   - **Canonical / structured** (contracts, standards, machine-readable specs, "drift is a defect" docs): create/update a **link-note** in `wiki/<area>/` that *points at* the doc (`source:` anchor + provenance) and summarizes what it governs — **do not copy its values** into the note (that creates a fourth drift source).
   - **Messy / tribal prose** (plans, scattered rationale): distill durable, reusable facts into atomic **draft** notes in `wiki/_drafts/` (low-trust → PR-promoted), one fact per note, per the `CLAUDE.md` note convention. Skip transient/duplicate content; check `wiki/index.md` first.
   **First ingest for a repo** (no link-notes / draft notes derived from its docs exist yet — e.g. a freshly onboarded repo): ingest **all** of its docs, not just recently-modified ones. **Thereafter:** only docs changed since the last ingest (track via a small manifest or the notes' `source:` anchors). Docs-ingest is **independent of code changes** — a repo whose source didn't change this session can still have un-ingested docs; don't gate it on "source changed." Skip only if every covered repo's docs are already fully ingested and unchanged.

5c. **Refresh the wiki concept graph if `wiki/` notes changed this session** (including any notes 5b just wrote)**.** The vault's own graph (`graphify-out/graph.json`, built over `wiki/`) goes stale when notes are added/edited. This refresh is **agent-driven**: unlike the code graphs (free, pure-AST, auto-fresh on every commit), prose notes need an LLM extraction pass. Run that pass **through the graphify _skill_ — this host session is the LLM** — never through the bare CLI:
   - **Invoke the graphify skill on `wiki/`.** From the vault root, run the skill (`Skill` tool, `skill: "graphify"`) scoped to the `wiki/` folder — **incremental** if a wiki graph already exists, **full** on the first build:
     - If `graphify-out/graph.json` exists → argument `wiki --update` (the `--update` flow; only changed notes re-extract via the semantic cache).
     - If it does **not** exist (first-ever wiki build for this vault) → argument `wiki` (a full build; `--update` has no baseline to diff against and would no-op).

     Because a stock Claude Code env sets **no** `GEMINI_API_KEY`/`GOOGLE_API_KEY`, the skill falls straight through to **host-session subagent dispatch** (graphify SKILL.md Step 3 Part B) for the notes' semantic extraction. This builds **keyless** — no `GEMINI`/`ANTHROPIC` key and no local ollama required. graphify does **not** read `ANTHROPIC_API_KEY`; if anything prompts for one, that's a misread of the graphify skill — ignore it.
   - **If the `/graphify` skill isn't available** (not in the skill list / `~/.claude/skills/graphify/SKILL.md` missing — the CLI installs separately from the skill), **fix it, don't defer it**: run `graphify install --platform claude`, tell the user the skill activates after a session restart (or `/reload-plugins`), and note the wiki-graph refresh as the first step of the next session. Never park this as a vague "open loop" without the one-line fix — a stale concept graph quietly degrades every future query.
   - **Do NOT shell out to the bare `graphify wiki --update` CLI binary.** That entrypoint sends prose semantic extraction to an API-keyed backend (gemini/openai/…); in a keyless env it can't build the concept-graph layer — the exact gap this step exists to close. The distinction is the leading slash: the **`/graphify` skill** (host session) is keyless; the **`graphify` binary** is not, for prose.
   - **Then refresh the wiki graph's community stubs** so its report links resolve:
     ```bash
     node "${CLAUDE_PLUGIN_ROOT}/bin/build-community-notes.mjs" graphify-out
     ```
   Skip if no `wiki/` note changed. Commit `graphify-out/graph.json` + `GRAPH_REPORT.md` + `graphify-out/communities/` with the rest (the machine-specific `.graphify_*` files are gitignored).

6. **Commit only the `.saveinclude` allowlist.** `/brain:save` **never** runs `git add -A`. Stage exactly the paths listed in `.saveinclude` (one path/glob per line; `#` comments and blank lines ignored), so private content — harvested `chats/` (also gitignored), or anything kept off the list — is never published by accident:
   ```bash
   grep -vE '^\s*(#|$)' .saveinclude | xargs -r git add --
   git commit -m "save: <date> session — <slug>"
   ```
   The default allowlist covers `logs/`, `wiki/hot.md`, `wiki/log.md`, and the `graphify-out/` graph artifacts. **Customize what `/brain:save` may commit by editing `.saveinclude`** — add a path to allow it, leave a path off to keep it local/manual. **Trusted `wiki/` notes are intentionally not allowlisted** — knowledge changes to trusted notes go via PR, staged separately. **Do not `git push` unless the user asks.**

## Output format

```
Saved. Log: logs/<date>-<slug>.md
hot.md refreshed · log.md appended
Graph sync: <synced repos | not needed this session>
Committed locally (not pushed). Open loops carried forward: <n>
```

## Notes

- One log per session; if `/brain:save` runs twice in a day, append to or supersede the existing dated log rather than creating a collision.
- **`/brain:save` is also the seed mechanism.** `/brain:init` offers to run it for the **first** build (step 5 treats a scope-table repo with no graph yet as a first/full build). So the first invocation may be a seed, not an end-of-session save — the log slug should reflect that ("seed brain for <repo>").
- The mirror of this is [[resume]].
