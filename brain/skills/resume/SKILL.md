---
name: resume
description: "Load prior brain session context before starting work. Reads the most recent logs/ entries, the hot.md cache, and relevant wiki notes so the agent picks up where the last session left off. Trigger: /brain:resume (when working in a brain vault)."
---

# /brain:resume — load brain session context

Run at the **start** of a working session in a brain vault to rehydrate context the way `/brain:save` left it. This is the read half of the session-continuity loop; [[save]] is the write half.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd); all paths below are relative to it.

## What to do when invoked

Do these in order; keep the summary tight (the user wants to start working, not read a report).

1. **Read the hot cache.** Read `wiki/hot.md` — the ~500-word rolling summary of current focus, graph entry vocabulary, and active gotchas. This is the single highest-signal file.

2. **Read the 3 most recent session logs.** List `logs/` and read the newest 3 `YYYY-MM-DD-*.md` files (ignore `.gitkeep`). Pull out: decisions made, and anything under a "Pending / next steps" heading that is still open.

3. **Pull relevant wiki notes.** Based on what the user says they're about to work on (or, if they said nothing, the focus in `hot.md`):
   - Skim `wiki/index.md` for the area's notes.
   - Read the specific notes that match the task. Honor the [[3-step query rule]]: if the task is structural, also note which `graphify/<repo>/graph.json` mirror to query.

4. **Surface open loops.** If any recent log has unresolved "Open decision" / "NEXT" items, list them — these are the things most likely to have been forgotten between sessions.

## Output format

Keep it to ~10 lines:

```
Resumed. Last session: <date> — <one-line what happened>.
Focus: <from hot.md>.
Open loops:
  - <pending item> (from <log>)
  - <pending item>
Relevant notes for "<this task>": [[note]], [[note]]; graph mirror: graphify/<repo>/graph.json
```

Then ask what they want to tackle, or proceed if they already said.

## Notes

- Read-only. `/brain:resume` never writes — it only loads context. The mirror of this is [[save]].
- If `logs/` has fewer than 3 entries, read what exists.
- Don't dump full file contents into the chat; synthesize.
