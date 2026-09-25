#!/usr/bin/env bash
# test-resume-brief.sh — deterministic quality gate for brain/bin/resume-brief.sh
#
# Contract under test (INNOV-301):
#   /brain:resume briefs from origin/<default>, never from whatever the checkout
#   happens to be on, and never moves the working tree to get there.
#     - a checkout on a deleted save branch N commits behind: the briefing is
#       origin/<default>'s hot.md + logs, the ref is named, the drift is reported,
#       and HEAD / branch / working-tree bytes are identical afterwards
#     - a dirty tree gives the SAME output as a clean one
#     - an already-current checkout: BRIEF line only, no DRIFT line
#     - no remote: falls back to the working tree and says so, exit 0
#     - detached HEAD: briefing unaffected
#     - the default branch comes from lib/branch.sh (origin/HEAD), not a literal
#     - CRLF content is passed through byte-for-byte (the vault is autocrlf)
#   Contract lines: first stdout line "BRIEF: <ref>" or "BRIEF: worktree - ...",
#   optional second line "DRIFT: ...".
#
# Run:  bash tests/test-resume-brief.sh   (from anywhere)
# No network, no real vault. Never touches a vault outside its own sandbox.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
BRIEF="$REPO_ROOT/brain/bin/resume-brief.sh"

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

assert_not_contains() { # name haystack needle
  case "$2" in
    *"$3"*) fail "$1" "expected NOT to contain: [$3]" "actual: [$2]" ;;
    *)      pass "$1" ;;
  esac
}

git_config() { # dir
  git -C "$1" config core.autocrlf false
  git -C "$1" config core.eol lf
  git -C "$1" config user.email "test@example.invalid"
  git -C "$1" config user.name "Harness"
  git -C "$1" config commit.gpgsign false
}

# Creates a sandbox and ASSIGNS the globals BOX / VAULT / REMOTE / SEED.
#   $REMOTE  a bare repo, origin, default branch $1 (default 'main')
#   $SEED    a second clone used to land "other people's" commits on the remote
#   $VAULT   the checkout under test, on the default branch
new_vault() { # [default-branch]
  local def="${1:-main}"
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  REMOTE="$BOX/remote.git"
  VAULT="$BOX/vault"
  SEED="$BOX/seed"

  mkdir -p "$SEED/wiki" "$SEED/logs"
  printf '# hot OLD\n' >"$SEED/wiki/hot.md"
  printf '# index\n' >"$SEED/wiki/index.md"
  printf '' >"$SEED/logs/.gitkeep"
  printf 'old log 1\n' >"$SEED/logs/2026-09-01-a.md"
  printf 'old log 2\n' >"$SEED/logs/2026-09-02-b.md"
  git -c core.autocrlf=false -c core.eol=lf init -q -b "$def" "$SEED" >/dev/null 2>&1
  git_config "$SEED"
  git -C "$SEED" add -A >/dev/null 2>&1
  git -C "$SEED" commit -q -m "initial vault" >/dev/null 2>&1

  git init -q --bare -b "$def" "$REMOTE" >/dev/null 2>&1
  git -C "$SEED" remote add origin "$REMOTE" >/dev/null 2>&1
  git -C "$SEED" push -q origin "$def" >/dev/null 2>&1

  git -c core.autocrlf=false -c core.eol=lf clone -q "$REMOTE" "$VAULT" >/dev/null 2>&1
  git_config "$VAULT"
  git -C "$VAULT" remote set-head origin "$def" >/dev/null 2>&1
}

# Lands NEW content on the remote's default branch from the seed clone, then
# fetches it into the vault. The vault's checkout does not move.
advance_remote() { # default-branch
  printf '# hot NEW\n' >"$SEED/wiki/hot.md"
  printf 'new log 3\n' >"$SEED/logs/2026-09-21-c.md"
  printf 'new log 4\n' >"$SEED/logs/2026-09-22-d.md"
  git -C "$SEED" add -A >/dev/null 2>&1
  git -C "$SEED" commit -q -m "other sessions landed" >/dev/null 2>&1
  git -C "$SEED" push -q origin "$1" >/dev/null 2>&1
  git -C "$VAULT" fetch -q --prune origin >/dev/null 2>&1
}

# Puts the vault on a save branch that was pushed, then deleted upstream (merged
# and cleaned up), so its upstream is [gone] and it is behind origin/<default>.
stale_save_branch() { # default-branch
  git -C "$VAULT" checkout -q -b brain/save-2026-09-10-mason
  git -C "$VAULT" push -q -u origin brain/save-2026-09-10-mason >/dev/null 2>&1
  git -C "$SEED" push -q origin --delete brain/save-2026-09-10-mason >/dev/null 2>&1
  advance_remote "$1"
}

# Runs the script against $VAULT from OUTSIDE it, proving $BRAIN_ROOT resolution.
# stdout -> $BOX/out.txt, stderr -> $BOX/err.txt. Echoes the exit status.
run_brief() { # [args...]
  (
    cd "$BOX" || exit 99
    BRAIN_ROOT="$VAULT" bash "$BRIEF" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  echo $?
}

tree_state() { # HEAD sha, branch, porcelain status and hot.md bytes
  printf '%s|%s|%s|%s' \
    "$(git -C "$VAULT" rev-parse HEAD 2>/dev/null)" \
    "$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    "$(git -C "$VAULT" status --porcelain 2>/dev/null)" \
    "$(od -c "$VAULT/wiki/hot.md" 2>/dev/null)"
}

if [[ ! -f "$BRIEF" ]]; then
  fail "resume-brief.sh/exists" "brain/bin/resume-brief.sh does not exist at $BRIEF"
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

# ================ the reported case: deleted save branch, N commits behind ====
# Negative control: the working tree holds "OLD", origin/main holds "NEW". A
# script that reads the working tree fails every content assertion here.
new_vault
stale_save_branch main
before="$(tree_state)"

status="$(run_brief)"
out="$(cat "$BOX/out.txt")"
assert_eq "stale/exit-0" "0" "$status"
assert_eq "stale/brief-line" "BRIEF: origin/main" "$(head -n 1 "$BOX/out.txt")"
assert_contains "stale/drift-line" "$out" "DRIFT:"
assert_contains "stale/drift-names-branch" "$out" "brain/save-2026-09-10-mason"
assert_contains "stale/drift-counts-behind" "$out" "1 commit(s) behind origin/main"
assert_contains "stale/drift-upstream-gone" "$out" "upstream is gone"

status="$(run_brief --cat wiki/hot.md)"
assert_eq "stale/cat-exit-0" "0" "$status"
assert_eq "stale/hot-from-origin" "# hot NEW" "$(cat "$BOX/out.txt")"

status="$(run_brief --logs)"
logs="$(cat "$BOX/out.txt")"
assert_eq "stale/logs-exit-0" "0" "$status"
assert_eq "stale/logs-newest-3-from-origin" \
  "logs/2026-09-02-b.md
logs/2026-09-21-c.md
logs/2026-09-22-d.md" "$logs"
assert_not_contains "stale/logs-skip-gitkeep" "$logs" ".gitkeep"

status="$(run_brief --cat logs/2026-09-22-d.md)"
assert_eq "stale/log-body-from-origin" "new log 4" "$(cat "$BOX/out.txt")"

assert_eq "stale/tree-untouched" "$before" "$(tree_state)"

# ============================ dirty tree => byte-identical briefing output ====
clean_out="$(run_brief >/dev/null; cat "$BOX/out.txt")"
printf 'uncommitted edit\n' >>"$VAULT/wiki/hot.md"
before="$(tree_state)"
status="$(run_brief)"
assert_eq "dirty/exit-0" "0" "$status"
assert_eq "dirty/same-output-as-clean" "$clean_out" "$(cat "$BOX/out.txt")"
run_brief --cat wiki/hot.md >/dev/null
assert_eq "dirty/hot-still-from-origin" "# hot NEW" "$(cat "$BOX/out.txt")"
assert_eq "dirty/tree-untouched" "$before" "$(tree_state)"

# ============================================== already current => no drift ===
new_vault
status="$(run_brief)"
assert_eq "current/exit-0" "0" "$status"
assert_eq "current/brief-line-only" "BRIEF: origin/main" "$(cat "$BOX/out.txt")"

# ===================================== detached HEAD => briefing unaffected ===
new_vault
advance_remote main
git -C "$VAULT" checkout -q --detach HEAD
before="$(tree_state)"
status="$(run_brief)"
assert_eq "detached/exit-0" "0" "$status"
assert_eq "detached/brief-line" "BRIEF: origin/main" "$(head -n 1 "$BOX/out.txt")"
run_brief --cat wiki/hot.md >/dev/null
assert_eq "detached/hot-from-origin" "# hot NEW" "$(cat "$BOX/out.txt")"
assert_eq "detached/tree-untouched" "$before" "$(tree_state)"

# ============ default comes from origin/HEAD (lib/branch.sh), not a literal ===
# 'trunk' is neither main nor master; a hard-coded main/master loop finds nothing.
new_vault trunk
advance_remote trunk
status="$(run_brief)"
assert_eq "trunk/exit-0" "0" "$status"
assert_eq "trunk/brief-line" "BRIEF: origin/trunk" "$(head -n 1 "$BOX/out.txt")"
run_brief --cat wiki/hot.md >/dev/null
assert_eq "trunk/hot-from-origin" "# hot NEW" "$(cat "$BOX/out.txt")"

# ============================ no remote => working tree, said out loud, exit 0 =
new_vault
git -C "$VAULT" remote remove origin >/dev/null 2>&1
status="$(run_brief)"
out="$(cat "$BOX/out.txt")"
assert_eq "noremote/exit-0" "0" "$status"
assert_contains "noremote/brief-worktree" "$(head -n 1 "$BOX/out.txt")" "BRIEF: worktree - "
assert_contains "noremote/not-current" "$out" "may not be current"
status="$(run_brief --cat wiki/hot.md)"
assert_eq "noremote/cat-exit-0" "0" "$status"
assert_eq "noremote/hot-from-tree" "# hot OLD" "$(cat "$BOX/out.txt")"
run_brief --logs >/dev/null
assert_eq "noremote/logs-from-tree" "logs/2026-09-01-a.md
logs/2026-09-02-b.md" "$(cat "$BOX/out.txt")"

# ======================================= missing file => exit 1, not empty ====
new_vault
status="$(run_brief --cat wiki/nope.md)"
assert_eq "missing/exit-1" "1" "$status"

# ======================================== CRLF content passes through intact ==
new_vault
printf '# hot CRLF\r\nline two\r\n' >"$SEED/wiki/hot.md"
git -C "$SEED" commit -q -am "crlf hot" >/dev/null 2>&1
git -C "$SEED" push -q origin main >/dev/null 2>&1
git -C "$VAULT" fetch -q origin >/dev/null 2>&1
run_brief --cat wiki/hot.md >/dev/null
assert_eq "crlf/bytes-preserved" \
  "$(printf '# hot CRLF\r\nline two\r\n' | od -c)" "$(od -c <"$BOX/out.txt")"

echo
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
