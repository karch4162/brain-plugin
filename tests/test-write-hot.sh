#!/usr/bin/env bash
# test-write-hot.sh — deterministic quality gate for brain/bin/write-hot.sh
#
# /brain:save step 3 REWRITES wiki/hot.md wholesale (it is a rolling cache; the
# history lives in logs/). Two overlapping sessions each read it, each rewrite
# it, and the later write silently discards the earlier — with NO merge conflict,
# because both wrote a whole file and git only ever sees the last one.
#
# Of everything INNOV-275 lists, this is the ONLY UNRECOVERABLE LOSS: a
# cross-contaminated commit has wrong attribution but nothing is gone, a commit
# on the wrong branch can be moved, a lost log.md line is one line. A discarded
# hot.md rewrite is a session's curation that exists nowhere else.
#
# So the rewrite is a compare-and-swap: pin the hash when you read, and install
# the new content only if it still matches. The check and the write have to be
# ONE operation — "verify immediately before the rewrite" is not something an
# agent can promise across a dozen tool calls, and the file is already gone by
# the time anyone notices. Hence a script, hence this test.
#
# Contract under test:
#   exit 0 => the operation succeeded (pin recorded / new hot.md installed)
#   exit 1 => REFUSED; the EXISTING hot.md is untouched and the new content is
#             left where the caller wrote it, so nothing is lost either way
#   first line of output starts with `HOT-WRITE: OK`      (stdout)
#                                 or `HOT-WRITE: REFUSED` (stderr)
#   vault resolved from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD
#   the pin lives at <vault>/.brain/hot.pin (machine-local, gitignored)
#
# The refusals, all fail-closed:
#   hot.md changed since --pin  — the whole point
#   no pin recorded             — an unpinned write IS the unguarded rewrite
#   --write with no/unreadable file argument
#
# Run:  bash tests/test-write-hot.sh   (from anywhere)
# No network, no git, no real vault. Every case gets its own mktemp -d sandbox.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
GUARD="$REPO_ROOT/brain/bin/write-hot.sh"

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

assert_file_is() { # name expected-content path [evidence...]
  local name="$1" exp="$2" path="$3"
  shift 3
  local act
  act="$(cat "$path" 2>/dev/null | tr -d '\r')"
  if [[ "$act" == "$exp" ]]; then
    pass "$name"
  else
    fail "$name" "expected file content: [$exp]" "actual:                [$act]" "$@"
  fi
}

# First line of a file, with any trailing CR stripped (Git Bash / CRLF safety).
first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

evidence() {
  echo "exit:   [$STATUS]"
  echo "stdout: [$(tr '\n' '|' <"$BOX/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$BOX/err.txt" 2>/dev/null)]"
}

# ------------------------------------------------------------ sandboxing ---

# Assigns the globals BOX / VAULT / NEW. Deliberately NOT run in a command
# substitution — the assignments would be lost and state would leak between
# cases (a previous harness in this repo made exactly that mistake).
BOX=""
VAULT=""
NEW=""
sb_new() { # [initial hot.md content; omit for a vault with no hot.md yet]
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  NEW="$BOX/new-hot.md"
  mkdir -p "$VAULT/wiki"
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$1" >"$VAULT/wiki/hot.md"
  fi
  printf 'my rewritten hot.md\n' >"$NEW"
}

hot() { cat "$VAULT/wiki/hot.md" 2>/dev/null | tr -d '\r'; }
pin_file() { echo "$VAULT/.brain/hot.pin"; }

STATUS=""
# Runs the guard, capturing streams into $BOX/out.txt / $BOX/err.txt and the exit
# code into $STATUS.
run_guard() { # [args...]
  (
    cd "$VAULT" 2>/dev/null || cd "$BOX" || exit 127
    unset CLAUDE_PROJECT_DIR
    BRAIN_ROOT="$VAULT" bash "$GUARD" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

out_all() { cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | tr '\n' ' ' | tr -d '\r'; }

if [[ ! -f "$GUARD" ]]; then
  echo "note: $GUARD does not exist yet — every case below is expected to FAIL until it lands."
fi

echo "--- A. pin, then write: the normal path ---"

# --- 1. --pin records a pin and changes nothing else ----------------------
sb_new "original hot content"
run_guard --pin
assert_eq "pin/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "pin/stdout-verdict-line" "HOT-WRITE: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "pin/hot-md-untouched" "original hot content" "$(hot)" "$(evidence)"
if [[ -f "$(pin_file)" ]]; then
  pass "pin/pin-file-created"
else
  fail "pin/pin-file-created" "expected a pin at $(pin_file)" "$(evidence)"
fi

# --- 2. pin then write installs the new content ---------------------------
sb_new "original hot content"
run_guard --pin
run_guard --write "$NEW"
assert_eq "write/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "write/stdout-verdict-line" "HOT-WRITE: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "write/content-installed" "my rewritten hot.md" "$(hot)" "$(evidence)"
assert_contains "write/reports-word-count" "words" "$(out_all)" "$(evidence)"

# --- 3. the pin advances after a write, so a second write needs no re-pin --
# /brain:save trims hot.md again when check-hot-budget.sh says OVER. That trim
# must not need its own --pin, or the skill grows a step people forget.
sb_new "original hot content"
run_guard --pin
run_guard --write "$NEW"
printf 'trimmed down\n' >"$BOX/trimmed.md"
run_guard --write "$BOX/trimmed.md"
assert_eq "write/second-write-without-repinning" "0" "$STATUS" "$(evidence)"
assert_eq "write/second-write-content" "trimmed down" "$(hot)" "$(evidence)"

# --- 4. --status reports without changing anything ------------------------
sb_new "original hot content"
run_guard --pin
run_guard --status
assert_eq "status/exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "status/hot-md-untouched" "original hot content" "$(hot)" "$(evidence)"
assert_contains "status/says-it-matches" "still matches" "$(out_all)" "$(evidence)"

echo "--- B. THE GUARD: a concurrent rewrite is refused ---"

# --- 5. hot.md changed after the pin => REFUSE ---------------------------
# The whole reason this script exists. Session A pins and edits; session B saves
# first; A's write must not land on top of B's.
sb_new "original hot content"
run_guard --pin
printf 'ANOTHER SESSION WROTE THIS\n' >"$VAULT/wiki/hot.md"
run_guard --write "$NEW"
assert_eq "concurrent/refused" "1" "$STATUS" "$(evidence)"
assert_prefix "concurrent/stderr-verdict-line" "HOT-WRITE: REFUSED" "$(first_line "$BOX/err.txt")" "$(evidence)"

# --- 6. ...and the OTHER session's content survives intact ---------------
# A refusal that still clobbered the file would be worse than no guard: it would
# lose the data AND report a failure.
assert_eq "concurrent/other-sessions-content-survives" "ANOTHER SESSION WROTE THIS" "$(hot)" "$(evidence)"

# --- 7. ...and the caller's own new content is not consumed either -------
# Nothing is lost on either side; the caller can re-read, fold, and retry.
assert_file_is "concurrent/callers-content-preserved" "my rewritten hot.md" "$NEW" "$(evidence)"
assert_contains "concurrent/points-at-the-callers-file" "$NEW" "$(out_all)" "$(evidence)"

# --- 8. even a ONE-BYTE change is caught ---------------------------------
# The hash is byte-exact and deliberately dumb. A false refusal costs a re-read;
# a false match costs someone's session.
sb_new "original hot content"
run_guard --pin
printf 'original hot content \n' >"$VAULT/wiki/hot.md"   # one trailing space
run_guard --write "$NEW"
assert_eq "concurrent/one-byte-change-caught" "1" "$STATUS" "$(evidence)"

# --- 9. --status predicts the refusal instead of asserting a match -------
sb_new "original hot content"
run_guard --pin
printf 'changed\n' >"$VAULT/wiki/hot.md"
run_guard --status
assert_eq "status/exit-0-even-when-mismatched" "0" "$STATUS" "$(evidence)"
assert_contains "status/predicts-the-refusal" "would refuse" "$(out_all)" "$(evidence)"

echo "--- C. fail-closed: no pin, and the absent-file case ---"

# --- 10. --write with no pin => REFUSE ----------------------------------
# NOT "write anyway". An unpinned write is precisely the unguarded rewrite this
# script replaces, and allowing it would make the guard optional in the exact
# situation where it gets skipped by accident.
sb_new "original hot content"
run_guard --write "$NEW"
assert_eq "no-pin/refused" "1" "$STATUS" "$(evidence)"
assert_eq "no-pin/hot-md-untouched" "original hot content" "$(hot)" "$(evidence)"
assert_contains "no-pin/names-the-remedy" "--pin" "$(out_all)" "$(evidence)"

# --- 11. a vault with no hot.md pins as `absent`, and the first write works --
sb_new                                    # no hot.md at all
run_guard --pin
assert_eq "absent/pin-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "absent/pin-says-absent" "absent" "$(out_all)" "$(evidence)"
run_guard --write "$NEW"
assert_eq "absent/first-write-succeeds" "0" "$STATUS" "$(evidence)"
assert_eq "absent/first-write-content" "my rewritten hot.md" "$(hot)" "$(evidence)"

# --- 12. ...but a file that APPEARS between pin and write is caught ------
# `absent` is a real, comparable state, not an error and not an empty string, so
# "someone created hot.md while I was working" is detectable rather than
# indistinguishable from "no hash available".
sb_new                                    # no hot.md at all
run_guard --pin
printf 'another session created it first\n' >"$VAULT/wiki/hot.md"
run_guard --write "$NEW"
assert_eq "absent/appeared-mid-flight-refused" "1" "$STATUS" "$(evidence)"
assert_eq "absent/appeared-mid-flight-content-survives" "another session created it first" "$(hot)" "$(evidence)"

echo "--- D. arguments and preconditions ---"

# --- 13. --write with no file argument ----------------------------------
sb_new "original hot content"
run_guard --pin
run_guard --write
assert_eq "args/write-without-file-refused" "1" "$STATUS" "$(evidence)"
assert_eq "args/write-without-file-hot-untouched" "original hot content" "$(hot)" "$(evidence)"

# --- 14. --write pointed at a file that isn't there ---------------------
sb_new "original hot content"
run_guard --pin
run_guard --write "$BOX/does-not-exist.md"
assert_eq "args/write-missing-file-refused" "1" "$STATUS" "$(evidence)"
assert_eq "args/write-missing-file-hot-untouched" "original hot content" "$(hot)" "$(evidence)"

# --- 15. no mode, and an unknown mode, are both refused -----------------
# A typo'd mode that fell through to "do nothing, exit 0" would look to the
# caller exactly like a successful guarded write.
sb_new "original hot content"
run_guard
assert_eq "args/no-mode-refused" "1" "$STATUS" "$(evidence)"
sb_new "original hot content"
run_guard --frobnicate
assert_eq "args/unknown-mode-refused" "1" "$STATUS" "$(evidence)"
assert_eq "args/unknown-mode-hot-untouched" "original hot content" "$(hot)" "$(evidence)"

# --- 16. not a vault => refuse, touch nothing ---------------------------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/not-a-vault"
NEW="$BOX/new-hot.md"
mkdir -p "$VAULT/src"
printf 'content\n' >"$NEW"
run_guard --pin
assert_eq "vault/non-vault-refused" "1" "$STATUS" "$(evidence)"
assert_contains "vault/non-vault-explains" "brain vault" "$(out_all)" "$(evidence)"

# --- 17. exactly one verdict line, on exactly one stream ----------------
# The contract is that a caller branches on the first line without parsing prose.
sb_new "original hot content"
run_guard --pin
printf 'changed\n' >"$VAULT/wiki/hot.md"
run_guard --write "$NEW"
assert_eq "contract/refusal-has-exactly-one-verdict-line" "1" \
  "$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^HOT-WRITE: ' || true)" "$(evidence)"
assert_eq "contract/refusal-stdout-carries-no-verdict" "0" \
  "$(grep -c '^HOT-WRITE: ' "$BOX/out.txt" 2>/dev/null || true)" "$(evidence)"

sb_new "original hot content"
run_guard --pin
run_guard --write "$NEW"
assert_eq "contract/success-has-exactly-one-verdict-line" "1" \
  "$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^HOT-WRITE: ' || true)" "$(evidence)"
assert_eq "contract/success-stderr-carries-no-verdict" "0" \
  "$(grep -c '^HOT-WRITE: ' "$BOX/err.txt" 2>/dev/null || true)" "$(evidence)"

# --- 18. the pin is machine-local state, under .brain/ ------------------
# It must never be committed: it describes an in-flight command in ONE checkout.
# The vault .gitignore template ignores .brain/ for exactly this reason.
sb_new "original hot content"
run_guard --pin
if [[ -f "$VAULT/.brain/hot.pin" ]]; then
  pass "pin/lives-under-dot-brain"
else
  fail "pin/lives-under-dot-brain" "expected the pin at .brain/hot.pin" \
    "found: [$(find "$VAULT" -name 'hot.pin' 2>/dev/null | tr '\n' ' ')]" "$(evidence)"
fi
assert_eq "pin/not-written-into-wiki" "0" \
  "$(find "$VAULT/wiki" -name '*.pin' 2>/dev/null | grep -c . || true)" "$(evidence)"

# --- 19. no half-written hot.md is ever visible ------------------------
# The install goes via a temp file in the destination directory + mv, so a
# concurrent reader sees either the old file or the new one, never a partial.
sb_new "original hot content"
run_guard --pin
run_guard --write "$NEW"
leftovers="$(find "$VAULT/wiki" -name '.hot.md.*' 2>/dev/null | grep -c . || true)"
assert_eq "write/no-temp-files-left-behind" "0" "$leftovers" "$(evidence)"

# ------------------------------------------------------------------ done ---
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
