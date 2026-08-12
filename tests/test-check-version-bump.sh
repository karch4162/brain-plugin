#!/usr/bin/env bash
# test-check-version-bump.sh — tools/check-version-bump.sh gates plugin bumps.
#
# The CI version-bump job fails a PR that touches brain/ without bumping the
# "version" field of brain/.claude-plugin/plugin.json. This suite pins the
# script's contract against scratch git repos: brain/ change without a bump
# fails and names the file to edit; a bump, or a change outside brain/, passes.
# The base ref may be a plain local branch name (test 4) — CI passes
# origin/<base>, but nothing in the script may assume the origin/ prefix.
#
# Run:  bash tests/test-check-version-bump.sh   (from anywhere)
# No network. Requires a real `node` on PATH (the script uses it to parse JSON).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
CHECK="$REPO_ROOT/tools/check-version-bump.sh"

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
  local l
  for l in "$@"; do echo "     $l"; done
}
assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi
}
assert_contains() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: [$3]" "actual: [$2]"; fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: no node on PATH — the script under test parses JSON with node." >&2
  exit 0
fi

# A scratch repo: main holds plugin.json at version 0.0.1, work branches off it.
new_sandbox() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  git -C "$BOX" init -q -b main
  git -C "$BOX" config user.email t@t.t
  git -C "$BOX" config user.name t
  git -C "$BOX" config core.autocrlf false
  mkdir -p "$BOX/brain/.claude-plugin"
  printf '{"name":"brain","version":"0.0.1"}\n' >"$BOX/brain/.claude-plugin/plugin.json"
  printf 'base\n' >"$BOX/README.md"
  git -C "$BOX" add -A
  git -C "$BOX" commit -q -m "initial"
  git -C "$BOX" checkout -q -b work
}

commit_all() { # msg
  git -C "$BOX" add -A
  git -C "$BOX" commit -q -m "$1"
}

run_check() { # base-ref
  (cd "$BOX" && bash "$CHECK" "$1") >"$BOX/out.txt" 2>&1
  echo $?
}

echo "--- 1. brain/ change without a bump fails and names the file ---"
new_sandbox
printf 'changed\n' >"$BOX/brain/somefile.md"
commit_all "brain change, no bump"
st="$(run_check main)"
assert_eq "no-bump/exit-1" "1" "$st"
assert_contains "no-bump/names-plugin-json" "$(cat "$BOX/out.txt")" "brain/.claude-plugin/plugin.json"

echo "--- 2. brain/ change WITH a bump passes ---"
new_sandbox
printf 'changed\n' >"$BOX/brain/somefile.md"
printf '{"name":"brain","version":"0.0.2"}\n' >"$BOX/brain/.claude-plugin/plugin.json"
commit_all "brain change with bump"
st="$(run_check main)"
assert_eq "bump/exit-0" "0" "$st"
assert_contains "bump/reports-versions" "$(cat "$BOX/out.txt")" "0.0.1 -> 0.0.2"

echo "--- 3. change outside brain/ needs no bump ---"
new_sandbox
mkdir -p "$BOX/.github/workflows" "$BOX/tools"
printf 'name: CI\n' >"$BOX/.github/workflows/ci.yml"
printf '#!/usr/bin/env bash\n' >"$BOX/tools/helper.sh"
commit_all "ci-only change"
st="$(run_check main)"
assert_eq "outside-brain/exit-0" "0" "$st"

echo "--- 4. base ref as a plain local branch name ---"
# Already exercised above (main is local), but pin it explicitly against a
# non-default branch name so the script provably takes any ref, not origin/*.
new_sandbox
git -C "$BOX" branch -q base-snapshot main
printf 'changed\n' >"$BOX/brain/somefile.md"
commit_all "brain change, no bump"
st="$(run_check base-snapshot)"
assert_eq "local-branch-base/exit-1" "1" "$st"
assert_contains "local-branch-base/names-plugin-json" "$(cat "$BOX/out.txt")" "brain/.claude-plugin/plugin.json"

echo "--- 5. no changes at all is fine ---"
new_sandbox
st="$(run_check main)"
assert_eq "no-changes/exit-0" "0" "$st"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
