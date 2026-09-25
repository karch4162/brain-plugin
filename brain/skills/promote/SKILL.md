---
name: promote
description: "Guided draft→trusted promotion: triage wiki/_drafts/ (keep / merge / drop), validate frontmatter, file into the right wiki area + index, and stage the batch as a PR. Never auto-promotes — the human is the gate; the PR is the promotion. Trigger: /brain:promote [draft-name|all], or 'promote the drafts' / 'graduate the drafts'."
---

# /brain:promote — graduate drafts to trusted wiki

## Portable hosts and URL-backed vaults

In Codex, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Companion to `/brain:wiki-ingest` (which creates drafts) and `/brain:freshness` (which flags rot). Ingest fills `wiki/_drafts/`; promote is the review gate that empties it. It automates the mechanical toil of the README's "Promoting a draft → trusted" flow while **keeping the human as the gate**: nothing moves without a per-draft decision, and trusted-note changes ship as a PR — the PR *is* the promotion.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

**Hard limits:**
- Never move a draft to trusted `wiki/` without an explicit keep decision from the user.
- Never commit trusted-note changes directly — always branch + PR (trusted areas are intentionally off `.saveinclude`; the push guardrail stands).
- Never invent facts to fill frontmatter gaps: propose, flag, and let the user confirm.
- Deleting a dropped draft is allowed (drafts are staging, direct-commit territory) — but only after the user chose **drop**.

## What to do when invoked

### 0. Open a session record — first, before any file work

On the vault's protected/default branch `--start` **creates the working branch**, so it must run before anything is read or written: step 5 branches, moves files and opens a PR, and a branch change made later would invalidate every triage decision that preceded it. It also publishes the fact that this session is live, so a concurrent brain command can see you.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start promote   # from the vault root, or with BRAIN_ROOT=<vault> set
```

- **Exit `0`, first line `SESSION: OK` →** recorded, and you are on a working branch. Go on to step 1.
- **Exit `0`, first line `SESSION: WARN` →** proceed, but **another session is live against this vault.** Relay the script's `SESSION: WARN` line to the user **verbatim** — it names the other session's branch and pid; do not paraphrase or re-derive it. It is the in-checkout twin of step 1b's open-PR check: same collision risk, closer to home.
- **Exit `1`, first line `SESSION: REFUSED` →** **stop here and change nothing** — no triage, no moves, no PR. Relay the script's `SESSION: REFUSED` line to the user **verbatim** — it names the reason and the remedy — and **do not work around it with a raw `git checkout` / `git switch`.** The branch state it refused on is exactly what the guard is protecting.

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
- a `source:` anchor — the `repo/file#anchor`, PR, or commit that makes the fact true. **Whether it resolves is decided by the script below, never by your reading of the path.**
- `last_verified:` = today — but only after you actually re-checked the claim against the source (a promote is a verification event, not a rubber stamp).
- an honest `confidence` — promotion usually raises `low` → `medium`; only the user can call `high`.

**Then run the anchor gate — don't reason about it, run it.** The trusted tier's only claim to trust is the anchor, so it is checked mechanically, with the *same* resolver `/brain:freshness` uses (`repos.json` identity keyed on the git remote, sub-path repos, pinned revisions via git — not path-guessing under `REPOS_DIR`):

```bash
node "${CLAUDE_PLUGIN_ROOT}/bin/check-anchors.mjs" wiki/_drafts/<keeper>.md [...]   # from the vault root, or with BRAIN_ROOT=<vault> set
```
No arguments checks every note in `wiki/_drafts/`. Pass the keepers explicitly when only some drafts are being promoted.

- **Exit `0` (`ANCHORS: OK`) →** every anchor verified on this machine. Go to step 4. The line carries the counts — quote it in the step 5 report.
- **Exit `1` (`ANCHORS: BROKEN`) →** the repo **is** on this machine and the file **is not**: the note points at something that moved. **Those notes do not get promoted this run.** Relay the script's `ANCHORS: BROKEN` line to the user **verbatim** — it names the notes, the anchors and where it looked; do not paraphrase or re-derive it — then either re-anchor to where the fact lives now (a note edit the user approves) and re-run until the script stops naming them, or leave them as drafts. Unaffected keepers may still proceed in the same batch.
- **Exit `2` (`ANCHORS: UNVERIFIABLE`) →** **not a block.** Nothing is broken; these simply could not be checked here (repo claimed by the vault but not cloned, unknown repo prefix, a pinned revision this clone never fetched, a PR/URL that is off-machine, a git-ignored vault file such as a `chats/` digest that exists only on this machine), or a note carries no `source:` at all. Relay the script's `ANCHORS: UNVERIFIABLE` line **verbatim**, then **ask** (`AskUserQuestion`): promote anyway, or hold until the repos are cloned / an anchor is supplied. **Never "resolve" one by editing the note to a path you did not check** — that manufactures a green anchor. A note with no `source:` at all stays a draft unless the user supplies one.
- A vault with no drafts, or a path that isn't there, exits `0` — this is a gate against promoting unverifiable claims, not a file-existence assertion.

> Why this is a script: on 2026-08-04 nine notes were promoted to trusted with `source: hub/docs/…` anchors that could not resolve on the promoting machine. The rule existed — as prose in this file, pointing at a resolution path that no longer matched `freshness.mjs`. Prose drifts; the exit code doesn't. Unverifiable stays a *choice* rather than a block precisely so the choice is made out loud.

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
4. **Close the session record** — `bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end` (from the vault root, or with `BRAIN_ROOT=<vault>` set). Run it on early exits too (empty queue, no decisions, a step 1b blocker). A lingering record only costs a spurious `SESSION: WARN` next time, but tidiness is cheap.
5. Report the same summary to the user, plus the new `_drafts/` count (goal: zero or a short, young queue) and step 3's `ANCHORS:` verdict line with its counts — including how many promoted notes went out with an anchor that could not be verified here, and on whose say-so.

## Notes

- Promote is the missing rung of the ladder: transient → draft (ingest) → **trusted (promote)** → law (project CLAUDE.md/docs). Without it, drafts are a write-only dead zone.
- Idempotent: re-running with an empty `_drafts/` is a no-op that says so.
- Writes are limited to `wiki/` and the vault git branch; nothing outside the vault is modified (auto-memory pointer edits are suggested to the user, not performed here).
