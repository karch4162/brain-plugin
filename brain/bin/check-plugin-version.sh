#!/usr/bin/env bash
# check-plugin-version.sh — is the INSTALLED brain plugin the one we shipped?
# (INNOV-277, /brain:doctor check 7)
#
# WHY THIS EXISTS. Nothing told anyone their installed brain plugin was behind.
# /brain:doctor already checks exactly this class of drift for graphify (check 3:
# "the CLI auto-upgraded, the skill didn't") — it just never turned the check on
# itself. Measured on the author's own machine, 2026-08-06: the install was
# 0.2.19 while source was 0.2.22, missing check-hot-budget.sh, label-guard.mjs,
# check-anchors.mjs, vault-commit.sh AND write-hot.sh. Nine shipped defect fixes
# were not running. This is also the most likely explanation for INNOV-265 —
# a ticket filed against a defect that had been fixed nine days earlier.
#
# That is the workstream's founding failure arriving by a different route: a
# known finding re-derived from scratch, because the machine reporting it was
# running code from before the fix. INNOV-262's auto-filing would NOT catch it —
# the ticket would just be filed faster.
#
# THERE ARE TWO PLACES IT GOES STALE, and they drift independently. This is the
# part the original ticket did not anticipate, and it is why a single check is
# not enough:
#
#   remote  --(a)-->  marketplace clone  --(b)-->  installed copy
#                     ~/.claude/plugins/    ~/.claude/plugins/cache/
#                       marketplaces/<mp>/    <mp>/<plugin>/<version>/
#
#   (a) stale => `claude plugin update` finds NOTHING NEW, because the clone it
#       reads has nothing new. This is the trap: the update command reports
#       success-shaped output and changes nothing.
#   (b) stale => the clone knows about a new version, the install still runs the
#       old one.
#
# Both were stale on the machine this was written on, which is why the fix is
# TWO commands in order, and why running only the second does nothing at all.
#
# WHAT THIS SCRIPT DOES NOT DO: it never reaches the network. Comparing the
# clone against its own remote would need a fetch, and a health check must work
# offline. So (a) is reported as an ADVISORY based on the clone's age, while (b)
# — the one that is checkable locally and exactly — is reported as a hard drift.
#
# Usage:
#   bash check-plugin-version.sh                   # check the brain plugin
#   bash check-plugin-version.sh --plugin <key>    # e.g. tray-brain@tray-brain-marketplace
#   bash check-plugin-version.sh --expect 0.2.22   # compare against an explicit version
#
# Contract (the /brain:doctor skill and its tests depend on exactly this):
#   exit 0  => installed matches the marketplace clone (or the check was skipped)
#   exit 1  => DRIFTED — the installed copy is not what the clone offers
# The FIRST line of output always starts with "PLUGIN-VERSION: OK" (stdout),
# "PLUGIN-VERSION: DRIFTED" (stderr) or "PLUGIN-VERSION: SKIPPED" (stdout), so a
# caller can branch on it without parsing prose.
#
# SKIPPED IS NOT OK, AND IS NEVER SILENT. A machine with no marketplace, no
# install record, or an unreadable cache reports SKIPPED and says which input was
# missing — exit 0, because an undeterminable state must not fail a health check,
# but visibly, because a false ✅ here is what cost this workstream two tickets.
set -uo pipefail

PLUGIN_KEY="brain@brain-marketplace"
EXPECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin) PLUGIN_KEY="${2:-}"; shift 2 || true ;;
    --expect) EXPECT="${2:-}"; shift 2 || true ;;
    *) { echo "PLUGIN-VERSION: SKIPPED - unknown argument '$1'"
         echo "  Usage: check-plugin-version.sh [--plugin <name@marketplace>] [--expect <version>]"; } >&2
       exit 0 ;;
  esac
done

PLUGIN_NAME="${PLUGIN_KEY%@*}"
MARKET_NAME="${PLUGIN_KEY#*@}"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INSTALLED_JSON="$CLAUDE_DIR/plugins/installed_plugins.json"
MARKETS_JSON="$CLAUDE_DIR/plugins/known_marketplaces.json"

skipped() { # reason, then extra lines
  echo "PLUGIN-VERSION: SKIPPED - $1"
  shift
  local line
  for line in "$@"; do echo "  $line" >&2; done
  exit 0
}

# Reads a plugin's installed version out of installed_plugins.json. Kept in one
# place because the file's shape (a MAP of key -> ARRAY of install records, one
# per scope) is not obvious and getting it wrong yields a confident wrong answer.
read_installed() {
  node -e '
    const fs = require("fs");
    try {
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const recs = (j.plugins || {})[process.argv[2]];
      if (!Array.isArray(recs) || !recs.length) process.exit(3);
      const r = recs[0];
      process.stdout.write([r.version || "", r.installPath || "", r.gitCommitSha || ""].join("\t"));
    } catch (e) { process.exit(4); }
  ' "$INSTALLED_JSON" "$PLUGIN_KEY" 2>/dev/null
}

read_market_location() {
  node -e '
    const fs = require("fs");
    try {
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const m = j[process.argv[2]];
      if (!m || !m.installLocation) process.exit(3);
      process.stdout.write([m.installLocation, m.lastUpdated || ""].join("\t"));
    } catch (e) { process.exit(4); }
  ' "$MARKETS_JSON" "$MARKET_NAME" 2>/dev/null
}

# --- 0. preconditions -------------------------------------------------------
command -v node >/dev/null 2>&1 || skipped "node is not on PATH, cannot read the plugin registries"
[[ -f "$INSTALLED_JSON" ]] || skipped "no installed_plugins.json at '$INSTALLED_JSON'" \
  "This machine may run the plugin from source (--plugin-dir), which never goes stale."

INSTALLED_RAW="$(read_installed)"
if [[ -z "$INSTALLED_RAW" ]]; then
  skipped "'$PLUGIN_KEY' is not recorded as installed" \
    "Either it runs from source (claude --plugin-dir), or it is installed under a" \
    "different marketplace name. Pass --plugin <name@marketplace> to check that one."
fi
IFS=$'\t' read -r INSTALLED_VER INSTALL_PATH INSTALL_SHA <<<"$INSTALLED_RAW"

# --- 1. what does the marketplace clone offer? ------------------------------
EXPECTED_VER=""
SOURCE_DESC=""
CLONE_DIR=""
CLONE_UPDATED=""

if [[ -n "$EXPECT" ]]; then
  EXPECTED_VER="$EXPECT"
  SOURCE_DESC="--expect"
else
  MARKET_RAW="$(read_market_location)"
  if [[ -n "$MARKET_RAW" ]]; then
    IFS=$'\t' read -r CLONE_DIR CLONE_UPDATED <<<"$MARKET_RAW"
    # Windows paths arrive backslashed; bash needs them forward.
    CLONE_DIR="${CLONE_DIR//\\//}"
    # The plugin's manifest is the authority (README: version resolves from
    # plugin.json first). Its directory inside the marketplace is not always the
    # plugin name, so search rather than assume.
    for cand in "$CLONE_DIR/$PLUGIN_NAME/.claude-plugin/plugin.json" \
                "$CLONE_DIR/.claude-plugin/plugin.json"; do
      if [[ -f "$cand" ]]; then
        EXPECTED_VER="$(node -e '
          const fs=require("fs");
          try { process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).version||"")); }
          catch(e){ process.exit(3); }' "$cand" 2>/dev/null)"
        [[ -n "$EXPECTED_VER" ]] && { SOURCE_DESC="marketplace clone"; break; }
      fi
    done
    if [[ -z "$EXPECTED_VER" ]]; then
      found="$(find "$CLONE_DIR" -maxdepth 3 -name plugin.json -path '*.claude-plugin*' 2>/dev/null | head -1)"
      if [[ -n "$found" ]]; then
        EXPECTED_VER="$(node -e '
          const fs=require("fs");
          try { process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).version||"")); }
          catch(e){ process.exit(3); }' "$found" 2>/dev/null)"
        SOURCE_DESC="marketplace clone"
      fi
    fi
  fi
fi

if [[ -z "$EXPECTED_VER" ]]; then
  skipped "could not determine the expected version for '$PLUGIN_KEY'" \
    "installed: ${INSTALLED_VER:-?}" \
    "Looked for the marketplace clone via '$MARKETS_JSON'." \
    "Reporting SKIPPED rather than OK — an unknown expected version is not a match."
fi

# --- 2. the advisory: is the CLONE itself stale? ----------------------------
# Checked without the network, from the clone's own recorded refresh time. This
# is the failure mode `claude plugin update` alone cannot fix, and the one that
# makes it look like it worked.
CLONE_NOTE=""
if [[ -n "$CLONE_UPDATED" ]]; then
  age_days="$(node -e '
    const t = Date.parse(process.argv[1]);
    if (!t) process.exit(3);
    process.stdout.write(String(Math.floor((Date.now() - t) / 86400000)));
  ' "$CLONE_UPDATED" 2>/dev/null)"
  if [[ "$age_days" =~ ^[0-9]+$ ]] && (( age_days >= 7 )); then
    CLONE_NOTE="the marketplace clone itself was last refreshed ${age_days} day(s) ago — it may not know about newer releases either"
  fi
fi

# --- 3. verdict -------------------------------------------------------------
if [[ "$INSTALLED_VER" == "$EXPECTED_VER" ]]; then
  echo "PLUGIN-VERSION: OK - $PLUGIN_KEY installed $INSTALLED_VER == $SOURCE_DESC $EXPECTED_VER"
  [[ -n "$CLONE_NOTE" ]] && echo "  note: $CLONE_NOTE" >&2
  exit 0
fi

{
  echo "PLUGIN-VERSION: DRIFTED - $PLUGIN_KEY installed $INSTALLED_VER, $SOURCE_DESC offers $EXPECTED_VER"
  echo "  installed at: ${INSTALL_PATH:-?}"
  [[ -n "$INSTALL_SHA" ]] && echo "  installed sha: $INSTALL_SHA"
  echo "  A stale install runs the code from before every fix released since"
  echo "  $INSTALLED_VER — silently. Guards you shipped are simply not there, and a"
  echo "  defect you already fixed will be re-reported as new."
  [[ -n "$CLONE_NOTE" ]] && echo "  ALSO: $CLONE_NOTE"
  echo "  Remedy — BOTH commands, in this order:"
  echo "    claude plugin marketplace update $MARKET_NAME"
  echo "    claude plugin update $PLUGIN_KEY"
  echo "  The second alone is not enough: it reads the local clone, so if the clone"
  echo "  is stale it finds nothing new and reports success. Then restart the session"
  echo "  (or /reload-plugins) — an updated copy is not live until then."
} >&2
exit 1
