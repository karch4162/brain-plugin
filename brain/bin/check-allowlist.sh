#!/usr/bin/env bash
# check-allowlist.sh — does this vault's .saveinclude cover what the shipped
# commands actually commit? (INNOV-278, /brain:doctor check 8)
#
# WHY THIS EXISTS. Upgrading to plugin 0.2.22 silently broke bin/sync-graph.sh on
# every vault created before it. INNOV-275 routed every commit through
# vault-commit.sh, which stages only .saveinclude paths and refuses anything
# outside them — and `graphify/` had never needed to be allowlisted, because the
# syncer used to run its own `git add graphify wiki/log.md` and never consulted
# the allowlist. So the sync copies the mirrors, regenerates the stubs, appends
# the log line, and then refuses to commit any of it. The work is on disk, the
# commit is not, and the vault looks fine.
#
# The migration was documented in a PR body and a README. That is prose, and
# prose drifts — the thesis of this whole workstream. This script is the
# mechanism the prose was standing in for.
#
# THE REQUIRED SET IS NOT DEFINED HERE. It comes from
# `vault-commit.sh --print-required`, which is where the enforcement lives. A
# second copy in this file would be the INNOV-274 defect — one rule, two
# implementations — drifting in the most useless direction possible: this
# checker would go stale exactly when a newly-committed path made it matter.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in
# the plugin, NOT inside the vault, so it cannot derive the vault from its own
# location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash check-allowlist.sh          # report only, change nothing
#   BRAIN_ROOT=<vault> bash check-allowlist.sh --fix    # APPEND what is missing
#
# Contract (the /brain:doctor skill and its tests depend on exactly this):
#   exit 0  => the allowlist covers the required set (or --fix just made it do so)
#   exit 1  => INCOMPLETE — entries are missing, or there is no usable allowlist
# The FIRST line of output always starts with "ALLOWLIST: OK" (stdout) or
# "ALLOWLIST: INCOMPLETE" (stderr), so a caller can branch on it without parsing
# prose.
#
# --fix ONLY APPENDS. It never overwrites, never reorders, never removes, and
# never rewrites from the template. A vault's allowlist is a customized
# governance file — tray-brain carries `wiki/_drafts/`, which a template
# overwrite would silently drop. Appending is the only safe edit, and each
# appended entry is commented with which command needs it, so the next reader
# knows why it is there.
#
# NOTE ON SCOPE: a MISSING required entry is a defect. An EXTRA entry the user
# added is not — it is the whole point of a customizable allowlist. This script
# only ever reports what is absent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
SAVEINCLUDE="$VAULT/.saveinclude"
VAULT_COMMIT="$SCRIPT_DIR/vault-commit.sh"

FIX=0
case "${1:-}" in
  --fix) FIX=1 ;;
  "")    ;;
  *)     echo "ALLOWLIST: INCOMPLETE - unknown argument '${1}'" >&2
         echo "  Usage: check-allowlist.sh [--fix]" >&2
         exit 1 ;;
esac

incomplete() { # reason-line, then extra lines
  {
    echo "ALLOWLIST: INCOMPLETE - $1"
    shift
    local line
    for line in "$@"; do echo "$line"; done
  } >&2
  exit 1
}

# --- 0. is this a vault? ----------------------------------------------------
if [[ ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  echo "ALLOWLIST: OK - '$VAULT' doesn't look like a brain vault (no graphify/ or wiki/), check skipped"
  echo "  hint: set BRAIN_ROOT to the vault if this was meant to be checked." >&2
  exit 0
fi

# --- 1. the required set, from the one place that owns it -------------------
# A failure to read it is NOT reported as OK. If we cannot establish what the
# vault needs, we cannot establish that the vault has it — and a checker that
# reports ✅ when it could not check is worse than no checker, because it
# actively tells you to stop looking.
REQ_RAW="$(bash "$VAULT_COMMIT" --print-required 2>/dev/null)" || REQ_RAW=""
if [[ -z "$REQ_RAW" ]]; then
  incomplete "could not read the required path set from vault-commit.sh" \
    "  Tried: bash \"$VAULT_COMMIT\" --print-required" \
    "  Without it there is no way to tell whether this vault's .saveinclude is" \
    "  complete, so this reports a failure rather than a false OK." \
    "  Check the plugin install is intact (/brain:doctor check 7)."
fi

REQ_PATHS=()
REQ_WHY=()
while IFS=$'\t' read -r rpath rwhy || [[ -n "${rpath:-}" ]]; do
  rpath="${rpath%$'\r'}"
  [[ -z "$rpath" ]] && continue
  REQ_PATHS+=("$rpath")
  REQ_WHY+=("${rwhy:-a shipped brain command}")
done <<<"$REQ_RAW"

# --- 2. the vault's allowlist -----------------------------------------------
if [[ ! -f "$SAVEINCLUDE" || ! -r "$SAVEINCLUDE" ]]; then
  # Deliberately not auto-created even under --fix: dropping in a template is
  # /brain:init's job and its consent flow, and a vault missing this file may be
  # mid-setup rather than broken.
  incomplete "no readable .saveinclude at '$SAVEINCLUDE'" \
    "  .saveinclude is the vault's whole permission model. Without it," \
    "  vault-commit.sh refuses EVERY commit — /brain:save and bin/sync-graph.sh" \
    "  both stop working, loudly." \
    "  Remedy: seed it from the template, then re-run this check:" \
    "    cp \"$SCRIPT_DIR/../templates/saveinclude\" \"$SAVEINCLUDE\""
fi

ALLOW=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "$line" == \#* ]] && continue
  ALLOW+=("$line")
done <"$SAVEINCLUDE"

if [[ ${#ALLOW[@]} -eq 0 ]]; then
  incomplete "'.saveinclude' has no entries (only comments/blank lines)" \
    "  An empty allowlist permits nothing, so every brain commit is a no-op." \
    "  Remedy: re-run with --fix to append the required entries, or seed from" \
    "  the template at $SCRIPT_DIR/../templates/saveinclude"
fi

# --- 3. which required paths are not covered? -------------------------------
# "Covered" uses the SAME matching vault-commit.sh uses, so this check cannot
# disagree with the thing it is predicting. A required path counts as covered
# when an allowlist entry equals it, or is a directory prefix of it.
covers() { # allow_entry required_path
  local entry="$1" req="$2"
  [[ "$entry" == "$req" ]] && return 0
  case "$entry" in
    */) [[ "$req" == "$entry"* ]] && return 0 ;;
    *)  [[ "$req" == "$entry"/* ]] && return 0 ;;
  esac
  return 1
}

MISSING_PATHS=()
MISSING_WHY=()
for i in "${!REQ_PATHS[@]}"; do
  req="${REQ_PATHS[$i]}"
  found=0
  for entry in "${ALLOW[@]}"; do
    if covers "$entry" "$req"; then found=1; break; fi
  done
  if [[ $found -eq 0 ]]; then
    MISSING_PATHS+=("$req")
    MISSING_WHY+=("${REQ_WHY[$i]}")
  fi
done

# --- 4. all present -> OK ---------------------------------------------------
if [[ ${#MISSING_PATHS[@]} -eq 0 ]]; then
  echo "ALLOWLIST: OK - .saveinclude covers all ${#REQ_PATHS[@]} required path(s) (${#ALLOW[@]} entries total)"
  exit 0
fi

# --- 5. --fix: APPEND, never rewrite ----------------------------------------
if [[ $FIX -eq 1 ]]; then
  {
    printf '\n# Added by check-allowlist.sh (/brain:doctor check 8) — paths that shipped\n'
    printf '# brain commands commit. Without these the command does its file work and\n'
    printf '# then vault-commit.sh refuses to commit it.\n'
    for i in "${!MISSING_PATHS[@]}"; do
      printf '# %s\n%s\n' "${MISSING_WHY[$i]}" "${MISSING_PATHS[$i]}"
    done
  } >>"$SAVEINCLUDE" || incomplete "could not append to '$SAVEINCLUDE'" \
      "  The file was NOT modified. Check permissions."

  echo "ALLOWLIST: OK - appended ${#MISSING_PATHS[@]} missing entry(ies) to .saveinclude"
  printf '  + %s\n' "${MISSING_PATHS[@]}"
  echo "  Nothing was removed or reordered — existing entries are byte-identical."
  echo "  .saveinclude is a governance file and is NOT in the allowlist, so commit it"
  echo "  deliberately:  git -C \"$VAULT\" commit -o .saveinclude -m 'chore: allowlist required paths'"
  exit 0
fi

# --- 6. report ---------------------------------------------------------------
{
  echo "ALLOWLIST: INCOMPLETE - .saveinclude is missing ${#MISSING_PATHS[@]} of ${#REQ_PATHS[@]} required path(s)"
  for i in "${!MISSING_PATHS[@]}"; do
    echo "  missing: ${MISSING_PATHS[$i]}"
    echo "           needed by ${MISSING_WHY[$i]}"
  done
  echo "  Effect: those commands do their file work and then vault-commit.sh refuses"
  echo "  to commit it. The work lands on disk; the commit never happens."
  echo "  Remedy — appends only, never rewrites your customized list:"
  echo "    BRAIN_ROOT=\"$VAULT\" bash \"${BASH_SOURCE[0]}\" --fix"
} >&2
exit 1
