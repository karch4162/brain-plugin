---
name: promote
description: "Guided draft→trusted promotion: triage wiki/_drafts/ (keep / merge / drop), validate frontmatter, file into the right wiki area + index, and stage the batch as a PR. Never auto-promotes — the human is the gate; the PR is the promotion. Trigger: /brain:promote [draft-name|all], or 'promote the drafts' / 'graduate the drafts'."
---

# /brain:promote — graduate drafts to trusted wiki

Companion to `/brain:wiki-ingest` (which creates drafts) and `/brain:freshness` (which flags rot). Ingest fills `wiki/_drafts/`; promote is the review gate that empties it. It automates the mechanical toil of the README's "Promoting a draft → trusted" flow while **keeping the human as the gate**: nothing moves without a per-draft decision, and trusted-note changes ship as a PR — the PR *is* the promotion.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

**Hard limits:**
- Never move a draft to trusted `wiki/` without an explicit keep decision from the user.
- Never commit trusted-note changes directly — always branch + PR (trusted areas are intentionally off `.saveinclude`; the push guardrail stands).
- Never invent facts to fill frontmatter gaps: propose, flag, and let the user confirm.
- Deleting a dropped draft is allowed (drafts are staging, direct-commit territory) — but only after the user chose **drop**.

## What to do when invoked

### 1. List the queue

Optional arg = one draft name or `all` (default: all). For each `wiki/_drafts/*.md`, show a one-line triage row: name, one-sentence gist, `confidence`, **age in days** (from frontmatter date or file mtime), and a duplicate check against `wiki/index.md` and existing trusted notes (same topic → likely **merge**, not keep).

**Stale-draft rule (TTL 14 days):** a draft older than 14 days gets no special mercy — it has already proven nothing reads it in staging. Recommend **promote or drop, never "leave in staging"** for these; say so explicitly in the triage row.

### 1b. Check for open PRs touching the same files

`main` being current does **not** mean a note is uncontested. Before triaging, intersect what you are about to write against every open PR:

```bash
git fetch --prune
for n in $(gh pr list --json number --jq '.[].number'); do
  echo "--- #$n"; gh pr diff "$n" --name-only
done
```

Compare that against the drafts you intend to move, their target paths, and `wiki/index.md`.

- **Overlap → stop and surface it** as a triage blocker before asking for any keep/merge/drop decision. Show the PR number, title, and the shared file. Let the user sequence: usually land the other PR first and rebase, since a PR editing a note's *facts* is foundational to promoting it.
- **No overlap → print nothing.** Silence is what keeps this check credible; a banner on every run gets tuned out.
- `gh` missing, unauthed, or offline → say so in one line and continue. Degraded, not blocked.

> Why this exists: on 2026-07-28 a promote graduated a draft to trusted while an open PR — opened 45 minutes earlier — was correcting that same note's facts. The promotion shipped wrong content and had to be rebased. Freshness can't catch this; only the PR list can.

### 2. Triage — keep / merge / drop, per draft

Present a recommendation per draft (`promote to wiki/<area>/` · `merge into [[existing-note]]` · `drop: <reason>`) and collect the user's decisions — one `AskUserQuestion` batch or a pre-authorized rule ("promote all your recommends, drop the rest") is fine. No decision → the draft stays untouched and is reported as still-pending.

### 3. Validate/complete frontmatter (keepers only)

Ensure each keeper has:
- `owner` — default to the vault's git user; flag placeholder owners.
- a `source:` anchor — the `repo/file#anchor`, PR, or commit that makes the fact true. **Verify the anchor resolves** (file exists under `REPOS_DIR` / the PR is real). No verifiable source → tell the user; they either supply one or the note stays a draft.
- `last_verified:` = today — but only after you actually re-checked the claim against the source (a promote is a verification event, not a rubber stamp).
- an honest `confidence` — promotion usually raises `low` → `medium`; only the user can call `high`.

*(Full note schema + one-fact-per-note, tagging, and `[[_COMMUNITY_*]]` code-linking rules live in the vault's own `CLAUDE.md` → "Writing to the wiki" — that's the authority; don't duplicate it.)*

### 4. File

- **Target:** `wiki/<area>/` from the note's id-prefix/tags (e.g. `sm-*` → the sports-management area), or `wiki/bridges/` for a cross-repo contract. Ambiguous → ask.
- Move the file out of `_drafts/`, strip `draft: true`.
- Add a line to `wiki/index.md` (drafts are excluded from the index; promoted notes must join it).
- Ensure a `Code:` `[[_COMMUNITY_*]]` link line; warn if absent rather than fabricating one.
- **Merge decisions:** fold the draft's fact into the existing trusted note (body edit, refresh `last_verified`), then delete the draft. The trusted-note edit rides the same PR.
- **De-duplicate downstream copies:** if the same fact lives in a project's Claude auto-memory or CLAUDE.md, don't fork it — leave a pointer there to the wiki note (wiki is canonical).

### 5. Ship as one PR

1. Branch in the vault repo (e.g. `promote/drafts-<date>`).
2. Commit the moves, index lines, and merge edits. Dropped drafts are deleted in the same branch.
3. Open a PR per the vault's convention. PR body: table of promoted notes (draft → target), merges, drops with reasons, and any still-pending drafts with what blocks them.
4. Report the same summary to the user, plus the new `_drafts/` count (goal: zero or a short, young queue).

## Notes

- Promote is the missing rung of the ladder: transient → draft (ingest) → **trusted (promote)** → law (project CLAUDE.md/docs). Without it, drafts are a write-only dead zone.
- Idempotent: re-running with an empty `_drafts/` is a no-op that says so.
- Writes are limited to `wiki/` and the vault git branch; nothing outside the vault is modified (auto-memory pointer edits are suggested to the user, not performed here).
