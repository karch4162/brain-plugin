#!/usr/bin/env bash
# test-sync-graph.sh — deterministic quality gate for brain/bin/sync-graph.sh
#
# Covers the label-guard defect: the old has_named_labels() was an existence
# check, so an incoming report with 30 named / 410 generic community headings
# was treated as "named" and clobbered a fully-named 440-community mirror.
# The fix replaces it with a COUNT comparison via count_named_labels().
#
# Run:  bash tests/test-sync-graph.sh   (from anywhere)
# No network, no real vault, no node/python required (both are stubbed).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SYNC="$REPO_ROOT/brain/bin/sync-graph.sh"

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

assert_files_identical() { # name file_a file_b
  if cmp -s "$2" "$3"; then
    pass "$1"
  else
    fail "$1" "expected byte-identical files:" "  a: $2" "  b: $3" \
      "first difference: $(cmp "$2" "$3" 2>&1 | head -n 1)"
  fi
}

assert_files_differ() { # name file_a file_b
  if cmp -s "$2" "$3"; then
    fail "$1" "expected files to DIFFER but they are identical:" "  a: $2" "  b: $3"
  else
    pass "$1"
  fi
}

# Write a GRAPH_REPORT.md with $2 named + $3 generic community headings.
# $4 (optional) is the label prefix, so two reports can have the same named
# count but different names.
make_report() { # file named generic [prefix]
  local f="$1" n="$2" g="$3" prefix="${4:-Named Cluster}" i
  {
    printf '# Graph Report\n\n'
    printf 'Generated for testing.\n\n'
    printf '## Communities\n\n'
    for ((i = 1; i <= n; i++)); do
      printf '### Community %d - "%s %d"\n\n- member: src/file%d.ts\n\n' "$i" "$prefix" "$i" "$i"
    done
    for ((i = n + 1; i <= n + g; i++)); do
      printf '### Community %d - "Community %d"\n\n- member: src/file%d.ts\n\n' "$i" "$i" "$i"
    done
  } >"$f"
}

# ================================================================= PART A ===
# Unit tests for count_named_labels() extracted from sync-graph.sh.

echo "--- A. count_named_labels() unit tests ---"

UNIT_SRC="$TMPROOT/count_named_labels.sh"
sed -n '/^count_named_labels[[:space:]]*(/,/^}/p' "$SYNC" >"$UNIT_SRC" 2>/dev/null

if [[ ! -s "$UNIT_SRC" ]] || ! grep -q '^}' "$UNIT_SRC"; then
  for t in \
    "count_named_labels/missing-file" \
    "count_named_labels/empty-file" \
    "count_named_labels/generic-only" \
    "count_named_labels/3-named-5-generic" \
    "count_named_labels/output-is-single-integer-line"; do
    fail "$t" "could not extract a 'count_named_labels()' function definition from $SYNC" \
      "the function must be defined at column 0 and closed by a '}' at column 0"
  done
else
  # shellcheck disable=SC1090
  source "$UNIT_SRC"

  if ! declare -F count_named_labels >/dev/null 2>&1; then
    for t in \
      "count_named_labels/missing-file" \
      "count_named_labels/empty-file" \
      "count_named_labels/generic-only" \
      "count_named_labels/3-named-5-generic" \
      "count_named_labels/output-is-single-integer-line"; do
      fail "$t" "count_named_labels is not defined after sourcing the extracted body"
    done
  else
    UOUT="$TMPROOT/unit.out"
    UERR="$TMPROOT/unit.err"

    # 1. missing file => 0, exit status 0
    count_named_labels "$TMPROOT/definitely-does-not-exist.md" >"$UOUT" 2>"$UERR"
    st=$?
    got="$(cat "$UOUT")"
    if [[ "$got" == "0" && $st -eq 0 ]]; then
      pass "count_named_labels/missing-file"
    else
      fail "count_named_labels/missing-file" \
        "expected: stdout [0], exit [0]" \
        "actual:   stdout [$got], exit [$st]" \
        "stderr:   [$(cat "$UERR")]"
    fi

    # 2. empty file => 0
    : >"$TMPROOT/empty.md"
    got="$(count_named_labels "$TMPROOT/empty.md" 2>/dev/null)"
    assert_eq "count_named_labels/empty-file" "0" "$got"

    # 3. generic-only => 0
    make_report "$TMPROOT/generic.md" 0 6
    got="$(count_named_labels "$TMPROOT/generic.md" 2>/dev/null)"
    assert_eq "count_named_labels/generic-only" "0" "$got"

    # 4. 3 named + 5 generic => 3
    make_report "$TMPROOT/mixed.md" 3 5
    got="$(count_named_labels "$TMPROOT/mixed.md" 2>/dev/null)"
    assert_eq "count_named_labels/3-named-5-generic" "3" "$got"

    # 5. output is exactly one integer line, nothing else (incl. stderr)
    count_named_labels "$TMPROOT/mixed.md" >"$UOUT" 2>"$UERR"
    printf '3\n' >"$TMPROOT/unit.expected"
    if cmp -s "$UOUT" "$TMPROOT/unit.expected" && [[ ! -s "$UERR" ]]; then
      pass "count_named_labels/output-is-single-integer-line"
    else
      fail "count_named_labels/output-is-single-integer-line" \
        "expected stdout bytes: [3\\n], stderr: empty" \
        "actual stdout (od -c): $(od -c "$UOUT" | head -n 2 | tr '\n' ' ')" \
        "actual stderr: [$(cat "$UERR")]"
    fi
  fi
fi

# ================================================================= PART B ===
# Integration tests: run the real script end-to-end in a sandbox.

echo "--- B. sync-graph.sh integration tests ---"

# Stub node + python so nothing reaches the network or a real interpreter.
# Both are invoked with `|| warn` / `|| true` by the script, but stubbing keeps
# output deterministic. A stub can never fail a test.
STUBS="$TMPROOT/stubs"
mkdir -p "$STUBS"
for prog in node python python3; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$prog"
  chmod +x "$STUBS/$prog"
done

# Creates a fresh isolated sandbox and echoes its path. Runs inside a command
# substitution, so it must not rely on mutating shell state.
new_sandbox() {
  local box
  box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  local vault="$box/vault" repos="$box/repos" name="demorepo"
  mkdir -p "$vault/graphify/$name" "$vault/wiki" "$repos/$name/graphify-out"
  : >"$vault/wiki/log.md"
  # graph.json differs from any dst copy so the script never short-circuits
  # on the "up-to-date" cmp check.
  printf '{"nodes":[],"links":[]}\n' >"$repos/$name/graphify-out/graph.json"
  printf '{"repo":"demorepo"}\n' >"$repos/$name/graphify-out/manifest.json"
  echo "$box"
}

run_sync() { # box  -> stdout/stderr captured to $box/out.txt, $box/err.txt
  local box="$1"
  (
    PATH="$STUBS:$PATH"
    BRAIN_ROOT="$box/vault" \
      REPOS_DIR="$box/repos" \
      bash "$SYNC" --no-commit "$box/repos/demorepo"
  ) >"$box/out.txt" 2>"$box/err.txt"
  echo $?
}

DST_REL="vault/graphify/demorepo/demorepo-GRAPH_REPORT.md"
SRC_REL="repos/demorepo/graphify-out/GRAPH_REPORT.md"

# --- 1. REGRESSION: 440 named in dst, 30 named / 410 generic incoming ------
box="$(new_sandbox)"
make_report "$box/$DST_REL" 440 0 "Vault Label"
make_report "$box/$SRC_REL" 30 410 "Rebuild Label"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
assert_files_identical "integration/regression-440-named-not-clobbered-by-30-named" \
  "$box/dst.before" "$box/$DST_REL"
if grep -q '440' "$box/err.txt" && grep -qE '(^|[^0-9])30([^0-9]|$)' "$box/err.txt"; then
  pass "integration/regression-stderr-mentions-both-counts"
else
  fail "integration/regression-stderr-mentions-both-counts" \
    "expected stderr to mention both 440 and 30" \
    "exit: $status" \
    "stderr: [$(cat "$box/err.txt")]" \
    "stdout: [$(cat "$box/out.txt")]"
fi

# --- 2. dst all-generic (0 named), incoming 440 named => replaced ----------
box="$(new_sandbox)"
make_report "$box/$DST_REL" 0 440 "Vault Label"
make_report "$box/$SRC_REL" 440 0 "Rebuild Label"
cp "$box/$SRC_REL" "$box/src.before"
status="$(run_sync "$box")"
assert_files_identical "integration/generic-dst-replaced-by-named-incoming" \
  "$box/src.before" "$box/$DST_REL"

# --- 3. equal counts (5 named both sides, different names) => replaced -----
box="$(new_sandbox)"
make_report "$box/$DST_REL" 5 0 "Old Name"
make_report "$box/$SRC_REL" 5 0 "New Name"
cp "$box/$SRC_REL" "$box/src.before"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
assert_files_identical "integration/equal-count-relabel-is-allowed" \
  "$box/src.before" "$box/$DST_REL"
assert_files_differ "integration/equal-count-relabel-actually-changed-dst" \
  "$box/dst.before" "$box/$DST_REL"

# --- 4. no dst report at all, incoming exists => copied --------------------
box="$(new_sandbox)"
rm -f "$box/$DST_REL"
make_report "$box/$SRC_REL" 7 3 "Fresh Label"
cp "$box/$SRC_REL" "$box/src.before"
status="$(run_sync "$box")"
if [[ -f "$box/$DST_REL" ]]; then
  assert_files_identical "integration/missing-dst-report-gets-incoming" \
    "$box/src.before" "$box/$DST_REL"
else
  fail "integration/missing-dst-report-gets-incoming" \
    "expected $box/$DST_REL to exist after sync" \
    "exit: $status" "stderr: [$(cat "$box/err.txt")]"
fi

# --- 5. no incoming report, dst report exists => dst untouched -------------
box="$(new_sandbox)"
make_report "$box/$DST_REL" 12 0 "Vault Label"
rm -f "$box/$SRC_REL"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
if [[ -f "$box/$DST_REL" ]]; then
  assert_files_identical "integration/missing-incoming-report-leaves-dst-untouched" \
    "$box/dst.before" "$box/$DST_REL"
else
  fail "integration/missing-incoming-report-leaves-dst-untouched" \
    "dst report was deleted; expected it preserved at $box/$DST_REL" \
    "exit: $status" "stderr: [$(cat "$box/err.txt")]"
fi

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
