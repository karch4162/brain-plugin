#!/usr/bin/env bash
# test-freshness.sh — deterministic quality gate for brain/bin/freshness.mjs
# dead-wikilink resolution (INNOV-282).
#
# Contract under test:
#   The dead-[[wikilink]] check resolves community stubs by filename basename
#   AND by any `aliases:` frontmatter entry. build-community-notes.mjs
#   rename-protection keeps the OLD stub filename (_COMMUNITY_Community 44.md)
#   and records the new label in `aliases:` — a label-based
#   [[_COMMUNITY_<Label>]] link must NOT be reported dead.
#     - stub linked by alias label      → not dead
#     - stub linked by filename basename→ not dead
#     - genuinely missing target        → still dead (negative control)
#   Runs with BRAIN_ROOT resolution, cwd outside the vault, --stdout.
#
# Run:  bash tests/test-freshness.sh   (from anywhere; needs node)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
FRESH="$REPO_ROOT/brain/bin/freshness.mjs"

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
  for line in "$@"; do
    echo "     $line"
  done
}

if [[ ! -f "$FRESH" ]]; then
  for t in \
    "alias-link/not-dead" \
    "basename-link/not-dead" \
    "dead-link/still-reported" \
    "dead-count/exactly-one"; do
    fail "$t" "brain/bin/freshness.mjs does not exist at $FRESH"
  done
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

echo "--- freshness.mjs (dead wikilinks vs community stub aliases) ---"

# ------------------------------------------------------------------ fixture ---
# One vault, three wiki notes:
#   note-alias.md    → [[_COMMUNITY_Circuit Breaker Service]]  (alias of the stub)
#   note-basename.md → [[_COMMUNITY_Community 44]]             (stub's filename)
#   note-dead.md     → [[Totally Nonexistent Target]]          (negative control)
# The stub keeps its rename-protected OLD filename and carries the new label in
# list-form `aliases:` frontmatter — exactly what build-community-notes.mjs writes.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/graphify/demo-repo/communities"

printf 'See [[_COMMUNITY_Circuit Breaker Service]] for the cluster.\n' >"$VAULT/wiki/note-alias.md"
printf 'See [[_COMMUNITY_Community 44]] for the cluster.\n' >"$VAULT/wiki/note-basename.md"
printf 'See [[Totally Nonexistent Target]] for nothing.\n' >"$VAULT/wiki/note-dead.md"

# CRLF line endings on the stub: freshness.mjs must normalize \r\n before
# parsing frontmatter, matching real Windows-authored vaults.
printf -- '---\r\naliases:\r\n  - _COMMUNITY_Circuit Breaker Service\r\n---\r\n# Circuit Breaker Service\r\n' \
  >"$VAULT/graphify/demo-repo/communities/_COMMUNITY_Community 44.md"

# Run with cwd OUTSIDE the vault so BRAIN_ROOT resolution is what's proven.
(
  cd "$BOX" || exit 99
  BRAIN_ROOT="$VAULT" node "$FRESH" --stdout
) >"$BOX/out.txt" 2>"$BOX/err.txt"
status=$?

if [[ "$status" != "0" ]]; then
  fail "run/exit-0" \
    "expected exit 0" \
    "actual exit [$status]" \
    "stderr: [$(cat "$BOX/err.txt")]"
else
  pass "run/exit-0"
fi

# --- 1. label-based link to a rename-protected stub is NOT dead --------------
if grep -qF '`_COMMUNITY_Circuit Breaker Service`' "$BOX/out.txt"; then
  fail "alias-link/not-dead" \
    "label-based link to a rename-protected stub was reported dead" \
    "report: [$(grep -F '_COMMUNITY_' "$BOX/out.txt")]"
else
  pass "alias-link/not-dead"
fi

# --- 2. filename-basename link to the stub still resolves --------------------
if grep -qF '`_COMMUNITY_Community 44`' "$BOX/out.txt"; then
  fail "basename-link/not-dead" \
    "filename-basename link to the stub was reported dead" \
    "report: [$(grep -F '_COMMUNITY_' "$BOX/out.txt")]"
else
  pass "basename-link/not-dead"
fi

# --- 3. genuinely dead link is still reported (negative control) -------------
if grep -qF '`Totally Nonexistent Target`' "$BOX/out.txt"; then
  pass "dead-link/still-reported"
else
  fail "dead-link/still-reported" \
    "the genuinely dead link vanished from the report — check is broken, not fixed" \
    "report head: [$(head -n 20 "$BOX/out.txt")]"
fi

# --- 4. dead-link section counts exactly the one real ghost ------------------
if grep -qF 'Dead `[[wikilinks]]` (1)' "$BOX/out.txt"; then
  pass "dead-count/exactly-one"
else
  fail "dead-count/exactly-one" \
    "expected section header: Dead \`[[wikilinks]]\` (1)" \
    "actual: [$(grep -F 'Dead' "$BOX/out.txt")]"
fi

# --- 5. a git-ignored vault-local anchor is listed as unverifiable ----------
# (INNOV-304) `chats/` digests are gitignored: the anchor resolves only on the
# harvesting machine, so it must surface in the report, never pass as verified.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/chats/demo"
git init --quiet "$VAULT"
printf 'chats/\n' >"$VAULT/.gitignore"
printf 'digest\n' >"$VAULT/chats/demo/d1.md"
printf -- '---\nid: from-chat\nsource: chats/demo/d1.md\ntags: [x]\n---\n# From chat\n' >"$VAULT/wiki/from-chat.md"
(
  cd "$BOX" || exit 99
  BRAIN_ROOT="$VAULT" node "$FRESH" --stdout
) >"$BOX/out.txt" 2>"$BOX/err.txt"
if grep -qF 'Git-ignored vault file (1)' "$BOX/out.txt" && grep -qF 'chats/demo/d1.md' "$BOX/out.txt"; then
  pass "gitignored-anchor/reported"
else
  fail "gitignored-anchor/reported" \
    "expected a 'Git-ignored vault file (1)' bucket naming chats/demo/d1.md" \
    "report: [$(grep -iF -A3 'Unverifiable' "$BOX/out.txt")]" "stderr: [$(cat "$BOX/err.txt")]"
fi

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
