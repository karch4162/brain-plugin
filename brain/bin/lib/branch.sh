#!/usr/bin/env bash
# lib/branch.sh — the ONE definition of "which branch must never be committed to
# automatically", shared by every script that needs to know.
#
# WHY THIS EXISTS (INNOV-275, PR 2). vault-commit.sh owned this rule because it
# was the only place that needed it: refuse the commit if the vault is sitting on
# the default branch. PR 2 adds session.sh, which needs the SAME rule at the other
# end of the command — at START, so the work happens on a working branch from the
# first file write rather than being discovered at commit time, an hour of edits
# later.
#
# Two scripts needing one rule is exactly the INNOV-274 defect condition: copy the
# functions and they drift, and they drift in the worst possible direction — the
# start-time check and the commit-time check disagreeing about what "protected"
# means is a vault where a command cheerfully starts on a branch it can never
# commit from. So the rule moves here, byte-identical, and both callers source it.
# One rule, one implementation, every caller.
#
# PRECONDITION: the caller must have set $VAULT to the vault root before calling
# either function. Both shell out with `git -C "$VAULT"`, exactly as they did when
# they lived inside vault-commit.sh, and that global is deliberately kept rather
# than turned into a parameter — "verbatim" is what makes the extraction provably
# behaviour-preserving. Both callers resolve $VAULT identically
# ($BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD) before sourcing this file.
#
# This file defines functions and nothing else: no `set`, no top-level work, no
# output. It is sourced, never executed.

# Prints the vault repo's default branch name, or nothing when it cannot be
# determined. Tried in order, first hit wins:
#   (a) the local origin/HEAD symbolic ref (works offline, no gh needed),
#   (b) `gh repo view --json defaultBranchRef` when gh exists and is authed.
# EVERY method degrades silently to "unknown" — an error, a missing tool or a
# vault with no remote must never be reported as a branch name. The literal
# main/master fallback lives in branch_is_protected(), not here, because it is a
# safety net rather than a detection result.
detect_default_branch() {
  local ref db
  ref="$(git -C "$VAULT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  ref="${ref#origin/}"
  ref="${ref//[[:space:]]/}"
  if [[ -n "$ref" ]]; then echo "$ref"; return 0; fi
  if command -v gh >/dev/null 2>&1; then
    # gh has no -C; run it from inside the vault so it resolves that repo's remote.
    db="$(cd "$VAULT" 2>/dev/null && gh repo view --json defaultBranchRef \
          --jq '.defaultBranchRef.name' 2>/dev/null || true)"
    db="${db//[[:space:]]/}"
    if [[ -n "$db" ]]; then echo "$db"; return 0; fi
  fi
  return 0
}

# True when branch $1 must never receive an automatic commit: it is the detected
# default branch, or (safety net, always on) literally main/master.
branch_is_protected() {
  local branch="${1:-}" default
  [[ -n "$branch" && "$branch" != "HEAD" ]] || return 1
  default="$(detect_default_branch)"
  if [[ -n "$default" && "$branch" == "$default" ]]; then return 0; fi
  # A vault with no remote and no gh must STILL refuse to auto-commit onto
  # main/master. This one deliberately does not degrade to "not protected".
  if [[ "$branch" == "main" || "$branch" == "master" ]]; then return 0; fi
  return 1
}
