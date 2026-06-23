---
name: save
description: "Persist the current brain working session: write a dated session log, refresh the hot.md cache, append to the operation log, and sync any changed graph mirrors. Trigger: /brain:save (when working in a brain vault)."
---

# /brain:save — persist brain session context

Run at the **end** of a working session in a brain vault. This is the write half of the session-continuity loop; [[resume]] reads back what this writes.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd). All paths below are relative to it. Bundled scripts live at `${CLAUDE_PLUGIN_ROOT}/bin/`.

## What to do when invoked

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

3. **Refresh `wiki/hot.md`.** Update the `_Last refreshed:_` date and rewrite the "Current focus" section to reflect where things actually stand now. Keep it ≤ ~500 words. Don't let it accrete — replace stale bullets, don't just append.

4. **Append one line to `wiki/log.md`** (append-only operation log), e.g.:
   ```
   - <date> — <one-line summary of what this session changed in the vault>.
   ```

5. **Sync graph mirrors if any covered repo's graph changed this session.** A *covered repo* is any repo with a mirror folder under `graphify/<repo>/`. If you ran `/graphify --update`, a graph merge, or edited code in a covered repo such that its `graphify-out/graph.json` changed:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/sync-graph.sh"      # syncs every covered repo whose graph differs from the mirror
   ```
   (Run from the vault root, or with `BRAIN_ROOT=<vault>` set. It is a no-op for unchanged repos and writes its own `log.md` line + commit.) Skip this step if no graph changed.

5b. **Refresh the wiki concept graph if `wiki/` notes changed this session.** The vault's own graph (`graphify-out/graph.json`, built over `wiki/`) goes stale when notes are added/edited. If you created or edited any `wiki/` note, rebuild it incrementally:
   ```bash
   graphify wiki --update                                       # re-extracts only changed notes, re-clusters, refreshes graph.json + GRAPH_REPORT.md
   node "${CLAUDE_PLUGIN_ROOT}/bin/build-community-notes.mjs" graphify-out   # refresh the wiki graph's community stubs so its report links resolve
   ```
   This is the agent-driven refresh (doc changes need the LLM extraction pass; it's not a free git-hook rebuild like the code graphs). The semantic cache means only changed notes re-extract. Skip if no `wiki/` note changed. Commit `graphify-out/graph.json` + `GRAPH_REPORT.md` + `graphify-out/communities/` with the rest (the machine-specific `.graphify_*` files are gitignored).

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
- The mirror of this is [[resume]].
