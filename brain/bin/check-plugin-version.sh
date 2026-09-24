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
# NETWORK: OPPORTUNISTIC, NEVER REQUIRED. (a) is only exactly checkable with a
# fetch, so when the clone is a git repo with an origin remote we ATTEMPT one —
# quiet, no auth prompts, hard ~5s timeout. If it succeeds we compare the clone
# against origin for real (STALE-CLONE below). If it fails, times out, or the
# clone is not a git repo, we degrade to the old behavior — the clone-age
# ADVISORY — and the OK line SAYS the remote was not checked. Being offline is
# never an error; (b) stays checkable locally and exactly, as a hard drift.
#
# Usage:
#   bash check-plugin-version.sh                   # check the brain plugin
#   bash check-plugin-version.sh --plugin <key>    # e.g. brain@brain-marketplace
#   bash check-plugin-version.sh --expect 0.2.22   # compare against an explicit version
#
# Contract (the /brain:doctor skill and its tests depend on exactly this):
#   exit 0  => installed matches the marketplace clone (or the check was skipped)
#   exit 1  => DRIFTED — the installed copy is not what the clone offers — or
#              STALE-CLONE — install == clone, but a successful fetch proved the
#              clone itself is behind its remote
# The FIRST line of output always starts with "PLUGIN-VERSION: OK" (stdout),
# "PLUGIN-VERSION: DRIFTED" (stderr), "PLUGIN-VERSION: STALE-CLONE" (stderr) or
# "PLUGIN-VERSION: SKIPPED" (stdout), so a caller can branch on it without
# parsing prose. The OK line always states what was actually compared: either
# "(clone current with remote)" or "(remote not checked: <reason>; ...)".
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

# --- 2b. opportunistic fetch: is the clone behind its REMOTE? ---------------
# Only attempted when the clone is a git repo with an origin remote. A fetch
# failure or timeout is NEVER an error — it degrades to the age advisory above,
# and the OK line says the remote was not checked. GIT_TERMINAL_PROMPT=0 so a
# credential prompt can never hang a health check; the timeout is a background
# job + poll loop because timeout(1) is not guaranteed on Git Bash/macOS and
# `wait -n` is bash 4.3+.
FETCH_STATE="not-attempted"   # ok | failed | timeout | no-git-repo | not-attempted
BEHIND=""
if [[ "$SOURCE_DESC" == "marketplace clone" && -n "$CLONE_DIR" ]]; then
  if git -C "$CLONE_DIR" rev-parse --git-dir >/dev/null 2>&1 \
     && git -C "$CLONE_DIR" remote get-url origin >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 git -C "$CLONE_DIR" fetch origin --quiet >/dev/null 2>&1 &
    fetch_pid=$!
    tick=0
    while kill -0 "$fetch_pid" 2>/dev/null && [[ $tick -lt 25 ]]; do
      tick=$((tick + 1)); sleep 0.2
    done
    if kill -0 "$fetch_pid" 2>/dev/null; then
      kill "$fetch_pid" 2>/dev/null
      wait "$fetch_pid" 2>/dev/null
      FETCH_STATE="timeout"
    elif wait "$fetch_pid" 2>/dev/null; then
      FETCH_STATE="ok"
    else
      FETCH_STATE="failed"
    fi
    if [[ "$FETCH_STATE" == "ok" ]]; then
      upstream=""
      for ref in origin/HEAD origin/main origin/master; do
        if git -C "$CLONE_DIR" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
          upstream="$ref"; break
        fi
      done
      if [[ -n "$upstream" ]]; then
        BEHIND="$(git -C "$CLONE_DIR" rev-list --count "HEAD..$upstream" 2>/dev/null)"
        [[ "$BEHIND" =~ ^[0-9]+$ ]] || { BEHIND=""; FETCH_STATE="failed"; }
      else
        FETCH_STATE="failed"   # fetched, but nothing to compare against
      fi
    fi
  else
    FETCH_STATE="no-git-repo"
  fi
fi

# Human-readable reason + clone age for the "remote not checked" qualifier.
remote_qualifier() {
  local reason age=""
  case "$FETCH_STATE" in
    timeout)     reason="fetch timed out" ;;
    no-git-repo) reason="no git repo" ;;
    *)           reason="offline" ;;
  esac
  if [[ -n "$CLONE_UPDATED" ]]; then
    age="$(node -e '
      const t = Date.parse(process.argv[1]);
      if (!t) process.exit(3);
      const h = Math.floor((Date.now() - t) / 3600000);
      process.stdout.write(h < 48 ? h + " hour(s) ago" : Math.floor(h / 24) + " day(s) ago");
    ' "$CLONE_UPDATED" 2>/dev/null)"
  fi
  echo "remote not checked: $reason; clone last refreshed ${age:-at an unknown time}"
}

# --- 3. verdict -------------------------------------------------------------
if [[ "$INSTALLED_VER" == "$EXPECTED_VER" ]]; then
  if [[ "$SOURCE_DESC" == "marketplace clone" && "$FETCH_STATE" == "ok" && -n "$BEHIND" && "$BEHIND" -gt 0 ]]; then
    # Install matches the clone, but the clone itself is provably behind. This
    # is the exact trap the age advisory could only guess at: `claude plugin
    # update` would find nothing new and report success-shaped output.
    {
      echo "PLUGIN-VERSION: STALE-CLONE - $PLUGIN_KEY install matches clone ($INSTALLED_VER) but the clone is $BEHIND commit(s) behind its remote"
      echo "  installed at: ${INSTALL_PATH:-?}"
      echo "  The install can only be as fresh as the clone it came from, and the clone"
      echo "  is behind. Guards shipped since then are simply not here."
      echo "  Remedy — BOTH commands, in this order:"
      echo "    claude plugin marketplace update $MARKET_NAME"
      echo "    claude plugin update $PLUGIN_KEY"
      echo "  The second alone is not enough: it reads the local clone, so if the clone"
      echo "  is stale it finds nothing new and reports success. Then restart the session"
      echo "  (or /reload-plugins) — an updated copy is not live until then."
    } >&2
    exit 1
  fi
  if [[ "$SOURCE_DESC" == "marketplace clone" ]]; then
    if [[ "$FETCH_STATE" == "ok" ]]; then
      echo "PLUGIN-VERSION: OK - $PLUGIN_KEY installed $INSTALLED_VER == marketplace clone $EXPECTED_VER (clone current with remote)"
    else
      echo "PLUGIN-VERSION: OK - $PLUGIN_KEY installed $INSTALLED_VER == marketplace clone $EXPECTED_VER ($(remote_qualifier))"
    fi
  else
    echo "PLUGIN-VERSION: OK - $PLUGIN_KEY installed $INSTALLED_VER == $SOURCE_DESC $EXPECTED_VER"
  fi
  [[ -n "$CLONE_NOTE" ]] && echo "  note: $CLONE_NOTE" >&2
  exit 0
fi

{
  echo "PLUGIN-VERSION: DRIFTED - $PLUGIN_KEY installed $INSTALLED_VER, $SOURCE_DESC offers $EXPECTED_VER"
  echo "  installed at: ${INSTALL_PATH:-?}"
  [[ -n "$INSTALL_SHA" ]] && echo "  installed sha: $INSTALL_SHA"
  [[ "$FETCH_STATE" == "ok" && -n "$BEHIND" && "$BEHIND" -gt 0 ]] \
    && echo "  AND the clone itself is $BEHIND commit(s) behind its remote — both staleness points at once."
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
