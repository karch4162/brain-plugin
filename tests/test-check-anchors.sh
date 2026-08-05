#!/usr/bin/env bash
# test-check-anchors.sh — deterministic quality gate for brain/bin/check-anchors.mjs
#
# /brain:promote turns a draft into a TRUSTED note, and the note's only claim to
# trust is its `source:` anchor. Nine notes were promoted with anchors that could
# not resolve on the promoting machine because "verify the anchor resolves" was
# prose in a skill file. check-anchors.mjs is the mechanical form of that rule,
# and this is its gate.
#
# Contract under test:
#   exit 0 => ANCHORS: OK          (stdout)  — every anchor verified
#   exit 1 => ANCHORS: BROKEN      (stderr)  — repo IS here, file is NOT (rot)
#   exit 2 => ANCHORS: UNVERIFIABLE(stderr)  — could not check here; advisory only
#   the first line ALWAYS carries all four counts (verified / broken /
#   unverifiable / no-source), on every path
#   unverifiable NEVER escalates to exit 1 — it is a conscious-choice prompt,
#   not a block
#   the script mutates nothing: no note edited, no file written, no repo touched
#
# Run:  bash tests/test-check-anchors.sh   (from anywhere)
# No network: the "remote" is a bogus URL that is never contacted; resolution is
# by git-config string match only. No real vault is touched. Every case gets its
# own fresh mktemp -d sandbox.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
CHECK="$REPO_ROOT/brain/bin/check-anchors.mjs"

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

assert_out_has() { # name substring [evidence...]
  local name="$1" pat="$2"
  shift 2
  if cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -qF -- "$pat"; then
    pass "$name"
  else
    fail "$name" "expected output to contain: [$pat]" "$@"
  fi
}

assert_out_lacks() { # name substring [evidence...]
  local name="$1" pat="$2"
  shift 2
  if cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -qF -- "$pat"; then
    fail "$name" "expected output NOT to contain: [$pat]" "$@"
  else
    pass "$name"
  fi
}

# First line of a file, with any trailing CR stripped (Git Bash / CRLF safety).
first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

evidence() {
  echo "stdout: [$(tr '\n' '|' <"$BOX/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$BOX/err.txt" 2>/dev/null)]"
}

# Node is a native Windows binary under Git Bash: MSYS rewrites path-shaped
# ARGUMENTS but env vars are less reliable, so convert explicitly.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

if ! command -v node >/dev/null 2>&1; then
  fail "harness/node-available" "node is required to run check-anchors.mjs but was not found on PATH"
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

if [[ ! -f "$CHECK" ]]; then
  echo "note: $CHECK does not exist yet — every case below is expected to FAIL until it lands."
fi

# ------------------------------------------------------------- sandboxing ---
#
# Layout per sandbox:
#   box/vault/wiki/_drafts/*.md      the notes under test
#   box/vault/graphify/demo/         mirror  => `demo` is CLAIMED by the vault
#   box/vault/graphify/ghost/        mirror  => `ghost` is CLAIMED but never cloned
#   box/vault/repos.json             identity: demo -> the bogus remote below
#   box/repos/demo/                  the only real checkout (git, one committed file)
#
# `ghost` deliberately has a mirror and NO checkout: that is the exact shape of
# the "unresolvable, not rot" case the whole three-state split exists for.
REMOTE="https://example.invalid/acme/demo.git"

BOX=""
VAULT=""
REPOS=""
sb_new() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  REPOS="$BOX/repos"

  mkdir -p "$VAULT/wiki/_drafts" "$VAULT/graphify/demo" "$VAULT/graphify/ghost" "$REPOS/demo/src"

  printf '{\n  "repos": {\n    "demo": { "remote": "%s" }\n  }\n}\n' "$REMOTE" >"$VAULT/repos.json"

  git init --quiet -b main "$REPOS/demo"
  git -C "$REPOS/demo" config user.email "anchors-test@example.invalid"
  git -C "$REPOS/demo" config user.name "Anchors Test"
  git -C "$REPOS/demo" config commit.gpgsign false
  git -C "$REPOS/demo" config core.autocrlf false
  git -C "$REPOS/demo" remote add origin "$REMOTE"
  printf 'console.log("a");\n' >"$REPOS/demo/src/a.js"
  git -C "$REPOS/demo" add -A
  git -C "$REPOS/demo" commit --quiet -m "seed"
}

# mknote <name> <source-line-or-empty> [extra frontmatter line]
mknote() {
  local name="$1" src="${2:-}" extra="${3:-}"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$name"
    printf 'last_verified: 2026-08-05\n'
    [[ -n "$src" ]] && printf 'source: %s\n' "$src"
    [[ -n "$extra" ]] && printf '%s\n' "$extra"
    printf -- '---\n\n# %s\n\nA fact.\n' "$name"
  } >"$VAULT/wiki/_drafts/$name.md"
}

STATUS=""
run_check() { # [args...]
  (
    unset CLAUDE_PROJECT_DIR
    BRAIN_ROOT="$(to_native "$VAULT")" REPOS_DIR="$(to_native "$REPOS")" \
      node "$(to_native "$CHECK")" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

# A content fingerprint of everything the script can see, excluding .git
# internals (git's own bookkeeping is not this script's doing).
snapshot() { # outfile
  (
    cd "$BOX" || exit 0
    find . -type f -not -path '*/.git/*' 2>/dev/null | sort | xargs cksum 2>/dev/null
  ) >"$1"
}

# ================================================================== CASES ===

# --- 1. verified anchor => exit 0, OK, counts on the CLEAN path -----------
echo "--- 1. verified anchor ---"
sb_new
mknote good "demo/src/a.js"
run_check
assert_eq "verified/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "verified/stdout-first-line-OK" "ANCHORS: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_out_has "verified/counts-on-clean-path" "1 verified, 0 broken, 0 unverifiable" "$(evidence)"
assert_out_has "verified/note-count-on-clean-path" "1 note(s), 1 anchor(s)" "$(evidence)"

# --- 2. broken anchor: repo resolves, file missing => exit 1 --------------
echo "--- 2. broken anchor ---"
sb_new
mknote gone "demo/src/gone.js"
run_check
assert_eq "broken/exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "broken/stderr-first-line-BROKEN" "ANCHORS: BROKEN" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_out_has "broken/counts-on-dirty-path" "0 verified, 1 broken, 0 unverifiable" "$(evidence)"
assert_out_has "broken/names-the-note" "wiki/_drafts/gone.md" "$(evidence)"
assert_out_has "broken/names-the-anchor" "demo/src/gone.js" "$(evidence)"

# --- 3. unresolvable: repo CLAIMED by the vault, never checked out => exit 2
echo "--- 3. unresolvable (no checkout) ---"
sb_new
mknote hub "ghost/docs/design.md"
run_check
assert_eq "no-checkout/exit-2-not-1" "2" "$STATUS" \
  "an anchor we merely could not check must never hard-block promotion" "$(evidence)"
assert_prefix "no-checkout/stderr-first-line-UNVERIFIABLE" "ANCHORS: UNVERIFIABLE" \
  "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_out_has "no-checkout/counts" "0 verified, 0 broken, 1 unverifiable" "$(evidence)"
assert_out_has "no-checkout/names-the-note" "wiki/_drafts/hub.md" "$(evidence)"
assert_out_has "no-checkout/names-the-repo-needed" "repo(s) needed: ghost" "$(evidence)"
assert_out_lacks "no-checkout/never-called-rot" "BROKEN" "$(evidence)"

# --- 4. unknown repo prefix (no mirror, no repos.json entry) => exit 2 ----
echo "--- 4. unknown repo prefix ---"
sb_new
mknote stranger "nowhere/docs/x.md"
run_check
assert_eq "unknown-prefix/exit-2" "2" "$STATUS" "$(evidence)"
assert_prefix "unknown-prefix/stderr-first-line-UNVERIFIABLE" "ANCHORS: UNVERIFIABLE" \
  "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_out_has "unknown-prefix/counts" "0 verified, 0 broken, 1 unverifiable" "$(evidence)"
assert_out_has "unknown-prefix/says-unknown" "unknown" "$(evidence)"
assert_out_has "unknown-prefix/names-the-note" "wiki/_drafts/stranger.md" "$(evidence)"

# --- 5. pinned revision not available locally => exit 2, NOT broken -------
echo "--- 5. pinned rev not fetched ---"
sb_new
mknote pinned "demo/src/a.js@0123456789abcdef0123456789abcdef01234567"
run_check
assert_eq "unfetched-rev/exit-2-not-1" "2" "$STATUS" \
  "'I don't have that commit' must never be reported as 'that file is missing'" "$(evidence)"
assert_out_has "unfetched-rev/counts" "0 verified, 0 broken, 1 unverifiable" "$(evidence)"
assert_out_has "unfetched-rev/says-rev" "rev" "$(evidence)"

# --- 5b. pinned revision that IS present => verified ----------------------
echo "--- 5b. pinned rev present ---"
sb_new
HEADSHA="$(git -C "$REPOS/demo" rev-parse HEAD)"
mknote pinnedok "demo/src/a.js@$HEADSHA"
run_check
assert_eq "fetched-rev/exit-0" "0" "$STATUS" "$(evidence)"
assert_out_has "fetched-rev/counts" "1 verified, 0 broken, 0 unverifiable" "$(evidence)"

# --- 6. a note with no source: at all => exit 2, reported, not "verified" -
echo "--- 6. no source: anchor ---"
sb_new
mknote anchorless ""
run_check
assert_eq "no-source/exit-2" "2" "$STATUS" "$(evidence)"
assert_out_has "no-source/counts" "0 verified, 0 broken, 0 unverifiable, 1 note(s) with no source:" "$(evidence)"
assert_out_has "no-source/names-the-note" "wiki/_drafts/anchorless.md" "$(evidence)"

# --- 6b. source_untracked: true is a documented absence, not a finding ----
echo "--- 6b. source_untracked ---"
sb_new
mknote scratch "demo/scratch/local-only.env" "source_untracked: true"
run_check
assert_eq "untracked/exit-0" "0" "$STATUS" \
  "a note that DECLARES its source is not in git must not be flagged for it" "$(evidence)"
assert_out_has "untracked/counted-separately" "declared source_untracked" "$(evidence)"

# --- 7. multiple notes mixing every state => BROKEN wins, counts are exact -
echo "--- 7. mixed batch ---"
sb_new
mknote m-good "demo/src/a.js"
mknote m-gone "demo/src/gone.js"
mknote m-hub "ghost/docs/design.md"
mknote m-stranger "nowhere/docs/x.md"
mknote m-pinned "demo/src/a.js@0123456789abcdef0123456789abcdef01234567"
mknote m-none ""
run_check
assert_eq "mixed/exit-1-broken-wins" "1" "$STATUS" "$(evidence)"
assert_prefix "mixed/stderr-first-line-BROKEN" "ANCHORS: BROKEN" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_out_has "mixed/all-four-counts" \
  "6 note(s), 5 anchor(s): 1 verified, 1 broken, 3 unverifiable, 1 note(s) with no source:" "$(evidence)"
assert_out_has "mixed/still-names-unverifiable-notes" "wiki/_drafts/m-hub.md" "$(evidence)"
assert_out_has "mixed/still-names-the-broken-note" "wiki/_drafts/m-gone.md" "$(evidence)"
assert_out_has "mixed/still-names-the-anchorless-note" "wiki/_drafts/m-none.md" "$(evidence)"

# --- 8. explicit note paths + a directory both work -----------------------
echo "--- 8. explicit paths ---"
sb_new
mknote p-good "demo/src/a.js"
mknote p-gone "demo/src/gone.js"
run_check "wiki/_drafts/p-good.md"
assert_eq "explicit-path/only-named-note-checked/exit-0" "0" "$STATUS" "$(evidence)"
assert_out_has "explicit-path/only-named-note-checked/counts" "1 note(s), 1 anchor(s)" "$(evidence)"
assert_out_lacks "explicit-path/other-note-untouched" "p-gone" "$(evidence)"
run_check "wiki/_drafts"
assert_eq "explicit-dir/exit-1" "1" "$STATUS" "$(evidence)"
assert_out_has "explicit-dir/both-notes-counted" "2 note(s), 2 anchor(s)" "$(evidence)"

# --- 9. missing preconditions never fail ---------------------------------
echo "--- 9. nothing to check ---"
sb_new
rm -rf "$VAULT/wiki/_drafts"
run_check
assert_eq "empty/exit-0" "0" "$STATUS" \
  "a vault with no drafts is not a failure" "$(evidence)"
assert_prefix "empty/stdout-first-line-OK" "ANCHORS: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_out_has "empty/counts-still-printed" "0 verified, 0 broken, 0 unverifiable" "$(evidence)"

# --- 10. the script mutates NOTHING, on every verdict path ---------------
echo "--- 10. never mutates ---"
for scenario in clean broken unverifiable; do
  sb_new
  case "$scenario" in
    clean)        mknote x "demo/src/a.js" ;;
    broken)       mknote x "demo/src/gone.js" ;;
    unverifiable) mknote x "ghost/docs/design.md" ;;
  esac
  snapshot "$BOX/before.txt"
  run_check
  snapshot "$BOX/after.txt"
  # The captured out/err files live in $BOX and are written between snapshots,
  # so compare only the vault + repos subtrees.
  grep -E '\./(vault|repos)/' "$BOX/before.txt" >"$BOX/before.f" 2>/dev/null
  grep -E '\./(vault|repos)/' "$BOX/after.txt" >"$BOX/after.f" 2>/dev/null
  if cmp -s "$BOX/before.f" "$BOX/after.f"; then
    pass "no-mutation/$scenario/vault-and-repos-byte-identical"
  else
    fail "no-mutation/$scenario/vault-and-repos-byte-identical" \
      "the script changed something under vault/ or repos/" \
      "diff: [$(diff "$BOX/before.f" "$BOX/after.f" 2>/dev/null | head -n 6 | tr '\n' '|')]" \
      "$(evidence)"
  fi
  if [[ -e "$VAULT/repos.local.json" ]]; then
    fail "no-mutation/$scenario/no-repos-local-json-written" \
      "the script wrote $VAULT/repos.local.json — resolution here must be read-only" "$(evidence)"
  else
    pass "no-mutation/$scenario/no-repos-local-json-written"
  fi
done

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
