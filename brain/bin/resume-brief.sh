#!/usr/bin/env bash
# resume-brief.sh — where /brain:resume reads its briefing from (INNOV-301).
#
# THE DEFECT. Resume used to read wiki/hot.md, logs/ and wiki/index.md from the
# WORKING TREE. /brain:save leaves the checkout on its save branch by construction,
# so the next resume briefed from that branch: a checkout 71 commits behind, its
# upstream long deleted, reported a 12-day-old hot.md and closed loops as current.
#
# THE FIX. The briefing always comes from origin/<default> via `git show`, whatever
# the checkout is on, dirty or clean, attached or detached. One code path, so the
# briefing never depends on the state of somebody's checkout. Drift between the
# checkout and origin/<default> is REPORTED, never repaired: moving the branch is
# /brain:save step 0b's job (check-freshness.sh), which also repins the session.
# This script never writes — not the tree, not the index, not a ref, and it does
# not fetch (resume step 2 already did; staying fetch-free keeps it offline-safe).
#
# Every `ref:path` git call lives here rather than in SKILL.md prose, because Git
# Bash's MSYS path conversion mangles `origin/main:wiki/hot.md` and git then
# reports a file that exists as missing. MSYS_NO_PATHCONV stops that — but only
# on those calls, run from inside the vault: exported globally it would also stop
# the translation of `git -C /posix/path`, and native git could not find the vault.
#
# Usage (vault from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD):
#   resume-brief.sh              first line "BRIEF: origin/<default>" or
#                                "BRIEF: worktree - <why>"; then, only when the
#                                checkout has drifted, one "DRIFT: ..." line
#   resume-brief.sh --cat PATH   PATH's content from the briefing ref; exit 1 if absent
#   resume-brief.sh --logs       the newest 3 logs/YYYY-MM-DD-*.md paths, oldest first
# Always exit 0 except --cat on a missing path. Degrades to the working tree when
# origin/<default> cannot be resolved — a briefing that cannot reach the remote is
# still a briefing, it just must not claim to be current.
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# detect_default_branch() is the one default-branch rule, shared with
# vault-commit.sh, session.sh and reap-branches.sh. It reads $VAULT.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/branch.sh
. "$BIN_DIR/lib/branch.sh"

# REF is "origin/<default>", or empty for the working tree (WHY says why).
REF=""
WHY=""
DEFAULT="$(detect_default_branch)"
# Same safety net branch_is_protected() uses when detection comes up empty.
if [[ -z "$DEFAULT" ]]; then
  for cand in main master; do
    if git -C "$VAULT" rev-parse --verify --quiet "refs/remotes/origin/$cand" >/dev/null 2>&1; then
      DEFAULT="$cand"
      break
    fi
  done
fi
if [[ -z "$DEFAULT" ]]; then
  WHY="no origin default branch could be resolved"
elif ! git -C "$VAULT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT" >/dev/null 2>&1; then
  WHY="no origin/$DEFAULT ref"
else
  REF="origin/$DEFAULT"
fi

case "${1:-}" in
  --cat)
    path="${2:-}"
    if [[ -z "$path" ]]; then echo "resume-brief: --cat needs a path" >&2; exit 1; fi
    if [[ -n "$REF" ]]; then
      (cd "$VAULT" && MSYS_NO_PATHCONV=1 git show "$REF:$path") 2>/dev/null && exit 0
    elif [[ -f "$VAULT/$path" ]]; then
      cat "$VAULT/$path" && exit 0
    fi
    echo "resume-brief: $path not found in ${REF:-the working tree}" >&2
    exit 1
    ;;
  --logs)
    if [[ -n "$REF" ]]; then
      (cd "$VAULT" && MSYS_NO_PATHCONV=1 git ls-tree --name-only "$REF" logs/) 2>/dev/null
    else
      (cd "$VAULT" 2>/dev/null && ls -1 logs/* 2>/dev/null)
    fi | grep -E '^logs/[0-9]{4}-[0-9]{2}-[0-9]{2}-.*\.md$' | sort | tail -n 3
    exit 0
    ;;
esac

if [[ -z "$REF" ]]; then
  echo "BRIEF: worktree - $WHY; briefing from the checkout, which may not be current"
  exit 0
fi
echo "BRIEF: $REF"

# Drift: only reported, never repaired. Detached HEAD has no branch to report on,
# and its briefing is unaffected either way.
BRANCH="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
[[ "$BRANCH" == "HEAD" ]] && exit 0
BEHIND="$(git -C "$VAULT" rev-list --count "HEAD..$REF" 2>/dev/null || echo 0)"
TRACK="$(git -C "$VAULT" for-each-ref --format='%(upstream:track)' "refs/heads/$BRANCH" 2>/dev/null)"
if [[ "$TRACK" == "[gone]" ]]; then
  echo "DRIFT: checkout is on $BRANCH, whose upstream is gone, $BEHIND commit(s) behind $REF - the briefing above is from $REF; /brain:save step 0b brings the branch current"
elif [[ "$BEHIND" != "0" ]]; then
  echo "DRIFT: checkout is on $BRANCH, $BEHIND commit(s) behind $REF - the briefing above is from $REF; /brain:save step 0b brings the branch current"
fi
exit 0
