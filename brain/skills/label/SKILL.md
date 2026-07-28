---
name: label
description: "Name a graph mirror's communities vault-side — no repo checkout, no resync. Reads graphify/<repo>/graph.json, names clusters in-session (keyless), rewrites <repo>-GRAPH_REPORT.md preserving existing names, regenerates stubs. Trigger: /brain:label [repo ...], or 'label the communities' / 'fix the unlabeled mirrors'."
---

# /brain:label — vault-side community labeling

Fixes the two freshness findings **"Graph mirrors never labeled (no community report)"** and **"all-generic community labels"** without touching any repo checkout. A mirror's `graph.json` carries every node's `community` id, member labels, and `source_file` — naming a cluster is a pure function of that data. The mirror is self-sufficient.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

**This is agent-driven LLM work** (same host-session pattern as `/brain:save` step 5c): the bundled script prepares the work order and renders the result; **you** do the naming, in this session, keyless.

## Hard rules

- **Never change an existing non-generic label.** The script enforces this (preserved > your labels > derived), but don't try either. A partially-named mirror (e.g. tray_pos_flutter: 30 named, 400+ placeholders) gets its placeholders filled and its named communities left byte-identical.
- **Never resync a mirror to fix labels.** A keyless resync replaces named stubs with "Community N" placeholders and breaks `Code:` links — the documented incident this skill exists to prevent. (`bin/sync-graph.sh` now guards against it, but don't lean on the guard.)
- **Never hand-edit `graphify/<repo>/communities/`** — `build-community-notes.mjs` wholesale-regenerates that dir.
- **Do not shell out to `graphify label` / `graphify cluster-only`.** The bare CLI has no host-session mode: with no API key it silently degrades to placeholders, and it re-clusters + writes to the wrong location as side effects. The keyless path is this skill.

## What to do when invoked

1. **Get the work order** (from the vault root, or with `BRAIN_ROOT=<vault>` set):
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/label-communities.mjs" --digest [repo ...]
   ```
   Per repo it prints: `preserved` (existing names — untouchable), `derived` (tiny tail communities auto-named from their dominant source file), and `batches` — the communities **you** must name, largest first, ≤100 per batch, each line like:
   ```
   Community 11 (95 nodes): _adjustTab, _appliedGiftCards, CheckoutBloc, ... | files: presentation/checkout/bloc/checkout_bloc.dart
   ```
   If every repo comes back with empty `batches` + `derived`, report "already labeled" per mirror and stop — the pass is idempotent.

2. **Name each batch in-session.** For each line, write a concise **2–5 word plain-language name** describing what the cluster is about — "Checkout BLoC", "Order Management", "Payment Flow", "Auth Middleware". Use both the member labels *and* the file paths (the paths usually carry the most signal). Rules: no `"` in names; avoid `\ / : * ? < > | # ^ [ ]` (they get folded to `-` in stub filenames); don't reuse an existing preserved name for a different cluster unless they genuinely belong together (same-name communities merge into one stub note).

3. **Apply, one repo at a time.** Write your `{"<id>": "<name>", ...}` map to a scratch file, then:
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/label-communities.mjs" --apply <repo> --labels <scratch>/labels-<repo>.json
   ```
   The script merges (preserved always wins, invalid/missing entries fall back to derived names) and rewrites `graphify/<repo>/<repo>-GRAPH_REPORT.md` — **in place** if a report exists (only generic headings + hub links change; omitted thin communities are appended in an "Additional communities" section), or generated fresh if the mirror had no report at all.

4. **Regenerate the stubs** so `[[_COMMUNITY_*]]` links resolve to the new names:
   ```bash
   BRAIN_ROOT=<vault> node "${CLAUDE_PLUGIN_ROOT}/bin/build-community-notes.mjs" <repo>
   ```
   This run also arms the rename-protection: stubs get `members:` frontmatter, so future relabels keep stable filenames via member-overlap matching.

5. **Verify.** Run the freshness scan (`node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --stdout`) and confirm: the labeled repo no longer appears under either labeling finding, and unresolved `_COMMUNITY_*` link targets are 0. If ghosts appeared, a wiki note was linking a renamed generic stub (`[[_COMMUNITY_Community N]]`) — list those notes for the user; fixing their `Code:` lines is a note edit and follows the vault's PR convention.

6. **Offer to commit** (ask first — vault governance): `git -C <vault> add graphify/<repo>` plus a `wiki/log.md` line, e.g.
   `- <date> — <repo> communities labeled vault-side via /brain:label (N named, M derived, K preserved).`
   Mirror the commit style of `sync-graph.sh` (`Label communities: <repos>`); push is left to the user.

## Notes

- Large mirrors are batched (POS ≈ 623 communities → ~1 batch of 100 for you + ~523 derived tail names). Work through batches sequentially; don't skip the tail — the script derives it automatically on apply.
- `--top N` on `--digest` adjusts how many communities get LLM names vs derived names (default 100, largest first).
- Read-only except `graphify/<repo>/<repo>-GRAPH_REPORT.md` (via `--apply`) and `graphify/<repo>/communities/` (via the stub regenerator). `graph.json` is never written.
