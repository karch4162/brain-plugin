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

echo "--- 6. every plugin dir is gated, not just brain/ ---"
# A marketplace can carry several plugins; each has its own version and its own
# frozen-cache risk if it ships without a bump.
new_sandbox
mkdir -p "$BOX/wave/.claude-plugin"
printf '{"name":"wave","version":"0.1.0"}\n' >"$BOX/wave/.claude-plugin/plugin.json"
git -C "$BOX" add -A && git -C "$BOX" commit -q -m "add wave" && git -C "$BOX" branch -q -f wave-base
printf 'changed\n' >"$BOX/wave/SKILL.md"
commit_all "wave change, no bump"
st="$(run_check wave-base)"
assert_eq "wave-no-bump/exit-1" "1" "$st"
assert_contains "wave-no-bump/names-plugin-json" "$(cat "$BOX/out.txt")" "wave/.claude-plugin/plugin.json"
printf '{"name":"wave","version":"0.1.1"}\n' >"$BOX/wave/.claude-plugin/plugin.json"
commit_all "wave bump"
st="$(run_check wave-base)"
assert_eq "wave-bump/exit-0" "0" "$st"

echo "--- 7. a brand-new plugin needs no bump ---"
new_sandbox
mkdir -p "$BOX/wave/.claude-plugin"
printf '{"name":"wave","version":"0.1.0"}\n' >"$BOX/wave/.claude-plugin/plugin.json"
commit_all "add wave"
st="$(run_check main)"
assert_eq "new-plugin/exit-0" "0" "$st"

echo "--- 8. brain/ change + an added bump fragment passes (INNOV-311) ---"
# Branches declare THAT they bump (.bumps/<dir>/<name>); the release step picks
# the number. The version literal is untouched, so parallel branches can't collide.
new_sandbox
printf 'changed\n' >"$BOX/brain/somefile.md"
mkdir -p "$BOX/.bumps/brain"
printf 'patch\r\n' >"$BOX/.bumps/brain/INNOV-1"   # CRLF: the check keys on the path, not content
commit_all "brain change with fragment"
st="$(run_check main)"
assert_eq "fragment/exit-0" "0" "$st"
assert_contains "fragment/reports-declared" "$(cat "$BOX/out.txt")" ".bumps/brain/"

echo "--- 9. a fragment for ANOTHER plugin does not cover brain/ ---"
new_sandbox
printf 'changed\n' >"$BOX/brain/somefile.md"
mkdir -p "$BOX/.bumps/wave"
printf 'patch\n' >"$BOX/.bumps/wave/INNOV-1"
commit_all "brain change, wave fragment"
st="$(run_check main)"
assert_eq "wrong-dir-fragment/exit-1" "1" "$st"
assert_contains "wrong-dir-fragment/names-fragment-option" "$(cat "$BOX/out.txt")" ".bumps/brain/"

echo "--- 10. DELETING a fragment is not a bump declaration ---"
new_sandbox
mkdir -p "$BOX/.bumps/brain"
printf 'patch\n' >"$BOX/.bumps/brain/OLD"
git -C "$BOX" add -A && git -C "$BOX" commit -q -m "pending fragment" && git -C "$BOX" branch -q -f frag-base
rm "$BOX/.bumps/brain/OLD"
printf 'changed\n' >"$BOX/brain/somefile.md"
commit_all "brain change, fragment deleted, no bump"
st="$(run_check frag-base)"
assert_eq "deleted-fragment/exit-1" "1" "$st"

echo "--- 10b. deleting a pending fragment WITHOUT touching brain/ still fails ---"
# Otherwise a stray cleanup PR drops an owed bump and brain/ changes ship frozen.
new_sandbox
mkdir -p "$BOX/.bumps/brain"
printf 'patch\n' >"$BOX/.bumps/brain/OLD"
git -C "$BOX" add -A && git -C "$BOX" commit -q -m "pending fragment" && git -C "$BOX" branch -q -f frag-base
rm "$BOX/.bumps/brain/OLD"
commit_all "drop fragment only"
st="$(run_check frag-base)"
assert_eq "fragment-only-delete/exit-1" "1" "$st"

echo "--- 10c. a nested path under .bumps/brain/ is not a fragment ---"
# bump-version.mjs reads direct children only; a nested file would pass CI and
# then crash the release.
new_sandbox
printf 'changed\n' >"$BOX/brain/somefile.md"
mkdir -p "$BOX/.bumps/brain/INNOV-1"
printf 'patch\n' >"$BOX/.bumps/brain/INNOV-1/x"
commit_all "brain change, nested fragment"
st="$(run_check main)"
assert_eq "nested-fragment/exit-1" "1" "$st"

echo "--- 11. two branches cut from one commit merge cleanly in either order ---"
# The ticket's acceptance #1, literally. A version-literal bump on both branches
# conflicts here; distinct fragment files cannot.
for order in "a b" "b a"; do
  new_sandbox
  git -C "$BOX" checkout -q main
  for br in a b; do
    git -C "$BOX" checkout -q -b "br-$br" main
    mkdir -p "$BOX/.bumps/brain"
    printf 'change %s\n' "$br" >"$BOX/brain/file-$br.md"
    printf 'patch\n' >"$BOX/.bumps/brain/INNOV-$br"
    commit_all "branch $br"
    git -C "$BOX" checkout -q main
  done
  st=0
  for br in $order; do
    git -C "$BOX" merge -q --no-edit "br-$br" >/dev/null 2>&1 || st=1
  done
  assert_eq "parallel-merge[$order]/clean" "0" "$st"
done

echo "--- 12. bump-version.mjs: fragments -> one version bump, manifests regenerated ---"
new_sandbox
mkdir -p "$BOX/tools" "$BOX/.bumps/brain"
cp "$REPO_ROOT/tools/bump-version.mjs" "$REPO_ROOT/tools/generate-host-manifests.mjs" "$BOX/tools/"
printf '{"name":"brain","version":"0.3.8","author":{"name":"t"}}\n' >"$BOX/brain/.claude-plugin/plugin.json"
printf 'patch\n' >"$BOX/.bumps/brain/INNOV-a"
printf 'minor\r\n' >"$BOX/.bumps/brain/INNOV-b"
(cd "$BOX" && node tools/bump-version.mjs brain) >"$BOX/out.txt" 2>&1
assert_eq "bump/exit-0" "0" "$?"
v="$(node -p 'require(process.argv[1]).version' "$BOX/brain/.claude-plugin/plugin.json")"
assert_eq "bump/highest-kind-wins" "0.4.0" "$v"
assert_eq "bump/fragments-consumed" "" "$(ls "$BOX/.bumps/brain" 2>/dev/null)"
(cd "$BOX" && node tools/generate-host-manifests.mjs --check) >/dev/null 2>&1
assert_eq "bump/host-manifests-in-sync" "0" "$?"
v="$(node -p 'require(process.argv[1]).version' "$BOX/brain/.codex-plugin/plugin.json")"
assert_eq "bump/codex-manifest-follows" "0.4.0" "$v"

echo "--- 13. bump-version.mjs with no fragments changes nothing and fails ---"
new_sandbox
mkdir -p "$BOX/tools"
cp "$REPO_ROOT/tools/bump-version.mjs" "$REPO_ROOT/tools/generate-host-manifests.mjs" "$BOX/tools/"
(cd "$BOX" && node tools/bump-version.mjs brain) >"$BOX/out.txt" 2>&1
assert_eq "bump-none/exit-1" "1" "$?"
v="$(node -p 'require(process.argv[1]).version' "$BOX/brain/.claude-plugin/plugin.json")"
assert_eq "bump-none/version-unchanged" "0.0.1" "$v"

echo "--- 14. bump-version.mjs: empty fragment is a patch; wave has no host manifests ---"
new_sandbox
mkdir -p "$BOX/tools" "$BOX/wave/.claude-plugin" "$BOX/.bumps/wave"
cp "$REPO_ROOT/tools/bump-version.mjs" "$REPO_ROOT/tools/generate-host-manifests.mjs" "$BOX/tools/"
printf '{"name":"wave","version":"0.1.1"}\n' >"$BOX/wave/.claude-plugin/plugin.json"
: >"$BOX/.bumps/wave/INNOV-c"
(cd "$BOX" && node tools/bump-version.mjs wave) >"$BOX/out.txt" 2>&1
assert_eq "bump-wave/exit-0" "0" "$?"
v="$(node -p 'require(process.argv[1]).version' "$BOX/wave/.claude-plugin/plugin.json")"
assert_eq "bump-wave/patch" "0.1.2" "$v"
assert_eq "bump-wave/no-brain-manifests-written" "no" "$([ -e "$BOX/brain/plugin.json" ] && echo yes || echo no)"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
