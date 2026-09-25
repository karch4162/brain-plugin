#!/usr/bin/env bash
# write-hot.sh — make the wiki/hot.md wholesale rewrite safe under concurrency.
#
# /brain:save step 3 REWRITES wiki/hot.md rather than appending to it, because it
# is a rolling cache and the history lives in logs/. That is the right design and
# it has one sharp edge: two overlapping sessions each read hot.md, each rewrite
# it, and the later write silently discards the earlier one. There is no merge
# conflict to catch it — both wrote a whole file, and git only sees the last one.
#
# Of everything INNOV-275 lists, this is THE ONLY UNRECOVERABLE LOSS. A
# cross-contaminated commit has wrong attribution but nothing is gone; a commit
# on the wrong branch can be moved; a lost log.md line is one line. A discarded
# hot.md rewrite is a session's worth of curation that exists nowhere else.
# check-freshness.sh guards the neighbouring case (a STALE base at the start of
# the save); it cannot see the base CHANGING mid-save, which is this one.
#
# So the rewrite becomes a two-step, compare-and-swap operation:
#
#   1. pin    — hash hot.md at the moment you read it
#   2. write  — re-hash it, and install the new content ONLY if it still matches
#
# Step 2 holds a shared mkdir lock across the comparison and replacement. An
# agent cannot do this by hand: "verify immediately before the rewrite" is not
# something you can promise across a dozen tool calls, and the file is already
# gone by the time you notice. Hence a script, not a rule.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in
# the plugin, NOT inside the vault, so it cannot derive the vault from its own
# location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash write-hot.sh --pin              # before you read/edit hot.md
#   BRAIN_ROOT=<vault> bash write-hot.sh --write <newfile>  # install <newfile> as hot.md
#   BRAIN_ROOT=<vault> bash write-hot.sh --status           # report the pin, change nothing
#
# Contract (the /brain:save skill and its tests depend on exactly this):
#   exit 0  => the operation succeeded (pin recorded / new hot.md installed)
#   exit 1  => REFUSED — hot.md changed underneath you, or there is no pin.
#              On a refusal the EXISTING hot.md is untouched and your new content
#              is left where you wrote it, so nothing is lost either way.
# The FIRST line of output always starts with "HOT-WRITE: OK" (stdout) or
# "HOT-WRITE: REFUSED" (stderr), so a caller can branch on it without parsing
# prose.
#
# THE PIN lives at <vault>/.brain/hot.pin, or .brain/hot-<id>.pin when
# BRAIN_SESSION_ID / CLAUDE_CODE_SESSION_ID / GROK_SESSION_ID names the session
# (so one session's write cannot advance another's pin) — machine-local state about an
# in-flight command, never committed (the vault .gitignore template ignores
# .brain/). It holds the hash and when it was taken. A hot.md that does not exist
# yet pins as the literal `absent`, so the first-ever write is guarded too: if
# another session creates hot.md between your pin and your write, you are told
# rather than silently flattening it.
#
# NO PIN => REFUSE. Not "write anyway" — an unpinned write is precisely the
# unguarded rewrite this script exists to eliminate, and allowing it would make
# the guard optional in the one situation where it is skipped by accident. The
# refusal names the one command that fixes it.
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
HOT="$VAULT/wiki/hot.md"
PIN_DIR="$VAULT/.brain"
PIN_FILE="$PIN_DIR/hot.pin"
SESSION_ID="${BRAIN_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}}"
if [[ -n "$SESSION_ID" ]]; then
  case "$SESSION_ID" in
    *[!A-Za-z0-9._-]*) echo 'HOT-WRITE: REFUSED - invalid session id' >&2; exit 1 ;;
  esac
  PIN_FILE="$PIN_DIR/hot-$SESSION_ID.pin"
fi

refuse() { # reason-line, then extra lines
  {
    echo "HOT-WRITE: REFUSED - $1"
    shift
    local line
    for line in "$@"; do echo "$line"; done
  } >&2
  exit 1
}

# Hash of the current hot.md, or the literal string `absent` when there is no
# file. `absent` is a real, comparable state — not an error and not an empty
# string — so "the file appeared while I was working" is detectable rather than
# indistinguishable from "no hash available".
#
# Hashing is byte-exact and deliberately dumb: any change at all, including
# whitespace and line endings, breaks the pin. A false refusal costs a re-read; a
# false match costs someone's session.
hot_hash() {
  if [[ ! -e "$HOT" ]]; then echo "absent"; return 0; fi
  local h=""
  if command -v sha256sum >/dev/null 2>&1; then
    h="$(sha256sum "$HOT" 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    h="$(shasum -a 256 "$HOT" 2>/dev/null | awk '{print $1}')"
  elif command -v cksum >/dev/null 2>&1; then
    # Weaker, but this is a concurrency guard against honest overlap, not an
    # adversary. Prefixed so a cksum pin can never compare equal to a sha256 one.
    h="cksum:$(cksum <"$HOT" 2>/dev/null | awk '{print $1 "-" $2}')"
  fi
  if [[ -z "$h" ]]; then
    # No hashing tool at all. Fail closed: report a value that cannot match any
    # later reading, so the write refuses rather than proceeding unverified.
    echo "unhashable-$$"
    return 0
  fi
  echo "$h"
}

MODE="${1:-}"
case "$MODE" in
  --pin|--write|--status) ;;
  "") refuse "no mode given" "  Usage: write-hot.sh --pin | --write <newfile> | --status" ;;
  *)  refuse "unknown mode '$MODE'" "  Usage: write-hot.sh --pin | --write <newfile> | --status" ;;
esac

if [[ ! -d "$VAULT/wiki" ]]; then
  refuse "'$VAULT' doesn't look like a brain vault (no wiki/)" \
    "  Set BRAIN_ROOT to the vault root."
fi

# Both pin and write participate: pin must not observe an intermediate write.
# Locks are never reaped on a guessed timeout; that could evict a slow writer.
if [[ "$MODE" != "--status" ]]; then
  mkdir -p "$PIN_DIR" 2>/dev/null || refuse "cannot create pin directory"
  LOCK_DIR="$PIN_DIR/hot-write.lock"
  mkdir "$LOCK_DIR" 2>/dev/null || refuse "another hot.md operation holds $LOCK_DIR" \
    "  Retry after it finishes. Remove the lock only after confirming no writer remains."
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi

# --- --pin ------------------------------------------------------------------
if [[ "$MODE" == "--pin" ]]; then
  if ! mkdir -p "$PIN_DIR" 2>/dev/null; then
    refuse "could not create '$PIN_DIR' to hold the pin" \
      "  The pin is machine-local state (.gitignored); it needs a writable vault."
  fi
  h="$(hot_hash)"
  if [[ "$h" == unhashable-* ]]; then
    refuse "no hashing tool available (sha256sum, shasum and cksum are all missing)" \
      "  Without a hash there is no way to tell whether hot.md changed underneath" \
      "  the rewrite, and an unverified wholesale rewrite is the exact loss this" \
      "  guard exists to prevent. Install coreutils, or edit hot.md by hand."
  fi
  printf '%s\t%s\n' "$h" "$(date +%FT%T 2>/dev/null || echo unknown)" >"$PIN_FILE"
  if [[ "$h" == "absent" ]]; then
    echo "HOT-WRITE: OK - pinned wiki/hot.md as absent (no file yet); a first write is guarded too"
  else
    echo "HOT-WRITE: OK - pinned wiki/hot.md at ${h:0:12}"
  fi
  exit 0
fi

# --- read the pin (shared by --write and --status) --------------------------
PINNED=""
PINNED_AT=""
if [[ -f "$PIN_FILE" && -r "$PIN_FILE" ]]; then
  IFS=$'\t' read -r PINNED PINNED_AT <"$PIN_FILE" || true
  PINNED="${PINNED%$'\r'}"
fi

# --- --status ---------------------------------------------------------------
if [[ "$MODE" == "--status" ]]; then
  cur="$(hot_hash)"
  if [[ -z "$PINNED" ]]; then
    echo "HOT-WRITE: OK - no pin recorded; wiki/hot.md is currently ${cur:0:12}"
  elif [[ "$PINNED" == "$cur" ]]; then
    echo "HOT-WRITE: OK - pin ${PINNED:0:12} still matches wiki/hot.md (pinned $PINNED_AT)"
  else
    echo "HOT-WRITE: OK - pin ${PINNED:0:12} does NOT match wiki/hot.md ${cur:0:12} (pinned $PINNED_AT); a --write would refuse"
  fi
  exit 0
fi

# --- --write <newfile> ------------------------------------------------------
NEW="${2:-}"
if [[ -z "$NEW" ]]; then
  refuse "--write needs the path of a file holding the NEW hot.md content" \
    "  Write the rewritten hot.md to a temp file, then:" \
    "    bash write-hot.sh --write /path/to/new-hot.md"
fi
if [[ ! -f "$NEW" || ! -r "$NEW" ]]; then
  refuse "'$NEW' is not a readable file"
fi

if [[ -z "$PINNED" ]]; then
  refuse "no pin recorded for wiki/hot.md" \
    "  An unpinned wholesale rewrite is exactly the unguarded write this guard" \
    "  exists to prevent, so it is refused rather than allowed through." \
    "  Remedy: pin BEFORE you read hot.md, then write:" \
    "    BRAIN_ROOT=\"$VAULT\" bash write-hot.sh --pin" \
    "  (Your new content is untouched at '$NEW'.)"
fi

CUR="$(hot_hash)"
if [[ "$CUR" != "$PINNED" ]]; then
  {
    echo "HOT-WRITE: REFUSED - wiki/hot.md changed after you read it"
    echo "  pinned:  ${PINNED} (at ${PINNED_AT:-unknown})"
    echo "  now:     ${CUR}"
    echo "  hot.md is rewritten wholesale, so installing your version now would"
    echo "  silently discard whatever landed in between — and because both sides"
    echo "  wrote a whole file, git would show no conflict. That is the only"
    echo "  unrecoverable loss in this vault, which is why this refuses."
    echo "  NOTHING was changed: the current hot.md is intact, and your new content"
    echo "  is still at '$NEW'."
    echo "  Remedy: re-read the current wiki/hot.md, fold your changes into it, then"
    echo "    BRAIN_ROOT=\"$VAULT\" bash write-hot.sh --pin"
    echo "    BRAIN_ROOT=\"$VAULT\" bash write-hot.sh --write \"$NEW\""
  } >&2
  exit 1
fi

# Install via a temp file in the destination directory + mv, so a reader never
# sees a half-written hot.md and a failure part-way leaves the original in place.
mkdir -p "$(dirname "$HOT")" 2>/dev/null || true
TMP="$(dirname "$HOT")/.hot.md.$$"
if ! cp "$NEW" "$TMP" 2>/dev/null; then
  rm -f "$TMP" 2>/dev/null || true
  refuse "could not stage the new hot.md next to '$HOT'" \
    "  The existing wiki/hot.md is untouched and your content is still at '$NEW'."
fi
if ! mv "$TMP" "$HOT" 2>/dev/null; then
  rm -f "$TMP" 2>/dev/null || true
  refuse "could not install the new wiki/hot.md" \
    "  The existing wiki/hot.md is untouched and your content is still at '$NEW'."
fi

# Re-pin to what we just wrote, so a second guarded write in the same session
# (a budget trim after check-hot-budget.sh says OVER) works without re-pinning.
NEWHASH="$(hot_hash)"
printf '%s\t%s\n' "$NEWHASH" "$(date +%FT%T 2>/dev/null || echo unknown)" >"$PIN_FILE" 2>/dev/null || true

WORDS="$(wc -w <"$HOT" 2>/dev/null | tr -d ' \r')"
echo "HOT-WRITE: OK - wrote wiki/hot.md (${WORDS:-?} words), pin advanced to ${NEWHASH:0:12}"
echo "  Now check the budget: bash \"\${CLAUDE_PLUGIN_ROOT}/bin/check-hot-budget.sh\""
exit 0
