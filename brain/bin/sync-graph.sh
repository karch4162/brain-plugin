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
#   BRAIN_ROOT=<vault> bash sync-graph.sh                  # sync only mirrors that are STALE (see below)
#   bash sync-graph.sh <repo-path> [...]                   # sync specific repo checkout(s)
#   bash sync-graph.sh --no-commit [...]                   # copy + log only, no git commit
#   bash sync-graph.sh --force-commit [...]                # commit even if the vault branch has an open PR
#
# Flags may appear in any order, anywhere before the repo args. If both
# --no-commit and --force-commit are given, --no-commit wins.
#
# DEFAULT SCOPE (no repo args): each folder name under <vault>/graphify/ is
# resolved to a checkout at $REPOS_DIR/<name> (default: the vault's parent dir),
# but only mirrors that are actually STALE are selected — i.e. the repo-side
# graphify-out/graph.json exists AND differs byte-for-byte from the mirrored
# copy in the vault. Mirrors nobody rebuilt this session are left alone (an
# unscoped run once degraded an untouched mirror's labels). The selected list is
# printed to stderr before any work happens; if nothing is stale the script says
# so and exits 0. Explicit repo args are NEVER filtered — naming a repo means it.
#
# COMMIT GUARD: if the vault's current branch has an open PR (per `gh`), the sync
# is left staged/uncommitted rather than piling commits onto a branch under
# review. Pass --force-commit to override. If `gh` is missing, unauthenticated,
# or errors, the guard is skipped and the commit proceeds as before — a vault
# with no GitHub remote keeps working.
#
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
FORCE_COMMIT=0
# Flags may be given in any order and anywhere before the repo args; the first
# non-flag argument ends flag parsing (repo paths can legitimately start with
# anything, and `--` explicitly terminates the flags).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-commit)    COMMIT=0; shift ;;
    --force-commit) FORCE_COMMIT=1; shift ;;
    --)             shift; break ;;
    *)              break ;;
  esac
done
# --no-commit wins over --force-commit if both were passed.
if [[ $COMMIT -eq 0 ]]; then FORCE_COMMIT=0; fi

# Prints how many NON-generic community headings the report at $1 has — i.e. how
# many communities someone (LLM or /brain:label) actually named in it. A missing,
# unreadable or empty file counts as 0. Always exits 0, always prints one integer.
count_named_labels() {
  local file="${1:-}" n
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    echo 0
    return 0
  fi
  n="$(grep -E '^### Community [0-9]+ - "' "$file" 2>/dev/null | grep -Evc -- '- "Community [0-9]+"$' || true)"
  n="${n//[^0-9]/}"
  echo "${n:-0}"
  return 0
}

# True when the repo-side graph at $1 exists and differs from the mirrored copy
# at $2 — the same `cmp -s` test the sync loop uses to decide "up-to-date".
mirror_is_stale() {
  local src_graph="$1" dst_graph="$2"
  [[ -f "$src_graph" ]] || return 1
  [[ -f "$dst_graph" ]] || return 0
  ! cmp -s "$src_graph" "$dst_graph"
}

repos=("$@")
if [[ ${#repos[@]} -eq 0 ]]; then
  # DEFAULT SCOPE: never "every mirror". Only mirrors whose source graph actually
  # differs from the mirrored copy — an unscoped run must not touch a repo nobody
  # rebuilt (that is how tray_pos_flutter got degraded to generic labels).
  selected=()
  for d in "$VAULT"/graphify/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    if mirror_is_stale "$REPOS_DIR/$n/graphify-out/graph.json" "$VAULT/graphify/$n/graph.json"; then
      repos+=("$REPOS_DIR/$n")
      selected+=("$n")
    fi
  done
  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "nothing to sync: no mirror's graph.json differs from its source" >&2
    exit 0
  fi
  echo "selected ${#selected[@]} mirror(s): ${selected[*]}" >&2
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
  # LABEL GUARD: never let a LESS-labeled incoming report clobber a more-labeled
  # one. This is a COMPARISON, not an existence check: a keyless repo-side rebuild
  # can emit a handful of named headings alongside hundreds of "Community N"
  # placeholders, and copying that over a fully named report destroys the
  # vault-side labels and breaks every Code: [[_COMMUNITY_*]] link built on them
  # (the documented tray_pos_flutter incident). So we copy only when the incoming
  # report names at least as many communities as the existing one — an equal count
  # (a same-count relabel or plain content refresh) still copies. graph.json syncs
  # below either way; stubs regenerate from the preserved report + new graph
  # (member-overlap matching keeps stub filenames stable).
  if [[ -f "$src/GRAPH_REPORT.md" ]]; then
    existing_named="$(count_named_labels "$dst/$name-GRAPH_REPORT.md")"
    incoming_named="$(count_named_labels "$src/GRAPH_REPORT.md")"
    if (( incoming_named < existing_named )); then
      echo "preserving labeled report for $name: incoming has $incoming_named named communities, existing has $existing_named — run /brain:label $name to refresh labels" >&2
    else
      cp "$src/GRAPH_REPORT.md" "$dst/$name-GRAPH_REPORT.md"
    fi
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

# Prints the number of the open PR whose head is the vault's CURRENT branch, or
# nothing at all when there is no such PR *or* when we simply cannot tell (gh
# missing, unauthenticated, no remote, API error). This is a safety net, not a
# hard dependency: "unknown" must look exactly like "no PR" so a vault with no
# GitHub remote keeps committing as it always has.
open_pr_for_current_branch() {
  local branch pr
  command -v gh >/dev/null 2>&1 || return 0
  branch="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || return 0
  # gh has no -C; run it from inside the vault so it resolves that repo's remote.
  pr="$(cd "$VAULT" 2>/dev/null && gh pr list --state open --head "$branch" \
        --json number --jq '.[0].number' 2>/dev/null || true)"
  pr="${pr//[^0-9]/}"
  [[ -n "$pr" ]] && echo "$pr"
  return 0
}

if [[ ${#synced[@]} -gt 0 && $COMMIT -eq 1 ]]; then
  git -C "$VAULT" add graphify wiki/log.md

  # COMMIT GUARD: don't pile a large mechanical sync onto a branch that is already
  # under review (a prior run committed 607 files onto a branch with an open PR).
  open_pr=""
  if [[ $FORCE_COMMIT -eq 0 ]]; then
    open_pr="$(open_pr_for_current_branch)"
  fi

  if [[ -n "$open_pr" ]]; then
    cur_branch="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    {
      echo "NOT COMMITTING: branch '$cur_branch' has open PR #$open_pr."
      echo "The sync was left STAGED and uncommitted. Staged for commit:"
      git -C "$VAULT" diff --cached --name-only | sed 's/^/  /'
      echo "Mirrors synced: ${synced[*]}"
      echo "Commit deliberately (git -C \"$VAULT\" commit), or re-run with --force-commit."
    } >&2
  else
    git -C "$VAULT" commit -m "Sync graph mirror(s): ${synced[*]}"
    echo "Committed. Push when ready: git -C \"$VAULT\" push"
  fi
fi
