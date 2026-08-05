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

# ================================================================= PART C ===
# Defect 3 — no-args runs must only sync mirrors whose repo-side graph.json
#            actually DIFFERS from the vault copy, announcing the selection on
#            stderr as `selected N mirror(s): ...` (or `nothing to sync: ...`).
#            Explicit repo args bypass the filter entirely.
# Defect 4 — the auto-commit must be skipped when the vault's current branch
#            already has an open PR (detected via `gh`); --force-commit
#            overrides; a missing/erroring `gh` must NOT block the commit;
#            --no-commit still wins over --force-commit.

echo "--- C. mirror selection + open-PR commit guard ---"

# PATH used by run_sync_ex; reset to "" after any case that overrides it so a
# per-case `gh` stub can never leak into a later case.
SYNC_PATH=""

git_init_commit() { # dir message
  # core.autocrlf=false / core.eol=lf: a global autocrlf=true otherwise makes a
  # freshly created repo look dirty and the HEAD-sha assertions meaningless.
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

# Writes a fake `gh` into dir $1. $2 is the headRefName to report for an open
# PR; pass the empty string for "no open PRs". Any non-`pr` invocation is a
# silent success so a `gh --version` probe cannot skew a case.
make_gh_stub() { # dir head_ref_or_empty
  local dir="$1" ref="$2" body='[]'
  [[ -n "$ref" ]] && body="[{\"number\":4242,\"state\":\"OPEN\",\"isDraft\":false,\"headRefName\":\"$ref\",\"title\":\"open pr\",\"url\":\"https://example.invalid/pr/4242\"}]"
  mkdir -p "$dir"
  cat >"$dir/gh" <<GHSTUB
#!/usr/bin/env bash
# test stub — never touches the network
for a in "\$@"; do
  if [[ "\$a" == "pr" ]]; then
    cat <<'JSON'
$body
JSON
    exit 0
  fi
done
exit 0
GHSTUB
  chmod +x "$dir/gh"
}

# $PATH with every directory that contains a `gh` executable removed.
path_without_gh() {
  local out="" d
  local IFS=:
  for d in $PATH; do
    [[ -n "$d" ]] || continue
    [[ -e "$d/gh" || -e "$d/gh.exe" || -e "$d/gh.cmd" || -e "$d/gh.bat" ]] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# A `gh` that reports no open PRs, used as the default for the PART C cases so
# no case can reach the real gh (and therefore the network).
GH_NONE="$TMPROOT/gh-none"
make_gh_stub "$GH_NONE" ""

# Runs the real script with arbitrary args. stdout -> $1/out.txt,
# stderr -> $1/err.txt, combined -> $1/all.txt. Echoes the exit status.
run_sync_ex() { # box [args...]
  local box="$1"
  shift
  (
    PATH="${SYNC_PATH:-$GH_NONE:$STUBS:$PATH}"
    BRAIN_ROOT="$box/vault" \
      REPOS_DIR="$box/repos" \
      bash "$SYNC" "$@"
  ) >"$box/out.txt" 2>"$box/err.txt"
  local st=$?
  cat "$box/out.txt" "$box/err.txt" >"$box/all.txt" 2>/dev/null
  echo $st
}

# Creates a two-mirror sandbox and ASSIGNS the global MBOX (not a command
# substitution — the git repo setup has to be visible to the caller).
# alpha and beta both start byte-identical on both sides; a case makes one
# differ. Vault is a git repo on branch $MBRANCH.
MBRANCH="brain/sync-harness"
new_multi_sandbox() {
  MBOX="$(mktemp -d "$TMPROOT/mboxXXXXXX")"
  local v="$MBOX/vault" r="$MBOX/repos" name
  mkdir -p "$v/wiki"
  : >"$v/wiki/log.md"
  for name in alpha beta; do
    mkdir -p "$v/graphify/$name" "$r/$name/graphify-out"
    printf '{"nodes":["%s"],"links":[]}\n' "$name" >"$r/$name/graphify-out/graph.json"
    printf '{"repo":"%s"}\n' "$name" >"$r/$name/graphify-out/manifest.json"
    make_report "$r/$name/graphify-out/GRAPH_REPORT.md" 3 0 "Label $name"
    cp "$r/$name/graphify-out/graph.json" "$v/graphify/$name/graph.json"
    cp "$r/$name/graphify-out/manifest.json" "$v/graphify/$name/manifest.json"
    cp "$r/$name/graphify-out/GRAPH_REPORT.md" "$v/graphify/$name/$name-GRAPH_REPORT.md"
  done
  git_init_commit "$v" "initial vault"
  git -C "$v" checkout -q -b "$MBRANCH" >/dev/null 2>&1
}

snapshot_beta() { # box -> $box/beta.before.*
  cp "$1/vault/graphify/beta/graph.json" "$1/beta.before.graph"
  cp "$1/vault/graphify/beta/manifest.json" "$1/beta.before.manifest"
  cp "$1/vault/graphify/beta/beta-GRAPH_REPORT.md" "$1/beta.before.report"
  cp "$1/vault/wiki/log.md" "$1/log.before"
}

# --- 13. no-args: only the mirror that DIFFERS is synced -------------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
snapshot_beta "$MBOX"
status="$(run_sync_ex "$MBOX" --no-commit)"
assert_files_identical "selection/differing-mirror-alpha-synced" \
  "$MBOX/repos/alpha/graphify-out/graph.json" "$MBOX/vault/graphify/alpha/graph.json"
assert_files_identical "selection/unchanged-mirror-beta-graph-untouched" \
  "$MBOX/beta.before.graph" "$MBOX/vault/graphify/beta/graph.json"
assert_files_identical "selection/unchanged-mirror-beta-report-untouched" \
  "$MBOX/beta.before.report" "$MBOX/vault/graphify/beta/beta-GRAPH_REPORT.md"
if grep -qF 'selected 1 mirror(s)' "$MBOX/err.txt" && grep -qF 'alpha' "$MBOX/err.txt"; then
  pass "selection/stderr-announces-selected-mirror"
else
  fail "selection/stderr-announces-selected-mirror" \
    "expected stderr to contain 'selected 1 mirror(s)' naming alpha" \
    "exit: $status" \
    "stderr: [$(cat "$MBOX/err.txt")]" \
    "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 14. no-args, nothing differs => 'nothing to sync', exit 0, no writes --
new_multi_sandbox
snapshot_beta "$MBOX"
cp "$MBOX/vault/graphify/alpha/graph.json" "$MBOX/alpha.before.graph"
status="$(run_sync_ex "$MBOX" --no-commit)"
assert_eq "empty-selection/exit-0" "0" "$status"
if grep -qF 'nothing to sync' "$MBOX/all.txt"; then
  pass "empty-selection/says-nothing-to-sync"
else
  fail "empty-selection/says-nothing-to-sync" \
    "expected 'nothing to sync' in the run output" \
    "exit: $status" \
    "stderr: [$(cat "$MBOX/err.txt")]" \
    "stdout: [$(cat "$MBOX/out.txt")]"
fi
assert_files_identical "empty-selection/log-not-appended" \
  "$MBOX/log.before" "$MBOX/vault/wiki/log.md"
assert_files_identical "empty-selection/alpha-graph-untouched" \
  "$MBOX/alpha.before.graph" "$MBOX/vault/graphify/alpha/graph.json"
assert_files_identical "empty-selection/beta-graph-untouched" \
  "$MBOX/beta.before.graph" "$MBOX/vault/graphify/beta/graph.json"

# --- 15. explicit repo arg bypasses the filter ----------------------------
# beta does not differ; an explicit arg must still be PROCESSED, not filtered
# out. The script may legitimately report it 'up-to-date' — the assertion is
# only that the new no-args filter did not silently drop it.
new_multi_sandbox
status="$(run_sync_ex "$MBOX" --no-commit "$MBOX/repos/beta")"
if grep -qF 'beta' "$MBOX/all.txt" && ! grep -qF 'nothing to sync' "$MBOX/all.txt"; then
  pass "explicit-arg/bypasses-difference-filter"
else
  fail "explicit-arg/bypasses-difference-filter" \
    "explicit repo arg for a non-differing mirror was dropped by the no-args filter" \
    "expected beta to appear in the run output and NOT 'nothing to sync'" \
    "exit: $status" \
    "stdout: [$(cat "$MBOX/out.txt")]" \
    "stderr: [$(cat "$MBOX/err.txt")]"
fi
assert_eq "explicit-arg/exit-0" "0" "$status"

# --- 16. open PR on the current branch => auto-commit skipped -------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
GH_OPEN="$MBOX/gh-open"
make_gh_stub "$GH_OPEN" "$MBRANCH"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$GH_OPEN:$STUBS:$PATH"
status="$(run_sync_ex "$MBOX")"
SYNC_PATH=""
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "pr-guard/no-commit-when-branch-has-open-pr" "$head_before" "$head_after"
if grep -qF '4242' "$MBOX/err.txt"; then
  pass "pr-guard/stderr-mentions-pr-number"
else
  fail "pr-guard/stderr-mentions-pr-number" \
    "expected stderr to name the open PR (#4242)" \
    "exit: $status" \
    "stderr: [$(cat "$MBOX/err.txt")]" \
    "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 17. --force-commit overrides the open-PR guard -----------------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
GH_OPEN="$MBOX/gh-open"
make_gh_stub "$GH_OPEN" "$MBRANCH"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$GH_OPEN:$STUBS:$PATH"
status="$(run_sync_ex "$MBOX" --force-commit)"
SYNC_PATH=""
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
if [[ "$head_before" != "$head_after" ]]; then
  pass "pr-guard/force-commit-overrides"
else
  fail "pr-guard/force-commit-overrides" \
    "expected a new commit with --force-commit; HEAD did not move" \
    "head: $head_before" \
    "exit: $status" \
    "stderr: [$(cat "$MBOX/err.txt")]" \
    "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 18. gh missing from PATH => commit still happens ---------------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
NOGH="$(path_without_gh)"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$STUBS:$NOGH"
if PATH="$SYNC_PATH" command -v gh >/dev/null 2>&1; then
  SYNC_PATH=""
  fail "pr-guard/missing-gh-still-commits" \
    "could not build a gh-free PATH for this case (gh is still resolvable)"
else
  status="$(run_sync_ex "$MBOX")"
  SYNC_PATH=""
  head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
  if [[ "$head_before" != "$head_after" ]]; then
    pass "pr-guard/missing-gh-still-commits"
  else
    fail "pr-guard/missing-gh-still-commits" \
      "gh is only a safety net: with no gh on PATH the commit must still be made" \
      "head: $head_before" \
      "exit: $status" \
      "stderr: [$(cat "$MBOX/err.txt")]" \
      "stdout: [$(cat "$MBOX/out.txt")]"
  fi
fi

# --- 19. --no-commit wins over --force-commit -----------------------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX" --no-commit --force-commit)"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "flags/no-commit-beats-force-commit" "$head_before" "$head_after"

# ================================================================= PART D ===
# INNOV-270 ask 1 — never auto-commit onto a protected/default branch (a run
#            committed straight onto protected `main`; GitHub logged a bypassed
#            rule violation). Detection: origin/HEAD, then `gh repo view`, then
#            the literal names main/master as an always-on safety net.
#            --force-commit overrides; --no-commit still beats --force-commit.
# INNOV-270 ask 3 — pin HEAD (branch + sha) at start and re-check right before
#            committing; a HEAD that moved mid-run ABORTS the commit even with
#            --force-commit, because the caller's intent is then unknown.
# INNOV-269 — `--all` opts back into syncing every mirror, bypassing the
#            staleness filter; the bare run stays filtered.

echo "--- D. protected-branch guard, HEAD pin, --all ---"

# Puts the multi sandbox on branch $1 (creating it), leaving MBOX assigned.
new_multi_sandbox_on_branch() { # branch
  new_multi_sandbox
  git -C "$MBOX/vault" checkout -q -B "$1" >/dev/null 2>&1
}

make_alpha_stale() { # box
  printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$1/repos/alpha/graphify-out/graph.json"
}

staged_count() { # box
  git -C "$1/vault" diff --cached --name-only 2>/dev/null | grep -c . || true
}

subject_of_head() { # box
  git -C "$1/vault" log -1 --format=%s 2>/dev/null || true
}

# A `node` that moves the vault's HEAD while the sync is mid-flight — the
# concurrent-session case. sync-graph.sh invokes it as
# `BRAIN_ROOT=<vault> node build-community-notes.mjs <name>`, so the stub can
# find the vault from the environment. Never fails the run.
HEAD_MOVER="$TMPROOT/head-mover"
mkdir -p "$HEAD_MOVER"
cat >"$HEAD_MOVER/node" <<'MOVER'
#!/usr/bin/env bash
# test stub — simulates another session committing in the shared working tree
if [[ -n "${BRAIN_ROOT:-}" ]]; then
  git -C "$BRAIN_ROOT" commit -q --allow-empty -m "concurrent session commit" >/dev/null 2>&1 || true
fi
exit 0
MOVER
chmod +x "$HEAD_MOVER/node"

# --- 20. commit REFUSED on 'main' -----------------------------------------
new_multi_sandbox_on_branch main
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "protected/no-commit-on-main" "$head_before" "$head_after"
if grep -qF 'NOT COMMITTING' "$MBOX/err.txt" && grep -qF "main" "$MBOX/err.txt"; then
  pass "protected/main-stderr-names-branch"
else
  fail "protected/main-stderr-names-branch" \
    "expected a NOT COMMITTING message on stderr naming 'main'" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
if [[ "$(staged_count "$MBOX")" -gt 0 ]]; then
  pass "protected/main-leaves-sync-staged"
else
  fail "protected/main-leaves-sync-staged" \
    "expected the sync to be left STAGED (git diff --cached non-empty)" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
fi

# --- 21. commit REFUSED on 'master' ---------------------------------------
new_multi_sandbox_on_branch master
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "protected/no-commit-on-master" "$head_before" "$head_after"

# --- 22. commit REFUSED on the DETECTED origin/HEAD default branch ---------
# 'trunk' is not in the literal main/master net, so only origin/HEAD detection
# can catch it.
new_multi_sandbox_on_branch trunk
git -C "$MBOX/vault" update-ref refs/remotes/origin/trunk "$(git -C "$MBOX/vault" rev-parse HEAD)" >/dev/null 2>&1
git -C "$MBOX/vault" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk >/dev/null 2>&1
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "protected/no-commit-on-detected-origin-head-default" "$head_before" "$head_after"
if grep -qF 'trunk' "$MBOX/err.txt"; then
  pass "protected/detected-default-stderr-names-branch"
else
  fail "protected/detected-default-stderr-names-branch" \
    "expected stderr to name the detected default branch 'trunk'" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 23. commit ALLOWED on a normal feature branch ------------------------
# Same setup, branch that is neither main/master nor origin/HEAD: must commit.
new_multi_sandbox_on_branch "brain/feature-work"
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
if [[ "$head_before" != "$head_after" ]]; then
  pass "protected/feature-branch-still-commits"
else
  fail "protected/feature-branch-still-commits" \
    "a non-default branch must still auto-commit; HEAD did not move" \
    "head: $head_before" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
if [[ "$(subject_of_head "$MBOX")" == Sync\ graph\ mirror* ]]; then
  pass "head-pin/branch-unchanged-commits-normally"
else
  fail "head-pin/branch-unchanged-commits-normally" \
    "expected HEAD's subject to be the sync commit" \
    "actual subject: [$(subject_of_head "$MBOX")]" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
fi

# --- 24. --force-commit overrides the protected-branch refusal ------------
new_multi_sandbox_on_branch main
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX" --force-commit)"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
if [[ "$head_before" != "$head_after" ]]; then
  pass "protected/force-commit-overrides"
else
  fail "protected/force-commit-overrides" \
    "expected --force-commit to commit onto main anyway; HEAD did not move" \
    "head: $head_before" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 25. --no-commit still beats --force-commit on a protected branch -----
new_multi_sandbox_on_branch main
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX" --no-commit --force-commit)"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "flags/no-commit-beats-force-commit-on-protected" "$head_before" "$head_after"

# --- 26. HEAD moved mid-run => commit aborted -----------------------------
new_multi_sandbox_on_branch "brain/feature-work"
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$HEAD_MOVER:$GH_NONE:$STUBS:$PATH"
status="$(run_sync_ex "$MBOX")"
SYNC_PATH=""
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
if [[ "$(subject_of_head "$MBOX")" == "concurrent session commit" ]]; then
  pass "head-pin/moved-head-aborts-commit"
else
  fail "head-pin/moved-head-aborts-commit" \
    "the sync must NOT commit after HEAD moved mid-run" \
    "expected HEAD subject: [concurrent session commit]" \
    "actual HEAD subject:   [$(subject_of_head "$MBOX")]" \
    "sha before: $head_before  sha after: $head_after" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
if grep -qF "$head_before" "$MBOX/err.txt" && grep -qF "$head_after" "$MBOX/err.txt"; then
  pass "head-pin/stderr-reports-then-and-now-shas"
else
  fail "head-pin/stderr-reports-then-and-now-shas" \
    "expected stderr to print both the pinned sha and the current sha" \
    "then: $head_before" "now:  $head_after" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
fi
if [[ "$(staged_count "$MBOX")" -gt 0 ]]; then
  pass "head-pin/moved-head-leaves-sync-staged"
else
  fail "head-pin/moved-head-leaves-sync-staged" \
    "expected the sync to be left STAGED after the abort" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
fi

# --- 27. HEAD moved mid-run aborts EVEN WITH --force-commit ---------------
new_multi_sandbox_on_branch "brain/feature-work"
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$HEAD_MOVER:$GH_NONE:$STUBS:$PATH"
status="$(run_sync_ex "$MBOX" --force-commit)"
SYNC_PATH=""
if [[ "$(subject_of_head "$MBOX")" == "concurrent session commit" ]]; then
  pass "head-pin/force-commit-does-not-bypass"
else
  fail "head-pin/force-commit-does-not-bypass" \
    "--force-commit must NOT bypass the HEAD pin: intent is unknown once HEAD moved" \
    "expected HEAD subject: [concurrent session commit]" \
    "actual HEAD subject:   [$(subject_of_head "$MBOX")]" \
    "sha before: $head_before" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 28. --all selects NON-STALE mirrors too ------------------------------
new_multi_sandbox
status="$(run_sync_ex "$MBOX" --all --no-commit)"
if grep -qF 'selected 2 mirror(s)' "$MBOX/err.txt" \
  && grep -qF 'alpha' "$MBOX/err.txt" && grep -qF 'beta' "$MBOX/err.txt"; then
  pass "all-flag/selects-every-mirror"
else
  fail "all-flag/selects-every-mirror" \
    "expected 'selected 2 mirror(s)' naming alpha and beta with --all" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
if grep -qF 'nothing to sync' "$MBOX/all.txt"; then
  fail "all-flag/does-not-say-nothing-to-sync" \
    "--all must bypass the staleness filter, not report 'nothing to sync'" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
else
  pass "all-flag/does-not-say-nothing-to-sync"
fi
assert_eq "all-flag/exit-0" "0" "$status"

# --- 29. bare run still filters to stale only (with --all available) ------
new_multi_sandbox
make_alpha_stale "$MBOX"
snapshot_beta "$MBOX"
status="$(run_sync_ex "$MBOX" --no-commit)"
if grep -qF 'selected 1 mirror(s)' "$MBOX/err.txt" && ! grep -qF 'beta' "$MBOX/err.txt"; then
  pass "all-flag/bare-run-still-filters-to-stale"
else
  fail "all-flag/bare-run-still-filters-to-stale" \
    "a bare run must still select only the stale mirror (alpha), not beta" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
assert_files_identical "all-flag/bare-run-leaves-beta-untouched" \
  "$MBOX/beta.before.graph" "$MBOX/vault/graphify/beta/graph.json"

# --- 30. explicit args still bypass filtering (unaffected by --all) -------
new_multi_sandbox
make_alpha_stale "$MBOX"
snapshot_beta "$MBOX"
status="$(run_sync_ex "$MBOX" --no-commit "$MBOX/repos/beta")"
if grep -qF 'beta' "$MBOX/all.txt" && ! grep -qF 'selected' "$MBOX/err.txt"; then
  pass "explicit-arg/still-unfiltered-and-unselected"
else
  fail "explicit-arg/still-unfiltered-and-unselected" \
    "an explicit repo arg must be processed directly, with no selection step" \
    "exit: $status" "stdout: [$(cat "$MBOX/out.txt")]" "stderr: [$(cat "$MBOX/err.txt")]"
fi
# alpha IS stale but was not named, so it must be left alone — its vault copy
# still differs from the repo-side graph.
assert_files_differ "explicit-arg/stale-alpha-not-swept-in" \
  "$MBOX/repos/alpha/graphify-out/graph.json" "$MBOX/vault/graphify/alpha/graph.json"

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
