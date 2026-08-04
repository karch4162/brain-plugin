#!/usr/bin/env bash
# check-freshness.sh — make it SAFE for /brain:save to rewrite wiki/hot.md.
#
# /brain:save step 3 REWRITES wiki/hot.md wholesale. Run from a vault branch that
# is behind origin, that rewrite silently reverts whatever anyone else landed on
# that file (this happened, from a branch 15 commits behind). Refusing outright is
# no better: the save ends half-done and the next /brain:resume reads a stale cache.
# So this script's job is to GET THE BRANCH CURRENT when it safely can — fast-forward
# when the branch has no local commits, merge when it has diverged — and to BLOCK only
# when neither is possible. It never pushes, never resets, never discards your work.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in the
# plugin, NOT inside the vault, so it cannot derive the vault from its own location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash check-freshness.sh              # get current, then report
#   BRAIN_ROOT=<vault> bash check-freshness.sh --no-merge   # report only, mutate nothing
#
# Contract (the /brain:save skill and its tests depend on exactly this):
#   exit 0  => safe to rewrite wiki/hot.md; proceed with the whole save.
#   exit 1  => DO NOT rewrite wiki/hot.md; every other step of the save still runs.
# The FIRST line of output always starts with "FRESHNESS: OK" (stdout) or
# "FRESHNESS: BLOCKED" (stderr), so a caller can branch on it without parsing prose.
#
# Missing preconditions are never failures: not a git repo, no origin, no
# origin/<default> ref, or an unreachable origin all report OK and exit 0. This is a
# guard against clobbering, not a network dependency.
set -euo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

MERGE=1
if [[ "${1:-}" == "--no-merge" ]]; then
  MERGE=0
  shift
fi

# Vault sanity check (same shape as sync-graph.sh) — but this script must NEVER
# emit a first line that isn't the FRESHNESS contract, and a guard has no business
# hard-failing a save. So it only fires when BRAIN_ROOT was NOT set, i.e. when the
# vault was *guessed* from CLAUDE_PROJECT_DIR/PWD and the guess looks wrong; an
# explicit BRAIN_ROOT is trusted. Skipping is the safe outcome: we would rather do
# nothing than fast-forward some unrelated repo we were pointed at by accident.
if [[ -z "${BRAIN_ROOT:-}" && ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  echo "FRESHNESS: OK - '$VAULT' doesn't look like a brain vault (no graphify/ or wiki/), freshness check skipped"
  echo "  hint: set BRAIN_ROOT to the vault if this was meant to be checked." >&2
  exit 0
fi

# --- 0. git repo? -----------------------------------------------------------
if ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "FRESHNESS: OK - not a git repo, nothing to check"
  exit 0
fi

BRANCH="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

# --- 1. upstream default branch --------------------------------------------
UPSTREAM=""
if git -C "$VAULT" remote get-url origin >/dev/null 2>&1; then
  for cand in origin/main origin/master; do
    if git -C "$VAULT" rev-parse --verify --quiet "refs/remotes/$cand" >/dev/null 2>&1; then
      UPSTREAM="$cand"
      break
    fi
  done
fi
if [[ -z "$UPSTREAM" ]]; then
  echo "FRESHNESS: OK - no origin/<default> ref, freshness check skipped"
  exit 0
fi

# --- 2. refresh refs only (never touches the working tree) ------------------
if ! git -C "$VAULT" fetch --prune origin >/dev/null 2>&1; then
  echo "FRESHNESS: OK - origin unreachable, freshness check skipped"
  exit 0
fi

# --- 3. behind / ahead ------------------------------------------------------
BEHIND="$(git -C "$VAULT" rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)"
AHEAD="$(git -C "$VAULT" rev-list --count "$UPSTREAM..HEAD" 2>/dev/null || echo 0)"

# --- 4. already current -----------------------------------------------------
if (( BEHIND == 0 )); then
  echo "FRESHNESS: OK - up to date with $UPSTREAM"
  exit 0
fi

# Behind. A merge is about to be attempted against whatever is in the tree, so say
# out loud if that tree is dirty — the user needs to know uncommitted work was in play.
DIRTY=0
if [[ -n "$(git -C "$VAULT" status --porcelain 2>/dev/null)" ]]; then
  DIRTY=1
fi

# --- --no-merge: report the state, change nothing ---------------------------
if (( MERGE == 0 )); then
  {
    echo "FRESHNESS: BLOCKED - branch '$BRANCH' is $BEHIND commit(s) behind and $AHEAD ahead of $UPSTREAM (--no-merge: nothing was changed)"
    (( DIRTY == 1 )) && echo "  note: working tree is dirty (uncommitted changes present)."
    echo "  Remedy: re-run without --no-merge, or: git -C \"$VAULT\" rebase $UPSTREAM"
    echo "  Then re-run /brain:save."
  } >&2
  exit 1
fi

REASON=""

# The dirty note is always emitted AFTER the FRESHNESS line, never before it — the
# contract is that the first line of output is the verdict, on either stream.
dirty_note() {
  (( DIRTY == 1 )) || return 0
  echo "  note: working tree was dirty; the merge was attempted against uncommitted changes." >&"${1:-1}"
}

if (( AHEAD == 0 )); then
  # --- 5. common case: fresh save branch, no local commits => fast-forward ---
  if git -C "$VAULT" merge --ff-only "$UPSTREAM" >/dev/null 2>&1; then
    echo "FRESHNESS: OK - fast-forwarded $BEHIND commit(s) from $UPSTREAM"
    dirty_note 1
    exit 0
  fi
  REASON="fast-forward from $UPSTREAM failed"
  (( DIRTY == 1 )) && REASON="$REASON (uncommitted changes are holding it back)"
else
  # --- 6. diverged: second save on the same branch, a stray local commit, or
  #        sync-graph.sh auto-committing => try a real merge --------------------
  if git -C "$VAULT" merge --no-edit "$UPSTREAM" >/dev/null 2>&1; then
    echo "FRESHNESS: OK - merged $UPSTREAM ($BEHIND commit(s) behind, $AHEAD ahead)"
    dirty_note 1
    exit 0
  fi
  # Leave nothing half-merged.
  git -C "$VAULT" merge --abort >/dev/null 2>&1 || true
  REASON="merge of $UPSTREAM conflicted (merge aborted, tree left as it was)"
  (( DIRTY == 1 )) && REASON="$REASON; working tree was dirty"
fi

# --- 7. BLOCKED -------------------------------------------------------------
{
  echo "FRESHNESS: BLOCKED - $REASON"
  echo "  branch '$BRANCH' is $BEHIND commit(s) behind and $AHEAD ahead of $UPSTREAM."
  echo "  Rewriting wiki/hot.md from here would revert what others landed on it."
  echo "  Remedy: commit or stash your changes, then"
  echo "    git -C \"$VAULT\" rebase $UPSTREAM"
  echo "  or resolve the conflicting files by hand. Then re-run /brain:save."
} >&2
exit 1
