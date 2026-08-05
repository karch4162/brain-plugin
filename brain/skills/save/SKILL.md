---
name: save
description: "Persist the current brain working session: write a dated session log, refresh the hot.md cache, append to the operation log, and sync any changed graph mirrors. Trigger: /brain:save (when working in a brain vault)."
---

# /brain:save — persist brain session context

Run at the **end** of a working session in a brain vault. This is the write half of the session-continuity loop; [[resume]] reads back what this writes.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd). All paths below are relative to it. Bundled scripts live at `${CLAUDE_PLUGIN_ROOT}/bin/`.

## What to do when invoked

0. **Check branch freshness before touching `wiki/hot.md`.** Step 3 **rewrites** hot.md, so a stale base silently reverts whatever anyone else landed on it. Don't reason about this — run the guard, which brings the branch up to date on its own when that's safe:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-freshness.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **Exit `0` (`FRESHNESS: OK`) →** the base is current (fast-forwarded, merged, or already up to date). Do the whole save, step 3 included.
   - **Exit `1` (`FRESHNESS: BLOCKED`) →** skip **step 3 only**. Relay the script's `FRESHNESS: BLOCKED` line to the user **verbatim** — it names the branch, the counts and the remedy; do not paraphrase or re-derive it — and report the skipped hot.md refresh in the output block.
   - **Only the hot.md rewrite is gated.** The session log (step 2), the `wiki/log.md` line (step 4) and the graph builds/sync (steps 5–5c) are **append-only or additive** — a stale base cannot revert anything through them, so they **always** run.

   Offline, no origin, or not a git repo exits `0` — this is a guard, not a network dependency. `--no-merge` reports without mutating.

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
   - **First: `git status --porcelain wiki/hot.md`.** Uncommitted edits here are about to be overwritten by the rewrite and are **not recoverable** — step 0's guard only catches the committed kind. If the file is dirty, show `git diff wiki/hot.md` and ask before continuing; if it's this session's own work in progress, continue.
   - Update the `_Last refreshed:_` date.
   - **Rewrite** "Current focus" to only what is actually in flight *now*. **Delete** any bullet describing a prior session or work that's finished — do not add "Prior session:" bullets, ever.
   - **Hard budget: after your edit, the whole file must be ≤ 500 words.** If it's over, keep cutting — oldest/stalest bullets first — until it isn't. Roughly: if a bullet wouldn't change what the next session does, it goes.
   - **The budget is enforced by a script, not by your judgement.** Don't eyeball it and don't hand-count — after the rewrite, run the guard:
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/bin/check-hot-budget.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
     ```
     - **Exit `0` (`HOT-BUDGET: OK`) →** the file is within budget; go on to step 4. The line reports the actual count, so quote it in the output block.
     - **Exit `1` (`HOT-BUDGET: OVER`) →** **stop here.** Cut the stalest bullets and re-run the script. Repeat until it exits `0`. **Do not proceed to step 4 while it exits `1`**, and do not "fix" it by editing once and assuming — the script's word is the only word. If you end up unable to get under, relay the script's `HOT-BUDGET: OVER` line to the user **verbatim** — it names the count, the budget and the overage; do not paraphrase or re-derive it.
     - A vault with no `wiki/hot.md` yet (mid-setup) exits `0` — this is a bloat guard, not a file-existence check. `HOT_WORD_BUDGET=<n>` overrides the 500-word default.
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
   - **First, get the real changed-note list:**
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/bin/changed-wiki-notes.sh"   # one vault-relative wiki/**/*.md path per line; silent + exit 0 when nothing changed
     ```
     (Run from the vault root, or with `BRAIN_ROOT=<vault>` set. `--since <ref>` also covers notes committed since that ref; `--porcelain` prints a count first.) **This output is the authoritative changed-note list. `manifest.json` over-reports badly — hundreds of notes flagged when ten actually changed — and must never be used to decide what to re-extract**, since 5c dispatches a subagent per changed note. **If the script prints nothing, skip step 5c entirely.**
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
Freshness: <up to date | fast-forwarded from origin/main | BLOCKED — <script's reason>>
hot.md <refreshed (<n> words / <budget> budget) | refresh SKIPPED (branch not fresh)> · log.md appended
Graph sync: <synced repos | not needed this session>
Committed locally (not pushed). Open loops carried forward: <n>
```

## Notes

- One log per session; if `/brain:save` runs twice in a day, append to or supersede the existing dated log rather than creating a collision.
- **`/brain:save` is also the seed mechanism.** `/brain:init` offers to run it for the **first** build (step 5 treats a scope-table repo with no graph yet as a first/full build). So the first invocation may be a seed, not an end-of-session save — the log slug should reflect that ("seed brain for <repo>").
- **Never hand-resolve merge conflicts under `graphify-out/`.** Two independent rebuilds re-cluster and re-label the same communities, so one cluster shows up as a rename/rename conflict between two unrelated-looking names — the "conflict" is cosmetic. **Take one side wholesale — normally the newer build — and let the next step-5c refresh regenerate.** (Learned resolving 143 of these on one PR.)
- The mirror of this is [[resume]].
