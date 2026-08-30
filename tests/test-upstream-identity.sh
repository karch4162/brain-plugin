#!/usr/bin/env bash
# test-upstream-identity.sh — UPSTREAM-ONLY. This repo's shipped identity must
# stay the personal one: marketplace `brain-marketplace`, plugin `brain`.
#
# WHY THIS EXISTS. This repo and the Tray fork are the same plugin under two
# identities, and the fork rebrands the marketplace + plugin names. The sync is
# one-way — fixes are cherry-picked from here ONTO the fork — so the rebrand is
# not supposed to travel back. But nothing structural stops a fork branch from
# being pushed or PR'd here by mistake, and if the shipped identity flips, every
# user whose settings name the personal marketplace loses the plugin: the
# marketplace fails to register, and the enabled plugin key resolves to nothing.
# That failure surfaces as "marketplace not found" and reads like a broken
# install, not a rename.
#
# A text scan for the fork's strings does NOT work here. Words like the fork's
# vault and repo names appear legitimately across this repo's docs, comments,
# and tools/compare-publications.sh — whose entire job is to translate between
# the two brandings. Grepping for them flags correct text, and a gate that cries
# wolf gets ignored. So this asserts the two identity FILES positively instead.
#
# Run:  bash tests/test-upstream-identity.sh   (from anywhere)
# No network, no vault. Needs node (CI provides it; check-version-bump.sh
# already depends on it).
#
# DO NOT PORT THIS FILE TO THE FORK. There the fork's identity is the CORRECT
# one, so this gate fails on every line by design — it is the mirror image of
# the fork's own branding gate, and the two must never both be present.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

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

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL upstream-identity/prereq"
  echo "     node is required to parse the identity files"
  exit 1
fi

# The shipped identity, as one field-ordered line. Asserting the parsed VALUES
# rather than grepping the file text keeps a reformat (indentation, key order)
# from turning into a false failure.
#   marketplace.name | plugin count | plugins[0].name | plugins[0].source | plugin.json name
EXPECTED='brain-marketplace|1|brain|./brain|brain'

# identity_of <marketplace.json> <plugin.json> — the one function both the gate
# and the negative controls go through. Returns 1 if either file fails to parse.
#
# Each file is piped in on STDIN rather than passed as a path. On Windows the
# repo's node is a native binary that cannot open an MSYS-style path, and
# whether the shell rewrites one for it depends on MSYS_NO_PATHCONV — so a path
# argument makes this suite pass or fail on an ambient env var. Reading fd 0 is
# what tools/check-version-bump.sh already does, for the same reason.
marketplace_identity() { # stdin = marketplace.json
  node -e '
    const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const pl = d.plugins || [];
    const first = pl[0] || {};
    process.stdout.write([d.name, pl.length, first.name, first.source].join("|"));
  ' 2>/dev/null
}

plugin_identity() { # stdin = plugin.json
  node -e '
    const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
    process.stdout.write(String(d.name));
  ' 2>/dev/null
}

identity_of() {
  local mkt plug
  mkt="$(marketplace_identity <"$1")" || return 1
  plug="$(plugin_identity <"$2")" || return 1
  [ -n "$mkt" ] && [ -n "$plug" ] || return 1
  printf '%s|%s' "$mkt" "$plug"
}

# --- negative controls --------------------------------------------------------
# 1. Fork-branded identity files must be DETECTED. Without this the gate below
#    proves nothing once the expectation rots.
printf '{"name":"tray-brain-marketplace","plugins":[{"name":"tray-brain","source":"./brain"}]}\n' \
  >"$TMPROOT/fork-marketplace.json"
printf '{"name":"tray-brain","version":"9.9.9"}\n' >"$TMPROOT/fork-plugin.json"
fork_identity="$(identity_of "$TMPROOT/fork-marketplace.json" "$TMPROOT/fork-plugin.json")"
if [ "$fork_identity" = "$EXPECTED" ]; then
  fail "negative-control/fork-identity-detected" \
    "fork-branded fixtures matched the upstream expectation — the gate cannot fail"
else
  pass "negative-control/fork-identity-detected"
fi

# 2. A correctly-branded fixture must NOT trip the gate. A gate that flags
#    correct text is worse than no gate: it trains people to ignore this suite.
printf '{"name":"brain-marketplace","plugins":[{"name":"brain","source":"./brain"}]}\n' \
  >"$TMPROOT/ok-marketplace.json"
printf '{"name":"brain","version":"9.9.9"}\n' >"$TMPROOT/ok-plugin.json"
ok_identity="$(identity_of "$TMPROOT/ok-marketplace.json" "$TMPROOT/ok-plugin.json")"
if [ "$ok_identity" = "$EXPECTED" ]; then
  pass "negative-control/upstream-identity-is-clean"
else
  fail "negative-control/upstream-identity-is-clean" \
    "the gate flagged a correctly-branded fixture" \
    "expected: [$EXPECTED]" \
    "got:      [$ok_identity]"
fi

# --- the gate: this repo's shipped identity -----------------------------------
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
PLUGIN="$REPO_ROOT/brain/.claude-plugin/plugin.json"

missing=""
[ -f "$MARKETPLACE" ] || missing="$missing $MARKETPLACE"
[ -f "$PLUGIN" ] || missing="$missing $PLUGIN"
if [ -n "$missing" ]; then
  fail "upstream-identity/files-present" "identity file(s) not found:$missing"
else
  pass "upstream-identity/files-present"

  actual="$(identity_of "$MARKETPLACE" "$PLUGIN")"
  if [ -z "$actual" ]; then
    fail "upstream-identity/shipped-identity" \
      "could not parse the identity files — malformed JSON?"
  elif [ "$actual" = "$EXPECTED" ]; then
    pass "upstream-identity/shipped-identity"
  else
    fail "upstream-identity/shipped-identity" \
      "this repo's shipped identity is not the upstream one." \
      "expected: [$EXPECTED]" \
      "got:      [$actual]" \
      "fields:   marketplace.name|plugin count|plugins[0].name|plugins[0].source|plugin.json name" \
      "If a fork branch was picked or pushed here, revert the identity files." \
      "$MARKETPLACE" \
      "$PLUGIN"
  fi
fi

# --- summary ------------------------------------------------------------------
echo
echo "passed: $PASSED  failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
