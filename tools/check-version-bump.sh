#!/usr/bin/env bash
# check-version-bump.sh — fail if a plugin dir (brain/, wave/, ...) changed but its version did not.
#
# Usage: check-version-bump.sh [base-ref]   (default: origin/main)
#
# Compares HEAD against the merge-base with <base-ref>, mirroring what
# `git diff base...HEAD` shows on a PR. Must run on bash 3.2 (macOS) —
# no mapfile, no associative arrays (INNOV-284).
set -uo pipefail

BASE="${1:-origin/main}"

MB="$(git merge-base "$BASE" HEAD)" || {
  echo "check-version-bump: cannot find merge-base of '$BASE' and HEAD" >&2
  exit 1
}

CHANGED="$(git diff --name-only "$MB" HEAD)"

extract_version() { # ref path
  git show "$1:$2" 2>/dev/null     | node -e 'const s=require("fs").readFileSync(0,"utf8");process.stdout.write(String(JSON.parse(s).version))' 2>/dev/null
}

# Every top-level plugin dir (<dir>/.claude-plugin/plugin.json) is gated on its own.
status=0
checked=0
for PLUGIN_JSON in */.claude-plugin/plugin.json; do
  [ -f "$PLUGIN_JSON" ] || continue
  DIR="${PLUGIN_JSON%%/*}"
  printf '%s
' "$CHANGED" | grep -q "^$DIR/" || continue
  checked=$((checked + 1))

  BASE_VERSION="$(extract_version "$MB" "$PLUGIN_JSON")"
  HEAD_VERSION="$(extract_version HEAD "$PLUGIN_JSON")"

  # File absent at base (new plugin) — nothing to compare against.
  if [ -z "$BASE_VERSION" ]; then
    echo "check-version-bump: $PLUGIN_JSON absent or unreadable at base — skipping."
  elif [ "$BASE_VERSION" = "$HEAD_VERSION" ]; then
    echo "check-version-bump: FAIL — files under $DIR/ changed but the version" >&2
    echo "  in $PLUGIN_JSON is still '$BASE_VERSION'." >&2
    echo "  Bump the \"version\" field in $PLUGIN_JSON." >&2
    status=1
  else
    echo "check-version-bump: OK — $DIR version bumped $BASE_VERSION -> $HEAD_VERSION."
  fi
done

[ "$checked" -gt 0 ] || echo "check-version-bump: no plugin dir changed — no bump required."
exit $status
