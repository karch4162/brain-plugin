#!/usr/bin/env bash
# vault-commit.sh — THE single guarded commit path into a brain vault.
#
# Every command that commits to the vault goes through here: /brain:save step 6,
# bin/sync-graph.sh, and anything added later. Nothing else may run `git commit`
# against a vault.
#
# WHY THIS EXISTS (INNOV-275). The guards were on the wrong side. sync-graph.sh
# carried six references' worth of protected-branch and HEAD-pin checking, while
# /brain:save step 6 — the path that actually put a commit on a protected `main`
# on 2026-08-05 — ran raw `git add` / `git commit` with no guard at all. Re-run
# that incident against the hardened helper and the helper refuses, then the
# agent commits to `main` by hand one step later. Hardening a helper does not
# harden the vault; hardening the ONLY commit path does. This is the INNOV-274
# pattern — one rule, one implementation, every caller — applied to commits.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in
# the plugin, NOT inside the vault, so it cannot derive the vault from its own
# location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash vault-commit.sh -m "msg"                  # stage the whole allowlist, commit
#   BRAIN_ROOT=<vault> bash vault-commit.sh -m "msg" logs/ wiki/log.md   # stage a SUBSET of it
#   BRAIN_ROOT=<vault> bash vault-commit.sh -m "msg" --pin "main:abc123" # verify HEAD hasn't moved
#   BRAIN_ROOT=<vault> bash vault-commit.sh -m "msg" --force-commit      # commit onto a branch with an open PR
#   BRAIN_ROOT=<vault> bash vault-commit.sh --print-allowlist            # what would be staged, one per line
#
#   -m, --message MSG   commit message (required unless --print-allowlist)
#   --pin BRANCH:SHA    the vault's branch + SHA as the CALLER saw them at start.
#                       Refuses if either moved. See "HEAD PIN" below.
#   --force-commit      overrides the OPEN-PR guard ONLY. It does NOT override the
#                       protected-branch guard or the HEAD pin — see below.
#   --print-allowlist   print THIS VAULT's resolved allowlist entries and exit 0.
#   --print-required    print the paths shipped brain commands commit, TSV
#                       "<path>\t<which command needs it>", and exit 0. Needs no
#                       vault — it is a property of the plugin, not of a vault.
#
# THE REQUIRED SET (INNOV-278). A vault whose .saveinclude omits a path that a
# shipped command commits is broken in a quiet way: the command does its file
# work, then this script refuses to commit it. That is exactly what the 0.2.22
# upgrade did to every vault created before it — `graphify/` had never needed to
# be allowlisted, because sync-graph.sh used to run its own `git add`.
#
# So the required set lives HERE, next to the enforcement, and `/brain:doctor`
# reads it rather than keeping its own copy. A second list in the doctor skill
# is the INNOV-274 defect — one rule, two implementations, drifting apart — and
# it would drift in the most useless direction possible: the checker would go
# stale exactly when a new committed path made the check matter.
#
# Adding a path a shipped command commits? Add it here. tests/test-vault-commit.sh
# asserts that every path sync-graph.sh passes to this script appears below, so
# forgetting fails the suite rather than shipping a checker that cannot see it.
#
# Contract (callers and tests depend on exactly this):
#   exit 0  => committed, or there was nothing to commit (both say which on stdout)
#   exit 1  => REFUSED, nothing was staged and nothing was committed
# The FIRST line of output always starts with "VAULT-COMMIT: OK" (stdout) or
# "VAULT-COMMIT: REFUSED" (stderr), so a caller can branch on it without parsing
# prose.
#
# THE ALLOWLIST. `.saveinclude` at the vault root is the whole permission model:
# one path or glob per line, `#` comments and blanks ignored. Two things happen
# with it, and the second is the one that matters:
#   1. Staging  — only allowlisted entries are staged (never `git add -A`).
#   2. VERIFICATION — after staging, every path in the index is checked against
#      the allowlist, and a single path outside it REFUSES the commit.
# Step 2 is not redundant with step 1. The git index is GLOBAL to the checkout:
# a concurrent session, an aborted merge, or a human running `git add` can leave
# anything at all staged, and step 1 alone would happily sweep it into this
# commit. Verifying the index is what makes "no command commits anything outside
# .saveinclude" a property of the tool rather than an intention.
#
# NO .saveinclude => REFUSE. A vault without an allowlist has no permission model,
# and defaulting to "commit everything" in that case would publish `chats/` the
# first time someone forgot the file. Fail closed; the remedy is one file and the
# refusal prints it.
#
# PROTECTED-BRANCH GUARD: never commits onto the repo's default/protected branch.
# The default branch is detected from origin/HEAD, then `gh repo view`, and
# finally by treating the literal names main/master as protected — the last one
# is the safety net, so a vault with no remote and no `gh` still refuses.
# THIS GUARD HAS NO OVERRIDE. sync-graph.sh's --force-commit used to bypass it;
# INNOV-275 retires that. "I want to commit straight onto main" is not a thing
# the tooling should offer a flag for — a human who genuinely means it can run
# git by hand and own it, which is a different act from a script doing it.
#
# OPEN-PR GUARD: if the vault's current branch has an open PR (per `gh`), the
# commit is refused rather than piling onto a branch under review (a prior run
# put 607 files onto a branch mid-review). --force-commit overrides this one:
# unlike the two below, "yes, add to my own open PR" is a coherent intent. If
# `gh` is missing, unauthenticated, or errors, the guard is skipped and the
# commit proceeds — a vault with no GitHub remote keeps working.
#
# HEAD PIN: a caller that did work before committing passes the branch + SHA it
# saw when it started. If either moved, the commit is refused — a moved HEAD
# means a concurrent session checked out or merged something underneath the run,
# so the commit would land on a branch its author never selected. That is exactly
# the 2026-08-05 incident. --force-commit does NOT override this: --force-commit
# means "I know about the open PR and want it anyway", but a moved HEAD makes the
# caller's intent genuinely unknown — there is nothing to force.
#
# NOTHING IS STAGED ON A REFUSAL. Every guard runs BEFORE the first `git add`, so
# a refusal leaves the index exactly as it found it. The older sync-graph.sh
# behaviour — stage, then refuse, and tell the user it was "left staged" — is
# wrong in a shared checkout: it hands the next session's commit a payload it
# never chose. A refusal here costs a re-run, nothing else.
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# detect_default_branch() and branch_is_protected() live in lib/branch.sh, shared
# verbatim with bin/session.sh — which applies the same protected-branch rule at
# command START, so the work happens on a working branch from the first file write
# instead of being discovered here an hour of edits later. Two copies of this rule
# would be the INNOV-274 defect: a start-time check and a commit-time check that
# disagree about "protected" means a command that starts somewhere it can never
# commit from. The path is resolved from this script's own location, so it works
# from any cwd. The lib reads $VAULT, which is why it is sourced after it is set.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/branch.sh
. "$BIN_DIR/lib/branch.sh"

MESSAGE=""
PIN=""
FORCE_COMMIT=0
PRINT_ALLOWLIST=0
PRINT_REQUIRED=0
PATHS=()

# The paths shipped brain commands commit — the single source of truth, read by
# /brain:doctor's allowlist check. See "THE REQUIRED SET" in the header before
# editing. Format: "<path>\t<which command needs it, and why>".
REQUIRED=(
  $'logs/\t/brain:save — the dated session log'
  $'wiki/hot.md\t/brain:save — the rolling session cache'
  $'wiki/log.md\t/brain:save and bin/sync-graph.sh — the append-only operation log'
  $'graphify/\tbin/sync-graph.sh — the mirrored code graphs, one folder per covered repo'
  $'graphify-out/graph.json\t/brain:save step 5c — the vault-s own wiki concept graph'
  $'graphify-out/GRAPH_REPORT.md\t/brain:save step 5c — the wiki graph report'
  $'graphify-out/communities/\t/brain:save step 5c — wiki graph community stubs'
)

refuse() { # reason-line, then extra lines
  {
    echo "VAULT-COMMIT: REFUSED - $1"
    shift
    local line
    for line in "$@"; do echo "$line"; done
  } >&2
  exit 1
}

# --- 0. arguments -----------------------------------------------------------
# Flags may appear anywhere, including after the path arguments, because callers
# build these argv lists programmatically and argument order is a silly thing to
# have to get right. `--` explicitly ends flag parsing.
END_OF_FLAGS=0
while [[ $# -gt 0 ]]; do
  if [[ $END_OF_FLAGS -eq 1 ]]; then PATHS+=("$1"); shift; continue; fi
  case "$1" in
    -m|--message)      MESSAGE="${2:-}"; shift 2 || refuse "--message needs a value" ;;
    --message=*)       MESSAGE="${1#*=}"; shift ;;
    --pin)             PIN="${2:-}"; shift 2 || refuse "--pin needs a value" ;;
    --pin=*)           PIN="${1#*=}"; shift ;;
    --force-commit)    FORCE_COMMIT=1; shift ;;
    --print-allowlist) PRINT_ALLOWLIST=1; shift ;;
    --print-required)  PRINT_REQUIRED=1; shift ;;
    --)                END_OF_FLAGS=1; shift ;;
    -*)                refuse "unknown flag '$1'" "  See the usage block at the top of vault-commit.sh." ;;
    *)                 PATHS+=("$1"); shift ;;
  esac
done

# --print-required is answered BEFORE any vault check: it describes the plugin,
# not a vault, so /brain:doctor can ask what the required set is on a machine
# with no vault bound at all — which is precisely the machine most likely to be
# misconfigured.
if [[ $PRINT_REQUIRED -eq 1 ]]; then
  printf '%s\n' "${REQUIRED[@]}"
  exit 0
fi

if [[ $PRINT_ALLOWLIST -eq 0 && -z "$MESSAGE" ]]; then
  refuse "no commit message" "  Pass -m \"<message>\"."
fi

# --- 1. is this a vault, and is it a git repo? ------------------------------
if [[ ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  refuse "'$VAULT' doesn't look like a brain vault (no graphify/ or wiki/)" \
    "  Set BRAIN_ROOT to the vault root."
fi
if ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
  refuse "'$VAULT' is not a git repo, so there is nothing to commit to" \
    "  Set BRAIN_ROOT to the vault root, or run 'git init' there."
fi

# --- 2. the allowlist -------------------------------------------------------
# Missing or empty => REFUSE. See the header: a vault with no allowlist has no
# permission model, and there is no safe default to fall back to.
SAVEINCLUDE="$VAULT/.saveinclude"
ALLOW=()
if [[ ! -f "$SAVEINCLUDE" || ! -r "$SAVEINCLUDE" ]]; then
  refuse "no readable .saveinclude at '$SAVEINCLUDE'" \
    "  .saveinclude is the vault's whole permission model: it is the list of paths" \
    "  a command may commit. Without it there is no safe default — committing" \
    "  everything would publish private content (chats/), committing nothing would" \
    "  make every save a silent no-op. So this is a refusal, not a fallback." \
    "  Remedy: copy the template into the vault root:" \
    "    cp \"\${CLAUDE_PLUGIN_ROOT}/templates/saveinclude\" \"$SAVEINCLUDE\""
fi
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"                       # tolerate CRLF checkouts
  line="${line#"${line%%[![:space:]]*}"}"    # ltrim
  line="${line%"${line##*[![:space:]]}"}"    # rtrim
  [[ -z "$line" || "$line" == \#* ]] && continue
  ALLOW+=("$line")
done <"$SAVEINCLUDE"

if [[ ${#ALLOW[@]} -eq 0 ]]; then
  refuse "'.saveinclude' has no entries (only comments/blank lines)" \
    "  An empty allowlist permits nothing, so every commit through this path would" \
    "  be a no-op. List the paths /brain:save may commit, one per line."
fi

if [[ $PRINT_ALLOWLIST -eq 1 ]]; then
  printf '%s\n' "${ALLOW[@]}"
  exit 0
fi

# True when vault-relative path $1 is covered by allowlist entry $2.
#   entry ending in '/'      => prefix match (a directory and everything under it)
#   entry containing a glob  => shell pattern match, and also matched as a
#                               directory prefix so `graphify*/` style entries work
#   plain entry              => exact match, or the path is under it as a directory
path_is_allowed_by() { # path entry
  local path="$1" entry="$2"
  case "$entry" in
    */) [[ "$path" == "$entry"* ]] && return 0 ;;
    *[\*\?\[]*)
        # shellcheck disable=SC2053  # glob match on the RHS is the point
        [[ "$path" == $entry ]] && return 0
        # shellcheck disable=SC2053
        [[ "$path" == $entry/* ]] && return 0
        ;;
    *)  [[ "$path" == "$entry" || "$path" == "$entry"/* ]] && return 0 ;;
  esac
  return 1
}

path_is_allowed() { # path
  local entry
  for entry in "${ALLOW[@]}"; do
    path_is_allowed_by "$1" "$entry" && return 0
  done
  return 1
}

# --- 3. what are we staging? ------------------------------------------------
# No path arguments => the whole allowlist. Path arguments => a SUBSET of it, and
# each one must itself be covered by the allowlist. A caller asking to stage a
# path the vault does not permit is a bug in the caller, not a thing to silently
# drop: dropping it would make the caller's commit quietly incomplete.
if [[ ${#PATHS[@]} -eq 0 ]]; then
  PATHS=("${ALLOW[@]}")
else
  outside=()
  for p in "${PATHS[@]}"; do
    p="${p#./}"; p="${p%/}"
    path_is_allowed "$p" || path_is_allowed "$p/" || outside+=("$p")
  done
  if [[ ${#outside[@]} -gt 0 ]]; then
    refuse "asked to stage path(s) that '.saveinclude' does not allow: ${outside[*]}" \
      "  The caller requested these explicitly, so they are not silently skipped." \
      "  Either add them to $SAVEINCLUDE, or fix the caller." \
      "  Allowed: ${ALLOW[*]}"
  fi
fi

# --- 4. branch guards (ALL of them run before anything is staged) -----------
CUR_BRANCH="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
CUR_SHA="$(git -C "$VAULT" rev-parse HEAD 2>/dev/null || true)"

# HEAD PIN. Format BRANCH:SHA, as the caller saw it before it started working.
# A malformed pin is a REFUSAL, not an ignored argument — a caller that meant to
# pin and typo'd the format must not silently get an unpinned commit.
if [[ -n "$PIN" ]]; then
  pin_branch="${PIN%%:*}"
  pin_sha="${PIN#*:}"
  if [[ "$PIN" != *:* || -z "$pin_branch" || -z "$pin_sha" ]]; then
    refuse "--pin '$PIN' is not in BRANCH:SHA form" \
      "  A pin that cannot be parsed is treated as a failure, never as 'unpinned'."
  fi
  if [[ "$pin_branch" != "$CUR_BRANCH" || "$pin_sha" != "$CUR_SHA" ]]; then
    refuse "the vault's HEAD moved while this command was running" \
      "  branch then: ${pin_branch:-?}   branch now: ${CUR_BRANCH:-?}" \
      "  sha then:    ${pin_sha:-?}   sha now:    ${CUR_SHA:-?}" \
      "  Another session changed branches or merged underneath this run, so the" \
      "  commit would land somewhere its author never selected. Nothing was staged." \
      "  Re-check the branch, then re-run the command." \
      "  --force-commit does NOT override this guard: a moved HEAD makes your" \
      "  intent unknown rather than forceable."
  fi
fi

# branch_is_protected() comes from lib/branch.sh, sourced at the top.
if branch_is_protected "$CUR_BRANCH"; then
  refuse "'$CUR_BRANCH' is the protected/default branch" \
    "  Nothing was staged and nothing was committed." \
    "  Create a working branch first, then re-run:" \
    "    git -C \"$VAULT\" checkout -b brain/<what-this-is>" \
    "  Or start the command through bin/session.sh --start, which picks a working" \
    "  branch up front so this never comes up at commit time." \
    "  There is no flag to override this. If you genuinely mean to commit straight" \
    "  onto '$CUR_BRANCH', do it with git by hand — that is a human decision, not" \
    "  something the tooling should offer."
fi

# Prints the number of the open PR whose head is the vault's CURRENT branch, or
# nothing at all when there is no such PR *or* when we simply cannot tell (gh
# missing, unauthenticated, no remote, API error). This is a safety net, not a
# hard dependency: "unknown" must look exactly like "no PR" so a vault with no
# GitHub remote keeps committing as it always has.
open_pr_for_current_branch() {
  local pr
  command -v gh >/dev/null 2>&1 || return 0
  [[ -n "$CUR_BRANCH" && "$CUR_BRANCH" != "HEAD" ]] || return 0
  pr="$(cd "$VAULT" 2>/dev/null && gh pr list --state open --head "$CUR_BRANCH" \
        --json number --jq '.[0].number' 2>/dev/null || true)"
  pr="${pr//[^0-9]/}"
  [[ -n "$pr" ]] && echo "$pr"
  return 0
}

if [[ $FORCE_COMMIT -eq 0 ]]; then
  OPEN_PR="$(open_pr_for_current_branch)"
  if [[ -n "$OPEN_PR" ]]; then
    refuse "branch '$CUR_BRANCH' has open PR #$OPEN_PR" \
      "  Nothing was staged and nothing was committed." \
      "  Piling a mechanical commit onto a branch under review makes the review" \
      "  meaningless. Either merge the PR first, or re-run with --force-commit if" \
      "  you deliberately want this in that PR."
  fi
fi

# --- 5. stage ---------------------------------------------------------------
# Entries that match nothing in the working tree are skipped rather than passed
# to `git add` (which errors on a pathspec that matches no file). An allowlist
# naming a path the vault does not have yet is normal — a fresh vault has no
# graphify-out/ — and must not fail a save.
#
# `compgen -G` alone is NOT an existence test: with no glob metacharacters it
# falls back to word expansion and echoes the entry back verbatim, so every
# plain path "matches". Hence the -e filter over its results, which is the real
# test and also handles the glob case correctly.
entry_exists() { # vault-relative entry
  local entry="${1%/}" m
  # shellcheck disable=SC2206  # deliberate glob expansion of the entry
  local matches=( $(cd "$VAULT" 2>/dev/null && compgen -G "$entry" 2>/dev/null) )
  for m in "${matches[@]:-}"; do
    [[ -n "$m" && -e "$VAULT/$m" ]] && return 0
  done
  return 1
}

staged_any=0
for entry in "${PATHS[@]}"; do
  entry_exists "$entry" || continue
  if ! add_err="$(git -C "$VAULT" add -- "$entry" 2>&1)"; then
    refuse "'git add -- $entry' failed" \
      "$(printf '    %s\n' "$add_err")" \
      "  Common causes: the index is locked by a concurrent session, or every file" \
      "  under that path is gitignored. Nothing was committed."
  fi
  staged_any=1
done

# --- 6. VERIFY THE INDEX ----------------------------------------------------
# The index is global to the checkout. Whatever step 5 added, something else may
# already have staged something the allowlist forbids — another session, an
# aborted merge, a human's `git add -A`. Step 5's discipline only governs step 5;
# this check governs the commit. It is the one that makes the guarantee real.
STAGED=()
while IFS= read -r _line; do
  [ -n "$_line" ] && STAGED+=("$_line")
done < <(git -C "$VAULT" diff --cached --name-only 2>/dev/null)

if [[ ${#STAGED[@]} -eq 0 ]]; then
  if [[ $staged_any -eq 0 ]]; then
    echo "VAULT-COMMIT: OK - nothing to commit (no allowlisted path has changes)"
  else
    echo "VAULT-COMMIT: OK - nothing to commit (allowlisted paths are unchanged)"
  fi
  exit 0
fi

violations=()
for path in "${STAGED[@]}"; do
  [[ -z "$path" ]] && continue
  path_is_allowed "$path" || violations+=("$path")
done

if [[ ${#violations[@]} -gt 0 ]]; then
  refuse "the index contains ${#violations[@]} path(s) that '.saveinclude' does not allow" \
    "$(printf '    %s\n' "${violations[@]}")" \
    "  These were already staged before this command ran — the git index is shared" \
    "  by every session using this checkout, so another session (or a stray" \
    "  'git add') can put anything in it. Committing now would publish them." \
    "  Nothing was committed, and nothing was UNstaged either: unstaging another" \
    "  session's work would be its own kind of damage." \
    "  Remedy: review them, then either" \
    "    git -C \"$VAULT\" restore --staged <path>      # drop from the index" \
    "  or add the path to $SAVEINCLUDE if it belongs in vault commits."
fi

# --- 7. commit --------------------------------------------------------------
if ! commit_out="$(git -C "$VAULT" commit -m "$MESSAGE" 2>&1)"; then
  refuse "git commit failed" "$(printf '    %s\n' "$commit_out")"
fi

echo "VAULT-COMMIT: OK - committed ${#STAGED[@]} path(s) on '$CUR_BRANCH'"
printf '  %s\n' "${STAGED[@]}"
echo "  Push when ready: git -C \"$VAULT\" push"
exit 0
