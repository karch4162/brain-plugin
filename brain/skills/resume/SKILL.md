---
name: resume
description: "Load prior brain session context before starting work. Reads the most recent logs/ entries, the hot.md cache, and relevant wiki notes so the agent picks up where the last session left off. Trigger: /brain:resume (when working in a brain vault)."
---

# /brain:resume — load brain session context

Run at the **start** of a working session in a brain vault to rehydrate context the way `/brain:save` left it. This is the read half of the session-continuity loop; [[save]] is the write half.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd); all paths below are relative to it.

## What to do when invoked

Do these in order; keep the summary tight (the user wants to start working, not read a report).

1. **Sync refs and see what's in flight.** Before reading anything, `git fetch --prune` (safe here — it touches refs, not the working tree), then list open PRs:
   ```bash
   git fetch --prune
   gh pr list --json number,title,author,headRefName --jq '.[] | "#\(.number) \(.title) — \(.author.login)"'
   ```
   A current `main` does **not** mean the vault is uncontested: a PR opened minutes ago can be rewriting the very note you're about to touch. Report them in the `In flight:` line below. If `gh` is missing, unauthed, or offline, say so in one line and carry on — this is context, not a gate.

2. **Read the hot cache.** Read `wiki/hot.md` — the ~500-word rolling summary of current focus, graph entry vocabulary, and active gotchas. This is the single highest-signal file.

3. **Read the 3 most recent session logs.** List `logs/` and read the newest 3 `YYYY-MM-DD-*.md` files (ignore `.gitkeep`). Pull out: decisions made, and anything under a "Pending / next steps" heading that is still open.

4. **Pull relevant wiki notes.** Based on what the user says they're about to work on (or, if they said nothing, the focus in `hot.md`):
   - Skim `wiki/index.md` for the area's notes.
   - Read the specific notes that match the task. Honor the [[3-step query rule]]: if the task is structural, also note which `graphify/<repo>/graph.json` mirror to query.

5. **Surface open loops.** If any recent log has unresolved "Open decision" / "NEXT" items, list them — these are the things most likely to have been forgotten between sessions.

## Output format

Keep it to ~10 lines:

```
Resumed. Last session: <date> — <one-line what happened>.
Focus: <from hot.md>.
In flight: #<n> <title> (<author>)      ← omit the line entirely if no PRs are open
Open loops:
  - <pending item> (from <log>)
  - <pending item>
Relevant notes for "<this task>": [[note]], [[note]]; graph mirror: graphify/<repo>/graph.json
```

Then ask what they want to tackle, or proceed if they already said.

## Notes

- Read-only. `/brain:resume` never writes — it only loads context (`git fetch` updates refs but never the working tree). The mirror of this is [[save]].
- **`In flight:` is context, not a gate.** Never tell the user to merge someone else's PR before they can work — it may be a draft, under review, or not theirs. The write-side commands ([[promote]], [[tidy]]) do the file-level collision check that actually blocks.
- If `logs/` has fewer than 3 entries, read what exists.
- Don't dump full file contents into the chat; synthesize.
