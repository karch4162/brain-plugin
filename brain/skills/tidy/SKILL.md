---
name: tidy
description: "Apply the mechanical tier of a freshness report as one reviewed batch: re-anchor moved source: paths, index orphans via hub notes, fold singleton tags. Never deletes notes or edits facts — judgment findings stay in the queue. Trigger: /brain:tidy, or 'fix the freshness findings' / 'clean up the wiki'."
---

# /brain:tidy — apply the mechanical tier of the freshness queue

Companion to `/brain:freshness`. Freshness produces the review queue; tidy turns the **mechanical, non-destructive** subset into one proposed batch, gets a single approval, and applies it. Per POC §8 the human stays in the loop — tidy just moves the gate from "85 individual decisions" to "one review of a diff."

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

**Hard limits — never crossed, regardless of what the report says:**
- Never delete or archive a note.
- Never change a note's body/fact content. Only frontmatter (`source:`, `tags:`), wikilinks, `wiki/index.md`, and new hub notes.
- Trusted-note edits land via branch + PR per the vault's `CLAUDE.md`; direct commits only for `wiki/_drafts/` and `logs/`.

## What to do when invoked

### 0. Open a session record — first, before any file work

On the vault's protected/default branch `--start` **creates the working branch**, so it must run before anything is read or written: step 4 branches and commits, and a branch change made later would invalidate every check that preceded it. It also publishes the fact that this session is live, so a concurrent brain command can see you.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start tidy   # from the vault root, or with BRAIN_ROOT=<vault> set
```

- **Exit `0`, first line `SESSION: OK` →** recorded, and you are on a working branch. Go on to step 1.
- **Exit `0`, first line `SESSION: WARN` →** proceed, but **another session is live against this vault.** Relay the script's `SESSION: WARN` line to the user **verbatim** — it names the other session's branch and pid; do not paraphrase or re-derive it. Treat it like step 2b's open-PR finding: context that shapes what you dare batch, not a stop.
- **Exit `1`, first line `SESSION: REFUSED` →** **stop here and change nothing.** Relay the script's `SESSION: REFUSED` line to the user **verbatim** — it names the reason and the remedy — and **do not work around it with a raw `git checkout` / `git switch`.** The branch state it refused on is exactly what the guard is protecting.

### 1. Get a current report

Use today's `logs/freshness-<date>.md` if it exists; otherwise run the scan first:

```bash
node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs"
```

Read the report and split every finding into **auto-fixable** vs **judgment** (below). Findings from a stale report may already be fixed — the scan-first rule avoids re-fixing.

### 2. Classify

**Auto-fixable (tidy handles these):**

- **Broken `source:` anchor, target relocated** — the file exists elsewhere under `REPOS_DIR`, typically at a known prefix (e.g. notes anchored `nodejs/...` while code lives at `monorepo/nodejs/...`). Detect the prefix by probing: for each broken source, search for the path suffix under `REPOS_DIR` (`Glob`/`fd`, not a full grep sweep). **Only rewrite an anchor whose corrected path you verified exists on disk.** One consistent prefix across a note family is the expected shape; a source that resolves to multiple candidates is a judgment item.
- **Orphan notes** — clear them by *linking, not listing*: for each orphaned family (same folder / id prefix), create or extend a **hub note** (e.g. `wiki/nodejs/nodejs-lambdas.md`) with a one-line-per-note `[[wikilink]]` list, then add the hub itself to `wiki/index.md`. This clears the orphan flag (any inbound `[[link]]` counts, including from `wiki/index.md`/`wiki/hot.md`) *and* reattaches the detached graph clusters in the same stroke — prefer it over 85 raw `index.md` lines. Hub notes carry normal frontmatter (`tags`, `source:` pointing at the family's repo dir). Orphans in `wiki/_drafts/` are **left alone** — drafts are staging by design.
- **Singleton tags with an obvious canonical** — fold only when a higher-frequency near-synonym already exists in the report's tag landscape (`configuration`→`config`, `deploy`/`deployment`→ the dominant one). No obvious canonical → judgment item, not a coin-flip.

**Judgment (present, do NOT fix):**

- Dead `[[wikilinks]]` (is the fact gone, or the note unwritten?), stale `last_verified` (needs re-verification against code), any broken source whose repo isn't cloned locally at all (the fix is a clone, not a rewrite), note deletion/archival of any kind, singleton tags with no clear canonical.

### 2b. Check for open PRs touching the same notes

Tidy rewrites frontmatter in **trusted** notes, so a concurrent PR on the same file is a real collision. Before proposing the batch:

```bash
git fetch --prune
for n in $(gh pr list --json number --jq '.[].number'); do
  echo "--- #$n"; gh pr diff "$n" --name-only
done
```

Intersect with every note in the planned batch, plus `wiki/index.md`.

- **Overlap → drop those notes from the auto-fixable set** and list them as blocked, with the PR number. Tidy is a mechanical lane; a contested file is by definition not mechanical. The rest of the batch proceeds.
- **No overlap → print nothing.**
- `gh` missing, unauthed, or offline → one line saying the check was skipped, then continue.

### 3. Propose one batch, get one approval

Before touching anything, show the full plan compactly: N anchors rewritten (with the prefix rule), M hub notes created (named, with member counts), K tag folds (old→new), and the judgment items left for the user. **Wait for a yes.** If the user pre-authorized ("just fix the obvious ones"), proceed.

### 4. Apply on a branch

1. Branch in the vault repo (e.g. `tidy/freshness-<date>`).
2. Apply the batch: `source:` rewrites and tag folds are frontmatter-only edits; hub notes are new files plus their `wiki/index.md` lines.
3. **Verify by re-running the freshness scan** — the fixed categories' counts must drop and no new dead links may appear (a hub note with a typo'd `[[link]]` creates one; fix before shipping).
4. Commit and open a PR per the vault's convention. Report before/after counts and the remaining judgment queue in the PR body and to the user.

### 5. Close the session record

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end   # from the vault root, or with BRAIN_ROOT=<vault> set
```

Run it once the PR is open — or on any early exit (nothing auto-fixable, no approval). A lingering record only costs a spurious `SESSION: WARN` next time, but tidiness is cheap.

## Notes

- Tidy is idempotent: re-running against a clean report is a no-op.
- Writes are limited to `wiki/` (notes, hubs, `index.md`) and the vault git branch. The `logs/` report is only written if tidy had to run the scan itself.
- Keep hub notes honest: a hub is an index of an existing family, not a place to author new facts.
