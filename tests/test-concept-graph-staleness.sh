#!/usr/bin/env bash
# test-concept-graph-staleness.sh — deterministic quality gate for
# brain/bin/check-concept-graph.sh (INNOV-286)
#
# /brain:save step 5c gated the wiki concept-graph refresh on notes changed THIS
# session only; staleness accumulated across prior sessions was invisible. A
# recorded incident: 2 session-changed notes, concept graph 517 documents behind,
# step reported green. The guard measures the TOTAL — wiki notes added/modified
# since the last commit that touched graphify-out/graph.json — from git, never
# from manifest.json (INNOV-271: it over-reports hundreds when ten changed).
#
# Contract under test:
#   exit 0 + first line "CONCEPT-GRAPH: OK - N document(s) ..."  (stdout) when
#            N <= threshold (default 25, CONCEPT_GRAPH_THRESHOLD overrides)
#   exit 1 + first line "CONCEPT-GRAPH: STALE - N document(s) behind" (stderr)
#            when N > threshold — WARN polarity, the caller relays but proceeds
#   exit 0 + "CONCEPT-GRAPH: SKIPPED - ..." when not measurable: no graph.json,
#            not a git repo, or graph.json never committed. Never a crash.
#   read-only; vault from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD
#
# Run:  bash tests/test-concept-graph-staleness.sh   (from anywhere)
# No network, no real vault, no node/python required.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
GUARD="$REPO_ROOT/brain/bin/check-concept-graph.sh"
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

first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

evidence() { # box
  local box="$1"
  echo "stdout: [$(tr '\n' '|' <"$box/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$box/err.txt" 2>/dev/null)]"
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

# Creates a fresh vault sandbox and ASSIGNS the globals BOX / VAULT.
# Deliberately NOT run in a command substitution — the assignments would be
# lost. Layout: wiki/ notes + graphify-out/graph.json, all committed together,
# i.e. a graph that is CURRENT at birth.
new_vault() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki" "$VAULT/graphify-out"
  printf '# one\n' >"$VAULT/wiki/one.md"
  printf '# two\n' >"$VAULT/wiki/two.md"
  printf '{"nodes":[]}\n' >"$VAULT/graphify-out/graph.json"
  git_init_commit "$VAULT" "initial vault + graph"
}

# add_notes <dir> <prefix> <n> — writes n new wiki notes named <prefix>-i.md
add_notes() { # dir prefix n
  local d="$1" prefix="$2" n="$3" i=1
  while [[ "$i" -le "$n" ]]; do
    printf '# %s %d\n' "$prefix" "$i" >"$d/wiki/$prefix-$i.md"
    i=$((i + 1))
  done
}

STATUS=""
# Runs a guard script against $VAULT with the CWD deliberately OUTSIDE the
# vault, so every run also proves $BRAIN_ROOT resolution. Streams captured in
# $BOX/out.txt / $BOX/err.txt, exit code in $STATUS.
run_guard() { # script [VAR=value...]
  local script="$1"
  shift
  (
    cd "$BOX" || exit 99
    unset CLAUDE_PROJECT_DIR
    unset CONCEPT_GRAPH_THRESHOLD
    env BRAIN_ROOT="$VAULT" "$@" bash "$script"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

if [[ ! -f "$GUARD" ]]; then
  echo "note: $GUARD does not exist yet — every case below is expected to FAIL until it lands."
fi

# ================================================================== CASES ===

# --- 1. THE INCIDENT SHAPE: 2 session notes, 32 stale total => STALE --------
# Prior sessions commit 30 notes AFTER the graph's last commit; this session
# adds 2 uncommitted notes. The session-only view sees 2 (green); the total is
# 32 (> 25) and must WARN, naming 32.
echo "--- 1. acceptance: accumulated staleness across sessions ---"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "prior sessions: 30 notes, graph never rebuilt"
add_notes "$VAULT" session 2
run_guard "$GUARD"
assert_eq "acceptance/exit-1" "1" "$STATUS" \
  "2 session notes must not hide 32 total stale documents" "$(evidence "$BOX")"
assert_prefix "acceptance/stderr-first-line-STALE" "CONCEPT-GRAPH: STALE" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
assert_contains "acceptance/names-N-32" "32 document(s) behind" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
assert_contains "acceptance/names-threshold" "25" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_eq "acceptance/nothing-on-stdout" "" "$(first_line "$BOX/out.txt")" \
  "the STALE verdict belongs on stderr" "$(evidence "$BOX")"

# --- 2. current graph => OK, exit 0, count reported --------------------------
echo "--- 2. current graph ---"
new_vault
run_guard "$GUARD"
assert_eq "current/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "current/stdout-first-line-OK" "CONCEPT-GRAPH: OK" \
  "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_contains "current/reports-zero" "0 document(s)" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 3. a few notes behind (<= threshold) => still OK, but N visible ---------
echo "--- 3. two notes behind, under threshold ---"
new_vault
add_notes "$VAULT" small 2
run_guard "$GUARD"
assert_eq "under-threshold/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "under-threshold/OK" "CONCEPT-GRAPH: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "under-threshold/reports-2" "2 document(s)" "$(first_line "$BOX/out.txt")" \
  "the number must be visible on the OK path too" "$(evidence "$BOX")"

# --- 4. no graphify-out/graph.json => SKIPPED, exit 0, no crash --------------
echo "--- 4. no graph.json ---"
new_vault
git -C "$VAULT" rm -q graphify-out/graph.json >/dev/null 2>&1
git_commit_all "$VAULT" "drop graph"
run_guard "$GUARD"
assert_eq "no-graph/exit-0" "0" "$STATUS" \
  "a vault with no wiki graph yet must not crash or warn" "$(evidence "$BOX")"
assert_prefix "no-graph/SKIPPED" "CONCEPT-GRAPH: SKIPPED" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "no-graph/names-the-file" "graph.json" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 5. graph.json exists but never committed => SKIPPED, says so ------------
echo "--- 5. graph.json never committed ---"
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf '# one\n' >"$VAULT/wiki/one.md"
git_init_commit "$VAULT" "notes only"
mkdir -p "$VAULT/graphify-out"
printf '{"nodes":[]}\n' >"$VAULT/graphify-out/graph.json"
run_guard "$GUARD"
assert_eq "never-committed/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "never-committed/SKIPPED" "CONCEPT-GRAPH: SKIPPED" \
  "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_contains "never-committed/says-never-committed" "never been committed" \
  "$(first_line "$BOX/out.txt")" \
  "the line must say it outright, not guess a staleness number" "$(evidence "$BOX")"

# --- 6. not a git repo => SKIPPED, exit 0 ------------------------------------
echo "--- 6. not a git repo ---"
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/graphify-out"
printf '{"nodes":[]}\n' >"$VAULT/graphify-out/graph.json"
run_guard "$GUARD"
assert_eq "no-git/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "no-git/SKIPPED" "CONCEPT-GRAPH: SKIPPED" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 7. threshold override tightens the gate ---------------------------------
echo "--- 7. CONCEPT_GRAPH_THRESHOLD=5 ---"
new_vault
add_notes "$VAULT" mid 6
git_commit_all "$VAULT" "six notes after graph"
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=5
assert_eq "custom-5/exit-1" "1" "$STATUS" \
  "the threshold must be able to tighten, not only loosen" "$(evidence "$BOX")"
assert_prefix "custom-5/STALE" "CONCEPT-GRAPH: STALE" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_contains "custom-5/names-6" "6 document(s) behind" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"

# --- 8. junk threshold falls back to 25 rather than disabling the gate -------
echo "--- 8. junk CONCEPT_GRAPH_THRESHOLD ---"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "30 notes after graph"
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=lots
assert_eq "junk-threshold/still-exit-1" "1" "$STATUS" \
  "a typo'd threshold must not silently disable the gate" "$(evidence "$BOX")"
assert_contains "junk-threshold/STALE-verdict-present" "CONCEPT-GRAPH: STALE" \
  "$(tr '\n' ' ' <"$BOX/err.txt" | tr -d '\r')" \
  "the stderr note about the junk value may precede the verdict" "$(evidence "$BOX")"
assert_contains "junk-threshold/falls-back-to-25" "threshold 25" \
  "$(tr '\n' ' ' <"$BOX/err.txt" | tr -d '\r')" "$(evidence "$BOX")"

# --- 9. rebuilt + recommitted graph resets the clock -------------------------
echo "--- 9. recommitting the graph resets staleness ---"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "30 notes"
printf '{"nodes":["rebuilt"]}\n' >"$VAULT/graphify-out/graph.json"
git_commit_all "$VAULT" "rebuild graph"
run_guard "$GUARD"
assert_eq "reset/exit-0" "0" "$STATUS" \
  "a graph committed after the notes is current again" "$(evidence "$BOX")"
assert_prefix "reset/OK" "CONCEPT-GRAPH: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "reset/reports-zero" "0 document(s)" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 10. read-only: the guard never mutates the vault ------------------------
echo "--- 10. read-only ---"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "30 notes"
status_before="$(git -C "$VAULT" status --porcelain | tr '\n' '|')"
head_before="$(git -C "$VAULT" rev-parse HEAD)"
run_guard "$GUARD"
assert_eq "read-only/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
assert_eq "read-only/worktree-unchanged" "$status_before" \
  "$(git -C "$VAULT" status --porcelain | tr '\n' '|')" "$(evidence "$BOX")"
assert_eq "read-only/HEAD-unchanged" "$head_before" "$(git -C "$VAULT" rev-parse HEAD)" \
  "$(evidence "$BOX")"

# --- 11. verdict discipline: exactly one CONCEPT-GRAPH line per run ----------
echo "--- 11. verdict discipline ---"
for shape in ok stale; do
  new_vault
  if [[ "$shape" == "stale" ]]; then
    add_notes "$VAULT" prior 30
    git_commit_all "$VAULT" "30 notes"
  fi
  run_guard "$GUARD"
  count="$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^CONCEPT-GRAPH:')"
  assert_eq "verdict/$shape/exactly-one-verdict-line" "1" "$count" "$(evidence "$BOX")"
done

# --- 12. NEGATIVE CONTROL: strip the total-staleness computation -------------
# A mutated guard whose --since is removed sees only the SESSION view — the
# exact INNOV-286 bug. Against the acceptance fixture it must flip STALE -> OK,
# proving case 1's assertion is what catches the regression (non-vacuous).
echo "--- 12. negative control ---"
MUTDIR="$TMPROOT/mutant-bin"
mkdir -p "$MUTDIR"
cp "$CWN" "$MUTDIR/changed-wiki-notes.sh"
sed 's/ --since "$LAST"//' "$GUARD" >"$MUTDIR/check-concept-graph.sh"
if grep -q -- '--since "$LAST"' "$MUTDIR/check-concept-graph.sh"; then
  fail "negative-control/mutation-applied" "sed failed to strip --since from the mutant"
else
  pass "negative-control/mutation-applied"
fi
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "prior sessions: 30 notes"
add_notes "$VAULT" session 2
run_guard "$MUTDIR/check-concept-graph.sh"
assert_eq "negative-control/session-only-view-goes-green" "0" "$STATUS" \
  "the mutant (session-only view) must report OK here — that flip is what proves" \
  "case 1 really tests the accumulated-staleness computation" "$(evidence "$BOX")"
assert_prefix "negative-control/mutant-reports-OK" "CONCEPT-GRAPH: OK" \
  "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
run_guard "$GUARD"
assert_eq "negative-control/real-guard-still-STALE-on-same-fixture" "1" "$STATUS" \
  "$(evidence "$BOX")"

# --- 13. missing sibling script => SKIPPED, never "OK - 0" -------------------
# A stale install can ship this guard without changed-wiki-notes.sh (doctor
# check 7's recorded incident). A broken measurement must not read as green.
echo "--- 13. missing changed-wiki-notes.sh ---"
LONEDIR="$TMPROOT/lone-bin"
mkdir -p "$LONEDIR"
cp "$GUARD" "$LONEDIR/check-concept-graph.sh"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "30 notes"
run_guard "$LONEDIR/check-concept-graph.sh"
assert_eq "missing-sibling/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "missing-sibling/SKIPPED-not-OK" "CONCEPT-GRAPH: SKIPPED" \
  "$(first_line "$BOX/out.txt")" \
  "a broken measurement must land on SKIPPED, never OK - 0" "$(evidence "$BOX")"
assert_contains "missing-sibling/names-the-sibling" "changed-wiki-notes.sh" \
  "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
