#!/usr/bin/env bash
# test-changed-wiki-notes.sh — deterministic quality gate for
# brain/bin/changed-wiki-notes.sh
#
# Contract under test:
#   Prints one vault-relative `wiki/**/*.md` path per line for every ACTUALLY
#   changed note (git working tree / index), NOT what manifest.json claims.
#     - without --since : uncommitted changes only
#     - with --since <ref> : additionally, files changed between <ref> and HEAD
#     - deletions are never listed (nothing left to re-extract)
#     - only wiki/**/*.md — nothing outside wiki/, no non-.md files
#     - paths with spaces are emitted verbatim (git's porcelain quoting must be
#       undone), renames report only the NEW path
#     - --porcelain prints an integer count first, then the paths
#     - read-only: never mutates the vault
#     - exit 0 normally, exit 2 + usage on stderr for an unknown flag
#   Vault resolution: $BRAIN_ROOT, then $CLAUDE_PROJECT_DIR, then $PWD.
#
# Run:  bash tests/test-changed-wiki-notes.sh   (from anywhere)
# No network, no real vault, no node/python required.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
CWN="$REPO_ROOT/brain/bin/changed-wiki-notes.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- helpers ---

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }

fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  shift
  local line
  for line in "$@"; do
    echo "     $line"
  done
}

assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected: [$2]" "actual:   [$3]"
  fi
}

# Number of lines on stdout of the last run (a trailing unterminated line counts).
line_count() { # file
  local n
  n="$(grep -c '' "$1" 2>/dev/null || echo 0)"
  echo "${n:-0}"
}

# Creates a fresh vault sandbox and ASSIGNS the globals BOX / VAULT.
# Deliberately NOT run in a command substitution: it has to export state.
#
# Layout:
#   $BOX/vault/wiki/one.md, wiki/two.md, wiki/area/deep.md
#   $BOX/vault/README.md, logs/x.md, graphify-out/y.md
# All committed, tree clean.
new_vault() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki/area" "$VAULT/logs" "$VAULT/graphify-out"
  printf '# one\n' >"$VAULT/wiki/one.md"
  printf '# two\n' >"$VAULT/wiki/two.md"
  printf '# deep\n' >"$VAULT/wiki/area/deep.md"
  printf '# readme\n' >"$VAULT/README.md"
  printf '# log\n' >"$VAULT/logs/x.md"
  printf '# out\n' >"$VAULT/graphify-out/y.md"
  git_init_commit "$VAULT" "initial vault"
}

# core.autocrlf=false / core.eol=lf: a global autocrlf=true otherwise makes a
# freshly created repo look dirty on Windows and every case would false-pass.
git_init_commit() { # dir message
  local d="$1" msg="$2"
  git -c core.autocrlf=false -c core.eol=lf init -q "$d" >/dev/null 2>&1
  git -C "$d" config core.autocrlf false
  git -C "$d" config core.eol lf
  git -C "$d" config user.email "test@example.invalid"
  git -C "$d" config user.name "Harness"
  git -C "$d" config commit.gpgsign false
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "$msg" >/dev/null 2>&1
}

git_commit_all() { # dir message
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -q -m "$2" >/dev/null 2>&1
}

# Runs the script against $VAULT with the CWD deliberately OUTSIDE the vault, so
# the run also proves $BRAIN_ROOT resolution. stdout -> $BOX/out.txt,
# stderr -> $BOX/err.txt. Echoes the exit status.
run_cwn() { # [args...]
  (
    cd "$BOX" || exit 99
    BRAIN_ROOT="$VAULT" bash "$CWN" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  echo $?
}

if [[ ! -f "$CWN" ]]; then
  for t in \
    "clean-tree/no-output" \
    "uncommitted/modified-and-added" \
    "deleted-note/not-listed" \
    "outside-wiki/never-listed" \
    "non-md-in-wiki/not-listed" \
    "since-ref/committed-note-listed" \
    "path-with-space/emitted-unquoted" \
    "rename/only-new-path" \
    "porcelain/count-matches-paths" \
    "unknown-flag/exit-2-usage-on-stderr" \
    "not-a-git-repo/exit-0-no-stdout" \
    "read-only/repo-state-unchanged"; do
    fail "$t" "brain/bin/changed-wiki-notes.sh does not exist at $CWN"
  done
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

echo "--- changed-wiki-notes.sh ---"

# --- 1. clean tree => no stdout, exit 0 ------------------------------------
new_vault
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
if [[ -z "$got" && "$status" == "0" ]]; then
  pass "clean-tree/no-output"
else
  fail "clean-tree/no-output" \
    "expected: empty stdout, exit 0" \
    "actual:   exit [$status], stdout [$got]" \
    "stderr:   [$(cat "$BOX/err.txt")]"
fi

# --- 2. one modified + one added wiki note (uncommitted) -------------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
mkdir -p "$VAULT/wiki/new"
printf '# three\n' >"$VAULT/wiki/new/three.md"
status="$(run_cwn)"
expected="$(printf 'wiki/new/three.md\nwiki/one.md')"
got="$(cat "$BOX/out.txt")"
assert_eq "uncommitted/modified-and-added" "$expected" "$got"
assert_eq "uncommitted/modified-and-added-exit-0" "0" "$status"

# --- 3. deleted note is NOT listed (nothing to re-extract) -----------------
new_vault
rm -f "$VAULT/wiki/two.md"
printf '# one changed\n' >>"$VAULT/wiki/one.md"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
if grep -qF 'wiki/one.md' "$BOX/out.txt" && ! grep -qF 'wiki/two.md' "$BOX/out.txt"; then
  pass "deleted-note/not-listed"
else
  fail "deleted-note/not-listed" \
    "expected wiki/one.md present and the DELETED wiki/two.md absent" \
    "actual stdout: [$got]" \
    "exit: $status  stderr: [$(cat "$BOX/err.txt")]"
fi

# --- 4. changes outside wiki/ are never listed -----------------------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
printf 'more\n' >>"$VAULT/logs/x.md"
printf 'more\n' >>"$VAULT/README.md"
printf 'more\n' >>"$VAULT/graphify-out/y.md"
printf '# brand new\n' >"$VAULT/logs/brand-new.md"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
assert_eq "outside-wiki/never-listed" "wiki/one.md" "$got"

# --- 5. non-.md file inside wiki/ is not listed ----------------------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
printf 'PNG-ish bytes\n' >"$VAULT/wiki/foo.png"
printf 'data\n' >"$VAULT/wiki/notes.txt"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
assert_eq "non-md-in-wiki/not-listed" "wiki/one.md" "$got"

# --- 6. --since <ref>: note committed after <ref>, clean tree --------------
new_vault
ref="$(git -C "$VAULT" rev-parse HEAD)"
printf '# four\n' >"$VAULT/wiki/four.md"
git_commit_all "$VAULT" "add four"
status="$(run_cwn --since "$ref")"
got="$(cat "$BOX/out.txt")"
if grep -qF 'wiki/four.md' "$BOX/out.txt" && [[ "$status" == "0" ]]; then
  pass "since-ref/committed-note-listed"
else
  fail "since-ref/committed-note-listed" \
    "expected wiki/four.md listed for --since $ref (tree is clean), exit 0" \
    "actual: exit [$status], stdout [$got]" \
    "stderr: [$(cat "$BOX/err.txt")]"
fi
# ... and WITHOUT --since the same clean tree yields nothing.
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
assert_eq "since-ref/omitted-means-uncommitted-only" "" "$got"

# --- 7. wiki note whose path contains a space ------------------------------
# git status --porcelain renders this as "wiki/a note.md" (quoted); naive
# parsing leaks the quotes, splits the path, or emits backslash escapes.
new_vault
printf '# spaced\n' >"$VAULT/wiki/a note.md"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
assert_eq "path-with-space/emitted-unquoted" "wiki/a note.md" "$got"
if [[ "$(line_count "$BOX/out.txt")" == "1" ]]; then
  pass "path-with-space/single-line"
else
  fail "path-with-space/single-line" \
    "expected exactly 1 output line" \
    "actual lines: $(line_count "$BOX/out.txt")" \
    "stdout (od -c): $(od -c "$BOX/out.txt" | head -n 3 | tr '\n' ' ')"
fi
if grep -qE '["\\]' "$BOX/out.txt"; then
  fail "path-with-space/no-quotes-or-backslashes" \
    "output contains a quote or backslash — porcelain quoting was not undone" \
    "stdout: [$got]"
else
  pass "path-with-space/no-quotes-or-backslashes"
fi

# --- 8. renamed wiki note (git mv, staged) => only the NEW path ------------
new_vault
git -C "$VAULT" mv "wiki/one.md" "wiki/renamed.md" >/dev/null 2>&1
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
if grep -qF 'wiki/renamed.md' "$BOX/out.txt" \
  && ! grep -qF 'wiki/one.md' "$BOX/out.txt" \
  && ! grep -qF -- '->' "$BOX/out.txt"; then
  pass "rename/only-new-path"
else
  fail "rename/only-new-path" \
    "expected only wiki/renamed.md — no old path, no 'old -> new' form" \
    "actual stdout: [$got]" \
    "exit: $status  stderr: [$(cat "$BOX/err.txt")]"
fi

# --- 9. --porcelain: first line is the count of the path lines -------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
printf '# five\n' >"$VAULT/wiki/five.md"
status="$(run_cwn --porcelain)"
first="$(head -n 1 "$BOX/out.txt")"
total="$(line_count "$BOX/out.txt")"
rest=$((total - 1))
if [[ "$first" =~ ^[0-9]+$ ]] && [[ "$first" -eq "$rest" ]] && [[ "$status" == "0" ]]; then
  pass "porcelain/count-matches-paths"
else
  fail "porcelain/count-matches-paths" \
    "expected first line to be an integer equal to the number of following path lines" \
    "first line: [$first]  following lines: [$rest]  exit: [$status]" \
    "stdout: [$(cat "$BOX/out.txt")]" \
    "stderr: [$(cat "$BOX/err.txt")]"
fi

# --- 10. unknown flag => exit 2 with usage on stderr -----------------------
new_vault
status="$(run_cwn --definitely-not-a-flag)"
err="$(cat "$BOX/err.txt")"
if [[ "$status" == "2" ]] && grep -qi 'usage' "$BOX/err.txt"; then
  pass "unknown-flag/exit-2-usage-on-stderr"
else
  fail "unknown-flag/exit-2-usage-on-stderr" \
    "expected: exit 2 and a usage message on stderr" \
    "actual:   exit [$status]" \
    "stderr:   [$err]" \
    "stdout:   [$(cat "$BOX/out.txt")]"
fi

# --- 11. vault is not a git repo => exit 0, no stdout, note on stderr ------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf '# lonely\n' >"$VAULT/wiki/lonely.md"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
err="$(cat "$BOX/err.txt")"
if [[ "$status" == "0" && -z "$got" && -n "$err" ]]; then
  pass "not-a-git-repo/exit-0-no-stdout"
else
  fail "not-a-git-repo/exit-0-no-stdout" \
    "expected: exit 0, empty stdout, non-empty stderr note" \
    "actual:   exit [$status], stdout [$got], stderr [$err]"
fi

# --- 12. read-only: repo state identical before and after ------------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
printf '# six\n' >"$VAULT/wiki/six.md"
rm -f "$VAULT/wiki/two.md"
head_before="$(git -C "$VAULT" rev-parse HEAD)"
git -C "$VAULT" status --porcelain >"$BOX/status.before"
status="$(run_cwn --porcelain)"
status2="$(run_cwn --since "$head_before")"
head_after="$(git -C "$VAULT" rev-parse HEAD)"
git -C "$VAULT" status --porcelain >"$BOX/status.after"
assert_eq "read-only/head-unchanged" "$head_before" "$head_after"
if cmp -s "$BOX/status.before" "$BOX/status.after"; then
  pass "read-only/worktree-unchanged"
else
  fail "read-only/worktree-unchanged" \
    "git status --porcelain differs after running the script" \
    "before: [$(cat "$BOX/status.before")]" \
    "after:  [$(cat "$BOX/status.after")]" \
    "exit codes: [$status] [$status2]"
fi

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
