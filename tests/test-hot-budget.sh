#!/usr/bin/env bash
# test-hot-budget.sh — deterministic quality gate for brain/bin/check-hot-budget.sh
#
# wiki/hot.md has a documented HARD ~500-word budget. Enforced by prose it drifted:
# the file shipped at 709 words twice in one session. check-hot-budget.sh moves the
# rule into a script — it measures, reports the number on every run, and refuses
# when the file is over.
#
# Contract under test:
#   exit 0 => at or under budget (also: no hot.md / unreadable hot.md — a guard
#             against bloat must not block a save over a file that isn't there)
#   exit 1 => OVER budget
#   first line of output starts with `HOT-BUDGET: OK`   (stdout)
#                                 or `HOT-BUDGET: OVER` (stderr)
#   BOTH verdict lines carry the word count, the budget and the overage
#   vault resolved from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD
#   HOT_WORD_BUDGET overrides the 500 default
#
# Run:  bash tests/test-hot-budget.sh   (from anywhere)
# No network, no git, no real vault. Every case gets its own mktemp -d sandbox.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
GUARD="$REPO_ROOT/brain/bin/check-hot-budget.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { chmod -R u+rwX "$TMPROOT" 2>/dev/null || true; rm -rf "$TMPROOT" 2>/dev/null || true; }
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

assert_eq() { # name expected actual [evidence...]
  local name="$1" exp="$2" act="$3"
  shift 3
  if [[ "$exp" == "$act" ]]; then
    pass "$name"
  else
    fail "$name" "expected: [$exp]" "actual:   [$act]" "$@"
  fi
}

assert_prefix() { # name prefix actual [evidence...]
  local name="$1" pre="$2" act="$3"
  shift 3
  if [[ "$act" == "$pre"* ]]; then
    pass "$name"
  else
    fail "$name" "expected line starting with: [$pre]" "actual line:                [$act]" "$@"
  fi
}

assert_contains() { # name needle haystack [evidence...]
  local name="$1" needle="$2" hay="$3"
  shift 3
  if [[ "$hay" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "expected to contain: [$needle]" "actual:              [$hay]" "$@"
  fi
}

# First line of a file, with any trailing CR stripped (Git Bash / CRLF safety).
first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

evidence() { # box -> a few lines of captured output for failure messages
  local box="$1"
  echo "stdout: [$(tr '\n' '|' <"$box/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$box/err.txt" 2>/dev/null)]"
}

# ------------------------------------------------------------ sandboxing ---

# Assigns the globals BOX / VAULT. Deliberately NOT run in a command
# substitution — the assignments would be lost and state would leak between
# cases (a previous harness in this repo made exactly that mistake).
BOX=""
VAULT=""
sb_new() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki"
}

# Writes wiki/hot.md with exactly $1 whitespace-separated words.
write_words() { # n
  local n="$1" i
  : >"$VAULT/wiki/hot.md"
  for ((i = 1; i <= n; i++)); do
    printf 'w%d ' "$i" >>"$VAULT/wiki/hot.md"
  done
  printf '\n' >>"$VAULT/wiki/hot.md"
}

STATUS=""
# Runs the guard against $1 (vault dir), capturing streams into $BOX/out.txt and
# $BOX/err.txt and the exit code into $STATUS. Extra args are env assignments.
run_guard() { # vault [VAR=value...]
  local vault="$1"
  shift
  (
    cd "$vault" 2>/dev/null || cd "$BOX" || exit 127
    unset CLAUDE_PROJECT_DIR
    unset HOT_WORD_BUDGET
    env BRAIN_ROOT="$vault" "$@" bash "$GUARD"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

out_all() { cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | tr '\n' ' ' | tr -d '\r'; }

if [[ ! -f "$GUARD" ]]; then
  echo "note: $GUARD does not exist yet — every case below is expected to FAIL until it lands."
fi

# ================================================================== CASES ===

# --- 1. comfortably under budget => exit 0, count reported ----------------
echo "--- 1. under budget ---"
sb_new
write_words 120
run_guard "$VAULT"
assert_eq "under/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "under/stdout-first-line-OK" "HOT-BUDGET: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "under/reports-actual-word-count" "120" "$(first_line "$BOX/out.txt")" \
  "ask 2: the number must be visible on the PASS path too" "$(evidence "$BOX")"
assert_contains "under/reports-the-budget" "500" "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_contains "under/reports-overage-on-pass-path" "over" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_eq "under/file-not-modified" "120" \
  "$(wc -w <"$VAULT/wiki/hot.md" | tr -d ' \r')" \
  "the guard must measure, never edit" "$(evidence "$BOX")"

# --- 2. BOUNDARY: exactly at budget => exit 0 ----------------------------
echo "--- 2. exactly at budget (boundary) ---"
sb_new
write_words 500
run_guard "$VAULT"
assert_eq "at-budget/exit-0" "0" "$STATUS" \
  "500 words is AT the budget, not over it" "$(evidence "$BOX")"
assert_prefix "at-budget/stdout-first-line-OK" "HOT-BUDGET: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "at-budget/reports-500" "500" "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"

# --- 3. BOUNDARY: one word over => exit 1 --------------------------------
echo "--- 3. one word over budget (boundary) ---"
sb_new
write_words 501
run_guard "$VAULT"
assert_eq "one-over/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
assert_prefix "one-over/stderr-first-line-OVER" "HOT-BUDGET: OVER" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_contains "one-over/reports-count-501" "501" "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"

# --- 4. THE REGRESSION: 709 words, twice-shipped => exit 1 ---------------
echo "--- 4. the 709-word regression ---"
sb_new
write_words 709
run_guard "$VAULT"
assert_eq "regression-709/exit-1" "1" "$STATUS" \
  "hot.md shipped at 709 words twice under prose enforcement; the script must refuse it" \
  "$(evidence "$BOX")"
assert_prefix "regression-709/stderr-first-line-OVER" "HOT-BUDGET: OVER" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
assert_contains "regression-709/reports-actual-count" "709" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_contains "regression-709/reports-the-budget" "500" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_contains "regression-709/reports-the-overage" "209" "$(first_line "$BOX/err.txt")" \
  "709 - 500 = 209 must be stated, not left for the reader to subtract" "$(evidence "$BOX")"
assert_eq "regression-709/nothing-on-stdout-before-verdict" "" \
  "$(first_line "$BOX/out.txt")" \
  "the OVER verdict belongs on stderr; stdout must not lead with something else" \
  "$(evidence "$BOX")"

# --- 5. 709 words but 750-word backstop budget => exit 0 -----------------
# freshness.mjs keeps a separate 1.5x (~750) backstop. Proves the two
# thresholds are independent and that the env override really moves the gate.
echo "--- 5. 709 words under a custom 750 budget ---"
sb_new
write_words 709
run_guard "$VAULT" HOT_WORD_BUDGET=750
assert_eq "custom-750/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "custom-750/stdout-first-line-OK" "HOT-BUDGET: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "custom-750/reports-custom-budget" "750" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 6. custom budget that TIGHTENS the gate => exit 1 -------------------
echo "--- 6. custom budget tightens the gate ---"
sb_new
write_words 120
run_guard "$VAULT" HOT_WORD_BUDGET=100
assert_eq "custom-100/exit-1" "1" "$STATUS" \
  "HOT_WORD_BUDGET must be able to tighten, not only loosen" "$(evidence "$BOX")"
assert_prefix "custom-100/stderr-first-line-OVER" "HOT-BUDGET: OVER" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_contains "custom-100/reports-overage-20" "20" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"

# --- 7. junk budget falls back to 500 rather than disabling the gate ----
echo "--- 7. junk HOT_WORD_BUDGET ---"
sb_new
write_words 709
run_guard "$VAULT" HOT_WORD_BUDGET=lots
assert_eq "junk-budget/still-exit-1" "1" "$STATUS" \
  "a typo'd budget must not silently disable the gate" "$(evidence "$BOX")"
assert_contains "junk-budget/falls-back-to-500" "500" "$(out_all)" "$(evidence "$BOX")"

# --- 8. missing hot.md => exit 0, DOCUMENTED as a pass -------------------
# Same stance as check-freshness.sh: missing preconditions are never failures.
# A vault mid-setup has no hot.md and must not be blocked from saving.
echo "--- 8. missing hot.md ---"
sb_new
run_guard "$VAULT"
assert_eq "missing/exit-0" "0" "$STATUS" \
  "a vault with no hot.md yet must not be blocked (documented behaviour)" "$(evidence "$BOX")"
assert_prefix "missing/stdout-first-line-OK" "HOT-BUDGET: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
if grep -qi 'skip' "$BOX/out.txt"; then
  pass "missing/says-check-skipped"
else
  fail "missing/says-check-skipped" "expected stdout to say the check was skipped" \
    "$(evidence "$BOX")"
fi
if [[ -e "$VAULT/wiki/hot.md" ]]; then
  fail "missing/did-not-create-hot-md" "the guard created $VAULT/wiki/hot.md" "$(evidence "$BOX")"
else
  pass "missing/did-not-create-hot-md"
fi

# --- 9. no wiki/ dir at all => exit 0 -----------------------------------
echo "--- 9. no wiki/ directory ---"
sb_new
rm -rf "$VAULT/wiki"
run_guard "$VAULT"
assert_eq "no-wiki/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "no-wiki/stdout-first-line-OK" "HOT-BUDGET: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 10. unreadable hot.md => exit 0, skipped ---------------------------
# chmod 000 is a no-op for an elevated user and on some Windows filesystems, so
# fall back to a directory in place of the file — also "not a readable regular
# file", and portable. Either way the guard must skip, not crash.
echo "--- 10. unreadable hot.md ---"
sb_new
write_words 10
chmod 000 "$VAULT/wiki/hot.md" 2>/dev/null || true
unreadable_kind="chmod-000"
if [[ -r "$VAULT/wiki/hot.md" ]]; then
  chmod u+rw "$VAULT/wiki/hot.md" 2>/dev/null || true
  rm -f "$VAULT/wiki/hot.md"
  mkdir -p "$VAULT/wiki/hot.md"
  unreadable_kind="directory-in-place-of-file"
fi
run_guard "$VAULT"
assert_eq "unreadable/exit-0-does-not-block-save ($unreadable_kind)" "0" "$STATUS" \
  "$(evidence "$BOX")"
assert_prefix "unreadable/stdout-first-line-OK" "HOT-BUDGET: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
if grep -qi 'skip' "$BOX/out.txt"; then
  pass "unreadable/says-check-skipped"
else
  fail "unreadable/says-check-skipped" "expected stdout to say the check was skipped" \
    "$(evidence "$BOX")"
fi
chmod u+rw "$VAULT/wiki/hot.md" 2>/dev/null || true

# --- 11. empty hot.md => 0 words, exit 0 --------------------------------
echo "--- 11. empty hot.md ---"
sb_new
: >"$VAULT/wiki/hot.md"
run_guard "$VAULT"
assert_eq "empty/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "empty/stdout-first-line-OK" "HOT-BUDGET: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "empty/reports-zero-words" "0 words" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 12. whitespace-only hot.md => 0 words, exit 0 ----------------------
echo "--- 12. whitespace-only hot.md ---"
sb_new
printf '\n\n   \n\t\n' >"$VAULT/wiki/hot.md"
run_guard "$VAULT"
assert_eq "whitespace/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_contains "whitespace/reports-zero-words" "0 words" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 13. vault resolution: CLAUDE_PROJECT_DIR and PWD fallbacks ---------
echo "--- 13. vault resolution fallbacks ---"
sb_new
write_words 709
(
  cd "$BOX" || exit 127
  unset BRAIN_ROOT
  unset HOT_WORD_BUDGET
  CLAUDE_PROJECT_DIR="$VAULT" bash "$GUARD"
) >"$BOX/out.txt" 2>"$BOX/err.txt"
STATUS=$?
assert_eq "resolve/CLAUDE_PROJECT_DIR/exit-1" "1" "$STATUS" \
  "the vault must resolve from CLAUDE_PROJECT_DIR when BRAIN_ROOT is unset" "$(evidence "$BOX")"
assert_contains "resolve/CLAUDE_PROJECT_DIR/reports-709" "709" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"

sb_new
write_words 709
(
  cd "$VAULT" || exit 127
  unset BRAIN_ROOT
  unset CLAUDE_PROJECT_DIR
  unset HOT_WORD_BUDGET
  bash "$GUARD"
) >"$BOX/out.txt" 2>"$BOX/err.txt"
STATUS=$?
assert_eq "resolve/PWD/exit-1" "1" "$STATUS" \
  "the vault must fall back to \$PWD" "$(evidence "$BOX")"
assert_contains "resolve/PWD/reports-709" "709" "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"

# --- 14. the guard is read-only and side-effect free --------------------
echo "--- 14. read-only ---"
sb_new
write_words 709
cp "$VAULT/wiki/hot.md" "$BOX/hot.expected"
listing_before="$(ls -A "$VAULT" "$VAULT/wiki" | tr '\n' '|')"
run_guard "$VAULT"
assert_eq "read-only/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
if cmp -s "$BOX/hot.expected" "$VAULT/wiki/hot.md"; then
  pass "read-only/hot-md-byte-for-byte-unchanged"
else
  fail "read-only/hot-md-byte-for-byte-unchanged" \
    "the guard altered wiki/hot.md" "$(evidence "$BOX")"
fi
assert_eq "read-only/no-files-created-or-removed" "$listing_before" \
  "$(ls -A "$VAULT" "$VAULT/wiki" | tr '\n' '|')" "$(evidence "$BOX")"
if [[ -e "$VAULT/.git" ]]; then
  fail "read-only/no-git-repo-created" "the guard created $VAULT/.git" "$(evidence "$BOX")"
else
  pass "read-only/no-git-repo-created"
fi

# --- 15. verdict discipline: exactly one HOT-BUDGET line, first, per run -
echo "--- 15. verdict discipline ---"
for words in 120 500 709; do
  sb_new
  write_words "$words"
  run_guard "$VAULT"
  count="$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^HOT-BUDGET:')"
  assert_eq "verdict/$words/exactly-one-verdict-line" "1" "$count" "$(evidence "$BOX")"
  assert_contains "verdict/$words/count-visible-in-output" "$words words" "$(out_all)" \
    "ask 2: report the number on every path" "$(evidence "$BOX")"
done

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
