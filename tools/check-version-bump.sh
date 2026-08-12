#!/usr/bin/env bash
# check-version-bump.sh — fail if brain/ changed but the plugin version did not.
#
# Usage: check-version-bump.sh [base-ref]   (default: origin/main)
#
# Compares HEAD against the merge-base with <base-ref>, mirroring what
# `git diff base...HEAD` shows on a PR. Must run on bash 3.2 (macOS) —
# no mapfile, no associative arrays (INNOV-284).
set -uo pipefail

BASE="${1:-origin/main}"
PLUGIN_JSON="brain/.claude-plugin/plugin.json"

MB="$(git merge-base "$BASE" HEAD)" || {
  echo "check-version-bump: cannot find merge-base of '$BASE' and HEAD" >&2
  exit 1
}

CHANGED="$(git diff --name-only "$MB" HEAD)"

if ! printf '%s\n' "$CHANGED" | grep -q '^brain/'; then
  echo "check-version-bump: no changes under brain/ — no bump required."
  exit 0
fi

extract_version() { # ref
  git show "$1:$PLUGIN_JSON" 2>/dev/null \
    | node -e 'const s=require("fs").readFileSync(0,"utf8");process.stdout.write(String(JSON.parse(s).version))' 2>/dev/null
}

BASE_VERSION="$(extract_version "$MB")"
HEAD_VERSION="$(extract_version HEAD)"

# File absent at base (new plugin) — nothing to compare against.
if [ -z "$BASE_VERSION" ]; then
  echo "check-version-bump: $PLUGIN_JSON absent or unreadable at base — skipping."
  exit 0
fi

if [ "$BASE_VERSION" = "$HEAD_VERSION" ]; then
  echo "check-version-bump: FAIL — files under brain/ changed but the version" >&2
  echo "  in brain/.claude-plugin/plugin.json is still '$BASE_VERSION'." >&2
  echo "  Bump the \"version\" field in brain/.claude-plugin/plugin.json." >&2
  exit 1
fi

echo "check-version-bump: OK — version bumped $BASE_VERSION -> $HEAD_VERSION."
exit 0
