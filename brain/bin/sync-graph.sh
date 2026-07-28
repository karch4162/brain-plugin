#!/usr/bin/env bash
# sync-graph.sh — publish a repo's graphify artifacts into a brain vault.
#
# Copies the three durable artifacts (graph.json, GRAPH_REPORT.md, manifest.json)
# from <repo>/graphify-out/ into <vault>/graphify/<repo-name>/, regenerates the
# Obsidian community stub notes (communities/), appends a wiki/log.md entry, and
# commits. Push is left to you.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in the
# plugin, NOT inside the vault, so it cannot derive the vault from its own location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash sync-graph.sh                  # sync every repo under graphify/
#   bash sync-graph.sh <repo-path> [...]                   # sync specific repo checkout(s)
#   bash sync-graph.sh --no-commit [...]                   # copy + log only, no git commit
#
# With no repo args, each folder name under <vault>/graphify/ is resolved to a
# checkout at $REPOS_DIR/<name> (default: the vault's parent dir).
# Override per machine: REPOS_DIR=~/code BRAIN_ROOT=<vault> bash sync-graph.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# Where the covered repos are checked out — explicit REPOS_DIR, else auto-detect the two
# common layouts (repos one or two levels above the vault). No fixed-layout assumption.
if [[ -z "${REPOS_DIR:-}" ]]; then
  REPOS_DIR="$VAULT/.."
  for cand in "$VAULT/.." "$VAULT/../.."; do
    for d in "$VAULT"/graphify/*/; do
      [[ -d "$d" ]] || continue
      if [[ -d "$cand/$(basename "$d")" ]]; then REPOS_DIR="$cand"; break 2; fi
    done
  done
fi

if [[ ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  echo "error: '$VAULT' doesn't look like a brain vault (no graphify/ or wiki/). Set BRAIN_ROOT." >&2
  exit 1
fi

COMMIT=1
if [[ "${1:-}" == "--no-commit" ]]; then
  COMMIT=0
  shift
fi

# True if the report at $1 has at least one NON-generic community heading —
# i.e. someone (LLM or /brain:label) actually named communities in it.
has_named_labels() {
  [[ -f "${1:-}" ]] || return 1
  grep -E '^### Community [0-9]+ - "' "$1" 2>/dev/null | grep -Evq -- '- "Community [0-9]+"$'
}

repos=("$@")
if [[ ${#repos[@]} -eq 0 ]]; then
  for d in "$VAULT"/graphify/*/; do
    [[ -d "$d" ]] || continue
    repos+=("$REPOS_DIR/$(basename "$d")")
  done
fi

synced=()
for repo in "${repos[@]}"; do
  name="$(basename "$repo")"
  src="$repo/graphify-out"
  dst="$VAULT/graphify/$name"

  if [[ ! -f "$src/graph.json" ]]; then
    echo "skip $name: no graph at $src/graph.json" >&2
    continue
  fi
  if [[ -f "$dst/graph.json" ]] && cmp -s "$src/graph.json" "$dst/graph.json"; then
    echo "up-to-date: $name"
    continue
  fi

  mkdir -p "$dst"
  cp "$src/graph.json" "$dst/graph.json"
  # Report is namespaced per repo in the vault so Obsidian's graph view and
  # quick-switcher don't collapse every repo's report to one "GRAPH_REPORT" node.
  #
  # LABEL GUARD: never let a generic/missing incoming report clobber a labeled
  # one. A keyless repo-side rebuild emits "Community N" placeholder headings,
  # and copying that over a named report destroys the vault-side labels and
  # breaks every Code: [[_COMMUNITY_*]] link built on them (the documented
  # tray_pos_flutter incident). graph.json still syncs below either way; stubs
  # regenerate from the preserved report + new graph (member-overlap matching
  # keeps stub filenames stable).
  if has_named_labels "$dst/$name-GRAPH_REPORT.md" && ! has_named_labels "$src/GRAPH_REPORT.md"; then
    echo "preserving labeled report for $name (incoming is generic/missing) — run /brain:label $name to refresh labels" >&2
  elif [[ -f "$src/GRAPH_REPORT.md" ]]; then
    cp "$src/GRAPH_REPORT.md" "$dst/$name-GRAPH_REPORT.md"
  fi
  rm -f "$dst/GRAPH_REPORT.md"  # drop legacy generic name if a prior sync left one
  [[ -f "$src/manifest.json" ]] && cp "$src/manifest.json" "$dst/manifest.json"

  # Regenerate Obsidian community stubs so [[_COMMUNITY_*]] links resolve.
  # The sibling script lives next to this one (in the plugin); the vault it operates
  # on is passed via BRAIN_ROOT.
  BRAIN_ROOT="$VAULT" node "$SCRIPT_DIR/build-community-notes.mjs" "$name" \
    || echo "warn: community notes not regenerated for $name" >&2

  # Node/edge counts for the log line; uses the repo's graphify interpreter
  # because plain `python` may be a Microsoft Store stub on Windows.
  PY_BIN="$(cat "$src/.graphify_python" 2>/dev/null || echo python3)"
  stats="$("$PY_BIN" - "$dst/graph.json" <<'PY' 2>/dev/null || true
import json, sys
g = json.load(open(sys.argv[1], encoding="utf-8"))
edges = g.get("links", g.get("edges", []))
print(f"{len(g.get('nodes', []))} nodes / {len(edges)} edges")
PY
)"
  echo "- $(date +%F) — ${name} graph mirror synced via bin/sync-graph.sh (${stats:-counts unavailable})." >> "$VAULT/wiki/log.md"
  echo "synced: $name (${stats:-?})"
  synced+=("$name")
done

if [[ ${#synced[@]} -gt 0 && $COMMIT -eq 1 ]]; then
  git -C "$VAULT" add graphify wiki/log.md
  git -C "$VAULT" commit -m "Sync graph mirror(s): ${synced[*]}"
  echo "Committed. Push when ready: git -C \"$VAULT\" push"
fi
