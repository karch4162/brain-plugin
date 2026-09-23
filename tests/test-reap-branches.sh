#!/usr/bin/env bash
# test-reap-branches.sh — deterministic quality gate for brain/bin/reap-branches.sh
#
# Contract under test (INNOV-309 slice 1):
#   After a save has committed, leave the checkout on the default branch and
#   delete the brain/* branches whose work has already landed.
#     - merged brain/* branches are deleted; the checkout ends on the default
#     - an UNMERGED branch is NEVER deleted: `git branch -d` refuses, the script
#       reports it under KEPT, and the commits are still reachable afterwards
#     - branches outside the brain/* namespace are never touched
#     - the default branch fast-forwards to origin/<default> when it is behind,
#       and a DIVERGED default is reported, never merged
#     - another live session in the checkout => REFUSED, nothing changed
#     - a switch git will not make (local changes in the way) => REFUSED, nothing
#       changed, nothing forced
#     - detached HEAD => REFUSED
#   Contract lines: "REAP: OK - ..." on stdout exit 0, "REAP: REFUSED - ..." on
#   stderr exit 1.
#
# Run:  bash tests/test-reap-branches.sh   (from anywhere)
# No network, no real vault. Never touches a vault outside its own sandbox.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
REAP="$REPO_ROOT/brain/bin/reap-branches.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }

fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  shift
  local line
  for line in "$@"; do echo "     $line"; done
}

assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi
}

assert_contains() { # name haystack needle
  case "$2" in
    *"$3"*) pass "$1" ;;
    *)      fail "$1" "expected to contain: [$3]" "actual: [$2]" ;;
  esac
}

git_config() { # dir
  git -C "$1" config core.autocrlf false
  git -C "$1" config core.eol lf
  git -C "$1" config user.email "test@example.invalid"
  git -C "$1" config user.name "Harness"
  git -C "$1" config commit.gpgsign false
}

# Creates a sandbox and ASSIGNS the globals BOX / VAULT / REMOTE.
# Deliberately not in a command substitution: it exports state.
#
#   $REMOTE          a bare repo, origin, default branch 'main'
#   $VAULT           a clone of it, wiki/ + logs/, on 'main'
# Branch litter is added per case by the helpers below.
new_vault() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  REMOTE="$BOX/remote.git"
  VAULT="$BOX/vault"

  local seed="$BOX/seed"
  mkdir -p "$seed/wiki" "$seed/logs"
  printf '# hot\n' >"$seed/wiki/hot.md"
  printf '# log\n' >"$seed/logs/x.md"
  # session.sh --status REFUSES a vault with no allowlist, and the reap asks it
  # about concurrent sessions — so a vault without this file is not a fixture of
  # anything real.
  printf 'logs/\nwiki/hot.md\nwiki/log.md\n' >"$seed/.saveinclude"
  git -c core.autocrlf=false -c core.eol=lf init -q -b main "$seed" >/dev/null 2>&1
  git_config "$seed"
  git -C "$seed" add -A >/dev/null 2>&1
  git -C "$seed" commit -q -m "initial vault" >/dev/null 2>&1

  git init -q --bare -b main "$REMOTE" >/dev/null 2>&1
  git -C "$seed" remote add origin "$REMOTE" >/dev/null 2>&1
  git -C "$seed" push -q origin main >/dev/null 2>&1

  git -c core.autocrlf=false -c core.eol=lf clone -q "$REMOTE" "$VAULT" >/dev/null 2>&1
  git_config "$VAULT"
  # origin/HEAD is what detect_default_branch() reads first; a fresh clone sets it,
  # but make it explicit so the case does not depend on the git version.
  git -C "$VAULT" remote set-head origin main >/dev/null 2>&1
}

# A branch whose work has ALREADY LANDED on main: branch, commit, merge into main,
# leave the branch behind. This is the litter shape the ticket measured.
merged_branch() { # name
  git -C "$VAULT" checkout -q -b "$1" main
  printf '%s\n' "$1" >>"$VAULT/logs/x.md"
  git -C "$VAULT" commit -q -am "work on $1" >/dev/null 2>&1
  git -C "$VAULT" checkout -q main
  git -C "$VAULT" merge -q --no-edit "$1" >/dev/null 2>&1
}

# A branch with a commit that is NOT on main. Deleting this would lose work.
unmerged_branch() { # name
  git -C "$VAULT" checkout -q -b "$1" main
  printf 'unmerged work on %s\n' "$1" >>"$VAULT/logs/x.md"
  git -C "$VAULT" commit -q -am "unmerged work on $1" >/dev/null 2>&1
  git -C "$VAULT" checkout -q main
}

# Runs the script against $VAULT from OUTSIDE it, proving $BRAIN_ROOT resolution.
# stdout -> $BOX/out.txt, stderr -> $BOX/err.txt. Echoes the exit status.
run_reap() { # [args...]
  (
    cd "$BOX" || exit 99
    BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="test-self" bash "$REAP" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  echo $?
}

cur_branch() { git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null; }

branch_exists() { # name
  git -C "$VAULT" show-ref --verify --quiet "refs/heads/$1"
}

if [[ ! -f "$REAP" ]]; then
  fail "reap-branches.sh/exists" "brain/bin/reap-branches.sh does not exist at $REAP"
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

# ============================================ merged litter is drained =======
new_vault
merged_branch "brain/save-2026-09-01"
merged_branch "brain/save-2026-09-02"
git -C "$VAULT" checkout -q -b "brain/save-2026-09-03" main   # the "current save"
merged_branch_head="$(git -C "$VAULT" rev-parse HEAD)"

status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "merged/exit-0" "0" "$status"
assert_contains "merged/ok-line" "$out" "REAP: OK -"
assert_eq "merged/ends-on-default" "main" "$(cur_branch)"
if branch_exists "brain/save-2026-09-01" || branch_exists "brain/save-2026-09-02"; then
  fail "merged/litter-deleted" "a fully merged brain/* branch survived the reap" "$out"
else
  pass "merged/litter-deleted"
fi
# The current save branch has no commits of its own here, so it too is merged.
assert_contains "merged/reports-count" "$out" "deleted 3 merged brain/* branch(es)"

# ================================== the load-bearing case: unmerged survives =
# `git branch -d` must refuse, the script must report it, and the commit must
# still be reachable afterwards. If this ever fails, the script is losing work.
new_vault
merged_branch "brain/save-2026-09-01"
unmerged_branch "brain/save-2026-09-09"
unmerged_sha="$(git -C "$VAULT" rev-parse "brain/save-2026-09-09")"
git -C "$VAULT" checkout -q "brain/save-2026-09-09"

status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "unmerged/exit-0" "0" "$status"
if branch_exists "brain/save-2026-09-09"; then
  pass "unmerged/branch-survives"
else
  fail "unmerged/branch-survives" "AN UNMERGED BRANCH WAS DELETED — work lost" "$out"
fi
assert_eq "unmerged/commit-still-reachable" \
  "$unmerged_sha" "$(git -C "$VAULT" rev-parse "brain/save-2026-09-09" 2>/dev/null)"
assert_contains "unmerged/reported-as-kept" "$out" "KEPT"
assert_contains "unmerged/named-in-output" "$out" "brain/save-2026-09-09"
assert_eq "unmerged/ends-on-default" "main" "$(cur_branch)"
if branch_exists "brain/save-2026-09-01"; then
  fail "unmerged/merged-sibling-still-drained" "the merged sibling survived" "$out"
else
  pass "unmerged/merged-sibling-still-drained"
fi

# ================================= branches outside brain/* are not touched ==
new_vault
merged_branch "feature/mine"
merged_branch "promote/notes"
merged_branch "brain/save-2026-09-01"
git -C "$VAULT" checkout -q main

status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "namespace/exit-0" "0" "$status"
if branch_exists "feature/mine" && branch_exists "promote/notes"; then
  pass "namespace/non-brain-branches-untouched"
else
  fail "namespace/non-brain-branches-untouched" "a branch outside brain/* was deleted" "$out"
fi
if branch_exists "brain/save-2026-09-01"; then
  fail "namespace/brain-branch-drained" "the brain/* branch survived" "$out"
else
  pass "namespace/brain-branch-drained"
fi

# ================================================ fast-forward from origin ===
new_vault
# Advance the remote behind our back, the way a merged PR does.
other="$BOX/other"
git -c core.autocrlf=false -c core.eol=lf clone -q "$REMOTE" "$other" >/dev/null 2>&1
git_config "$other"
printf 'landed elsewhere\n' >>"$other/logs/x.md"
git -C "$other" commit -q -am "landed via PR" >/dev/null 2>&1
git -C "$other" push -q origin main >/dev/null 2>&1
remote_sha="$(git -C "$other" rev-parse HEAD)"
git -C "$VAULT" checkout -q -b "brain/save-2026-09-10" main

status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "ff/exit-0" "0" "$status"
assert_eq "ff/default-advanced" "$remote_sha" "$(git -C "$VAULT" rev-parse main)"
assert_contains "ff/reported" "$out" "fast-forwarded 1 commit(s) from origin/main"

# ====================================== another live session => REFUSED ======
new_vault
merged_branch "brain/save-2026-09-01"
git -C "$VAULT" checkout -q -b "brain/save-2026-09-11" main
before_branch="$(cur_branch)"
# A real record written by the real writer, under a DIFFERENT session id.
BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="somebody-else" \
  bash "$REPO_ROOT/brain/bin/session.sh" --start "/brain:promote" >/dev/null 2>&1

status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "concurrent/exit-1" "1" "$status"
assert_contains "concurrent/refused-line" "$err" "REAP: REFUSED - 1 other session(s) are live"
assert_eq "concurrent/branch-unchanged" "$before_branch" "$(cur_branch)"
if branch_exists "brain/save-2026-09-01"; then
  pass "concurrent/nothing-deleted"
else
  fail "concurrent/nothing-deleted" "a branch was deleted despite the refusal" "$err"
fi

# ============================ a switch git will not make => REFUSED, no force =
new_vault
git -C "$VAULT" checkout -q -b "brain/save-2026-09-12" main
printf 'work in progress\n' >>"$VAULT/logs/x.md"
git -C "$VAULT" commit -q -am "committed on the save branch" >/dev/null 2>&1
# An uncommitted change to the same file main has at a different content: the
# switch would have to overwrite it, so git refuses.
printf 'uncommitted\n' >>"$VAULT/logs/x.md"
before_branch="$(cur_branch)"
before_file="$(cat "$VAULT/logs/x.md")"

status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "dirty/exit-1" "1" "$status"
assert_contains "dirty/refused-line" "$err" "REAP: REFUSED - could not switch"
assert_eq "dirty/branch-unchanged" "$before_branch" "$(cur_branch)"
assert_eq "dirty/worktree-unchanged" "$before_file" "$(cat "$VAULT/logs/x.md")"

# ================================================= detached HEAD => REFUSED ==
new_vault
git -C "$VAULT" checkout -q --detach main
status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "detached/exit-1" "1" "$status"
assert_contains "detached/refused-line" "$err" "REAP: REFUSED - the vault is in DETACHED HEAD"

# ==================================================== not a vault => REFUSED =
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/notavault"
mkdir -p "$VAULT"
status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "not-a-vault/exit-1" "1" "$status"
assert_contains "not-a-vault/refused-line" "$err" "doesn't look like a brain vault"

# ====================================================== unknown flag =========
new_vault
status="$(run_reap --wat)"
err="$(cat "$BOX/err.txt")"
assert_eq "unknown-flag/exit-1" "1" "$status"
assert_contains "unknown-flag/refused-line" "$err" "REAP: REFUSED - unknown argument"

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
