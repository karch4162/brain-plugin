# {{VAULT_NAME}} — agent instructions

This repo is a **knowledge base for AI agents** (a "brain" vault). You are reading this because your session has this vault available. Resolve context with the 3-step query rule below before reading raw code.

> Seeded by the `brain` plugin (`/brain:init`). Fill in `{{...}}` placeholders for this vault: its name, the repos it covers, and any vault-specific charter. Keep this file **thin** — it says "go ask the brain," it is not the brain.

## The 3-step query rule

When answering questions about the codebase or making changes, resolve context in this order:

1. **Graph first.** Query the Graphify graph for structural questions — what connects to what, where a concept lives, blast radius of a change. **Traverse the graph; do not `grep`/`rg` raw source to discover structure.**
2. **Wiki second.** Search `wiki/` for decisions, gotchas, contracts, and rationale — the *why* that code can't tell you.
3. **Raw code last.** Only read source files when you are about to edit them, or when 1–2 came up empty.

> **Graph before grep — this is the point of the brain.** A `grep`/`rg`/`Grep` sweep over source to find "where does X live" or "what calls Y" is exactly the stateless re-derivation this vault exists to replace. A self-gating `PreToolUse` hook (shipped by the brain plugin) reminds you of this when you reach for `Grep` while a `graphify-out/graph.json` is present.

> **Staleness rule — the correctness keystone.** The graph reflects the **last commit**. Treat it as authoritative for **pre-existing, committed structure only — NEVER for any file the session is editing or about to edit** (those are read raw, every time). Fall back to raw read/grep when: (a) no `graphify-out/graph.json` is present; (b) the query returns no nodes, collides on a generic term, the hit carries no `source_location`, or `confidence` is weak; or (c) you are about to edit the file. Staleness downgrades a graph answer to a hint, it never errors.

**How to query the graph:**

- **Working inside a covered repo** (cwd has `graphify-out/`): just ask in natural language — the graphify skill auto-detects the local graph and runs `graphify query "<question>"`.
- **Working inside this vault** (querying a mirror): scope by repo —
  ```bash
  graphify query "<question>" --graph graphify/<repo>/graph.json
  graphify path "<A>" "<B>"   --graph graphify/<repo>/graph.json
  ```
  **Always scope by repo** — generic terms collide across repos. Per-repo entry vocabulary lives in `wiki/hot.md`.
- **Querying the wiki itself as a graph** (step 2): the vault's own concept graph lives at `graphify-out/graph.json` (built over `wiki/`). Run `graphify query "<question>"` from the vault root. Its nodes carry the **code-symbol names** the notes reference, so you can hop from a symbol to its rationale in one query. Rebuild after editing notes with `graphify wiki --update` (see [[save]]).

## Writing to the wiki

- **One fact per note.** Atomic notes, cross-linked with `[[wikilinks]]`.
- Every note carries frontmatter:
  ```yaml
  ---
  id: <kebab-case-slug>
  tags: [<cross-cutting>, <topic>, ...]
  source: <repo/file#anchor, PR, or commit that makes this true>
  owner: <github-handle>
  last_verified: <YYYY-MM-DD>
  confidence: high | medium | low
  ---
  ```
- **Namespace by area** (`wiki/<area>/...`); cross-cutting contracts go in `wiki/bridges/`.
- **Tags are the cross-cutting axis** — folders/`id` prefixes scope a note to its repo; `tags` link the *same concept across repos*. Aim for 2–4 tags and **reuse existing tags** rather than coining singletons. `/brain:freshness` flags missing/singleton tags.
- **Link notes to code communities.** End each note with a `Code:` line of `[[_COMMUNITY_<Name>]]` links (names from `graphify/<repo>/<repo>-GRAPH_REPORT.md`). Stubs in `graphify/<repo>/communities/` are auto-generated — never hand-edit them.
- **No secrets in notes** — link to where a secret lives, never copy its value.
- Agent-generated notes land as **drafts** (`wiki/_drafts/`); promotion into trusted `wiki/` happens via PR review.

## Session workflow

- `/brain:resume` — load prior context (`hot.md` + recent `logs/` + relevant notes) before starting work.
- `/brain:save` — write a dated session log, refresh `hot.md`, append to `wiki/log.md`, sync changed graph mirrors, commit (allowlist only).
- `/brain:freshness` — wiki health check (orphans, dead links, stale `last_verified`, broken `source:`) → a review queue.
- `/brain:wiki-ingest` — distill harvested chats into draft notes (run the harvest script first).

## Repos this brain covers

| Area | Repo | Stack | Graph |
|---|---|---|---|
| {{area}} | `{{path/to/repo}}` | {{stack}} | `graphify/{{repo}}/graph.json` |

Sync all mirrors at once with the plugin's `bin/sync-graph.sh` (run with `BRAIN_ROOT` set to this vault).

## Git conventions

- Knowledge changes via PR when they touch trusted notes; direct commits OK for `logs/`, `chats/`, drafts.
- `graph.json` is regenerated, never hand-edited; the graphify merge driver handles parallel commits.
