---
name: freshness
description: "Run the brain wiki health check (POC §8 freshness agent): orphans, dead [[links]], stale last_verified, broken source anchors. Produces a review queue, never auto-deletes. Trigger: /brain:freshness, or 'lint the wiki' / 'check the brain for rot'."
---

# /brain:freshness — wiki health check

Runs the deterministic freshness scan and turns its output into a triaged review queue. **Nothing is auto-deleted or auto-edited** — per POC §8 the output is a queue a human (or you, with the user's OK) acts on.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

## What to do when invoked

1. **Run the scan** (from the vault root, or with `BRAIN_ROOT=<vault>` set):
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs"               # writes logs/freshness-<date>.md
   # or: node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --stale-days 30   (tighten the threshold)
   ```
   It checks across every `wiki/` note:
   - **Dead `[[wikilinks]]`** — link targets that resolve to no note, community stub, or graph report.
   - **Orphan notes** — notes nothing links to (not in `index.md`/`hot.md`, not linked by any note).
   - **Stale `last_verified`** — frontmatter dates older than the threshold (default 45 days).
   - **Broken `source:` anchors** — a `source:` file path that no longer exists in its repo (resolved against `REPOS_DIR`, default the vault's sibling dir).
   - Plus: missing tags, singleton tags, and whole-vault graph connectivity (detached wiki clusters).

2. **Read the generated report** (`logs/freshness-<date>.md`) and present the findings grouped, **with a recommended disposition per item**, e.g.:
   - dead link → fix the link, create the missing note, or remove the reference?
   - broken source → the source moved/was deleted; re-anchor `source:` or re-verify the fact?
   - stale → re-verify against current code and bump `last_verified`, or the fact is still true (just bump)?
   - orphan → add an `index.md` line / inbound link, or archive the note?

3. **Only act on a finding after the user confirms** (or if they said "just fix the obvious ones"). Link fixes and `index.md` additions are low-risk; deleting/re-verifying facts is a judgment call. Trusted-note edits still follow the PR convention in the vault's `CLAUDE.md`.

## Scheduling (optional)

Run weekly on a real runner (CI / service account), **not** a laptop, per the POC §14.9 lesson. Three portable gotchas that bit the pilot:
- **Use an absolute `node` path** — schedulers run with a minimal PATH.
- **On a laptop, allow-on-battery** — e.g. Windows Task Scheduler defaults to `DisallowStartIfOnBatteries`, so the task reports "Ready"/success but the action silently never runs. Register with `-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable`.
- **Name dated artifacts by local date, not UTC** — the script already does; just don't override it.

Validate a scheduled run actually executed (not just "Ready"/exit 0): confirm a fresh `logs/freshness-<date>.md` appeared — a success code alone can mean a battery/PATH condition skipped the action.

## Notes

- Read-only except the report file under `logs/`.
- Tune `--stale-days` down as the wiki ages; 45 is deliberately loose so a young vault isn't all-stale.
- To apply the mechanical subset of the queue (source re-anchors, orphan indexing, tag folds) as one reviewed batch, follow up with `/brain:tidy`.
