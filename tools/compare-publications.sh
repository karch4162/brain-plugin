#!/usr/bin/env bash
# compare-publications.sh — diff this plugin against its Tray publication.
#
# This repo (karch4162/brain-plugin) and vendsy/tray-brain-plugin are the same
# codebase published to two marketplaces. They share NO git ancestry — same
# commit messages, different SHAs — so `git log A ^B` cannot answer "what have I
# not ported yet". This script answers it by content instead, with no coupling
# between the two repos: nothing is added as a remote, nothing is grafted, and
# either side can be deleted without touching the other.
#
# It compares COMMITTED trees (via `git archive`), not working directories, so
# untracked scratch files and CRLF checkouts never show up as false differences.
# That matters on Windows: the Tray checkout stores CRLF in the working tree, so
# a naive `diff -r` reports every file as different.
#
# Two deltas are EXPECTED and filtered out as branding, not divergence:
#   1. `/brain:` vs `/tray-brain:` in skill prose — the command namespace comes
#      from plugin.json "name", so these strings are documentation only.
#   2. "name": "brain" vs "tray-brain" in plugin.json.
# Anything else is real: either an unported change or deliberate divergence.
# The script does not know which — that judgment is yours.
#
# Usage:
#   bash tools/compare-publications.sh                    # committed main vs main
#   bash tools/compare-publications.sh --ref HEAD         # compare working branches
#   bash tools/compare-publications.sh --raw              # skip branding filter
#   TRAY_PLUGIN=~/src/tray-brain-plugin bash tools/compare-publications.sh
#
# Exit: 0 = in sync (branding aside) · 1 = differences found · 2 = setup error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSONAL="${PERSONAL_PLUGIN:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TRAY="${TRAY_PLUGIN:-$HOME/Projects/Tray/tray-brain-plugin}"
REF="main"
RAW=0
SUBDIR="brain"   # the shipped plugin payload; repo-root dirs are personal-only

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)     REF="${2:?--ref needs a value}"; shift 2 ;;
    --tray)    TRAY="${2:?--tray needs a path}"; shift 2 ;;
    --raw)     RAW=1; shift ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *)         echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

for repo in "$PERSONAL" "$TRAY"; do
  [ -d "$repo/.git" ] || { echo "not a git repo: $repo" >&2; exit 2; }
done

# Resolve the ref per repo — they have unrelated histories, so a SHA is
# meaningless across them; only symbolic names (main, HEAD) make sense.
resolve() {
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1 && echo "$2" && return
  git -C "$1" rev-parse --verify --quiet "origin/$2^{commit}" >/dev/null 2>&1 && echo "origin/$2" && return
  echo "ref '$2' not found in $1" >&2; exit 2
}
P_REF="$(resolve "$PERSONAL" "$REF")"
T_REF="$(resolve "$TRAY" "$REF")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# git archive emits blob content as committed — LF, no working-tree noise.
export_tree() {
  local repo="$1" ref="$2" dest="$3"
  mkdir -p "$dest"
  git -C "$repo" archive "$ref" "$SUBDIR" | tar -x -C "$dest"
}
export_tree "$PERSONAL" "$P_REF" "$TMP/personal"
export_tree "$TRAY"     "$T_REF" "$TMP/tray"

# Normalize the Tray side onto personal naming. Only ever rewrites the copy in
# $TMP — neither checkout is touched.
# Normalize BOTH trees the same way. Two traps here, both hit during development:
#   - GNU sed -i under Git Bash writes CRLF, so a file rewritten on one side no
#     longer matches its untouched counterpart. Every file gets the CR strip,
#     rewritten or not.
#   - Only UNAMBIGUOUS plugin-identity tokens are rewritten. A bare
#     `tray-brain` -> `brain` catch-all is WRONG: `tray-brain` is also the name
#     of the Tray *vault*, which both copies reference identically (registry
#     examples, resolve-repos comments). Rewriting it invented four phantom
#     differences. Plugin identity and vault identity collide as strings; only
#     the compound forms below are safe.
#   - Compound patterns must precede narrower ones (tray-brain-marketplace
#     before /tray-brain:).
normalize() {
  local tree="$1" brand="$2"
  find "$tree" -type f -print0 |
    while IFS= read -r -d '' f; do
      if [ "$brand" = "1" ]; then
        sed -i \
          -e 's|tray-brain@tray-brain-marketplace|brain@brain-marketplace|g' \
          -e 's|tray-brain-marketplace|brain-marketplace|g' \
          -e 's|vendsy/tray-brain-plugin|karch4162/brain-plugin|g' \
          -e 's|/tray-brain:|/brain:|g' \
          -e 's|`tray-brain:|`brain:|g' \
          "$f"
        # Plugin identity only. Elsewhere `"name": "tray-brain"` is a VAULT
        # registry entry that both copies share verbatim — rewriting it there
        # invented two more phantom differences.
        case "$f" in
          */.claude-plugin/plugin.json)
            sed -i 's|"name": "tray-brain"|"name": "brain"|' "$f" ;;
        esac
      fi
      tr -d '\r' < "$f" > "$f.lf" && mv "$f.lf" "$f"
    done
}
normalize "$TMP/personal" 0
normalize "$TMP/tray" "$([ "$RAW" -eq 0 ] && echo 1 || echo 0)"

P_VER="$(git -C "$PERSONAL" show "$P_REF:$SUBDIR/.claude-plugin/plugin.json" | sed -n 's/.*"version": "\([^"]*\)".*/\1/p')"
T_VER="$(git -C "$TRAY"     show "$T_REF:$SUBDIR/.claude-plugin/plugin.json" | sed -n 's/.*"version": "\([^"]*\)".*/\1/p')"

echo "personal : $PERSONAL @ $P_REF (v$P_VER)"
echo "tray     : $TRAY @ $T_REF (v$T_VER)"
[ "$RAW" -eq 0 ] && echo "filter   : branding normalized (--raw to disable)" || echo "filter   : none (--raw)"
[ "$P_VER" != "$T_VER" ] && echo "note     : versions differ — expected once the publications intentionally diverge"
echo

if diff -rq "$TMP/personal" "$TMP/tray" >"$TMP/summary" 2>&1; then
  echo "IN SYNC — no differences beyond branding."
  exit 0
fi

# Rewrite temp paths back to something recognizable.
sed -e "s|$TMP/personal|personal|g" -e "s|$TMP/tray|tray|g" "$TMP/summary"
echo
echo "--- full diff ---"
diff -ru "$TMP/personal" "$TMP/tray" |
  sed -e "s|$TMP/personal|personal|g" -e "s|$TMP/tray|tray|g" || true
echo
echo "Differences found. Each is either an unported change or deliberate divergence."
exit 1
