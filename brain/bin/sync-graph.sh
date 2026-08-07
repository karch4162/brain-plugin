#!/usr/bin/env bash
# sync-graph.sh — publish a repo's graphify artifacts into a brain vault.
#
# Copies the three durable artifacts (graph.json, GRAPH_REPORT.md, manifest.json)
# from <repo>/graphify-out/ into <vault>/graphify/<repo-name>/, regenerates the
# Obsidian community stub notes (communities/), appends a wiki/log.md entry, and
# commits. Push is left to you.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in the
# plugin, NOT inside the vault, so it cannot derive the vault from its own location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash sync-graph.sh                  # sync only mirrors that are STALE (see below)
#   bash sync-graph.sh <repo-path> [...]                   # sync specific repo checkout(s)
#   bash sync-graph.sh --all                               # sync EVERY mirror under <vault>/graphify/
#   bash sync-graph.sh --no-commit [...]                   # copy + log only, no git commit
#   bash sync-graph.sh --force-commit [...]                # commit even if the vault branch has an open PR
#                                                          # (NOT the protected branch — see COMMITTING below)
#
# Flags may appear in any order, anywhere before the repo args. If both
# --no-commit and --force-commit are given, --no-commit wins.
#
# DEFAULT SCOPE (no repo args): each folder name under <vault>/graphify/ is
# resolved to a checkout at $REPOS_DIR/<name> (default: the vault's parent dir),
# but only mirrors that are actually STALE are selected — i.e. the repo-side
# graphify-out/graph.json exists AND differs byte-for-byte from the mirrored
# copy in the vault. Mirrors nobody rebuilt this session are left alone (an
# unscoped run once degraded an untouched mirror's labels). The selected list is
# printed to stderr before any work happens; if nothing is stale the script says
# so and exits 0. Explicit repo args are NEVER filtered — naming a repo means it.
# --all opts back into the old "every mirror under graphify/" scope, skipping the
# staleness filter (it still prints the selected list to stderr).
#
# LABEL GUARD: the vault-side GRAPH_REPORT.md is only overwritten when the
# incoming report names at least as many communities as the existing one. That
# rule (and the definition of "named") lives in bin/label-guard.mjs, shared with
# /brain:label's label-communities.mjs — see INNOV-274. It is enforced by running
# `node bin/label-guard.mjs --may-replace`, and it FAILS CLOSED: if node is
# missing, the module is broken, or the answer is anything we do not recognise,
# the existing report is KEPT and the sync says so on stderr. graph.json and
# manifest.json still mirror.
#
# SCOPE AUDIT (INNOV-267/268): before a mirror is published, its graph is checked
# against the standard scope by bin/scope-audit.mjs, in BOTH directions — nodes
# built from files that must be OUT (build/config manifests, test scaffolding,
# deps, generated output), and source-bearing top-level directories with ZERO
# nodes. A finding REFUSES that mirror's copy, names the offending files and the
# remedy, and makes the run exit 1; other mirrors still sync and still commit.
# The rule the audit enforces is the one the vault records, so it is finally a
# mechanism rather than a paragraph — everything enforced by prose drifts.
#
# COMMITTING IS NOT THIS SCRIPT'S JOB (INNOV-275). Every guard that used to live
# here — open-PR, protected branch, HEAD pin — now lives in bin/vault-commit.sh,
# the single commit path shared with /brain:save. This script captures the HEAD
# pin at start, copies files, and hands the commit over. It carries no commit
# rules of its own, so it cannot drift from the ones /brain:save enforces.
#
# What that buys, and what it costs, in one line each:
#   • the commit is refused on the protected/default branch, with NO override —
#     --force-commit used to bypass that here, and INNOV-275 retires it. A human
#     who genuinely means to commit onto main can run git by hand.
#   • --force-commit still overrides the OPEN-PR guard only.
#   • a refusal now leaves NOTHING staged (it used to leave the sync staged).
#     The index is shared by every session in the checkout, so leaving a payload
#     in it hands the next session a commit it never chose. Re-run instead.
#   • the sync's file copies, log.md line and stub regeneration all still happen;
#     only the commit is withheld.
#
# HEAD PIN: the vault's branch + commit SHA are recorded at start and passed to
# vault-commit.sh, which re-checks them immediately before committing. If either
# moved (a concurrent session merged a PR and moved HEAD mid-run), the commit is
# refused. --force-commit does NOT override that one.
#
# Override per machine: REPOS_DIR=~/code BRAIN_ROOT=<vault> bash sync-graph.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# Where the covered repos are checked out — explicit REPOS_DIR, else auto-detect the two
# common layouts (repos one or two levels above the vault). No fixed-layout assumption.
if [[ -z "${REPOS_DIR:-}" ]]; then
  REPOS_DIR="$VAULT/.."
  for cand in "$VAULT/.." "$VAULT/../.."; do
    for d in "$VAULT"/graphify/*/; do
      [[ -d "$d" ]] || continue
      if [[ -d "$cand/$(basename "$d")" ]]; then REPOS_DIR="$cand"; break 2; fi
    done
  done
fi

if [[ ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  echo "error: '$VAULT' doesn't look like a brain vault (no graphify/ or wiki/). Set BRAIN_ROOT." >&2
  exit 1
fi

# HEAD PIN (INNOV-270 ask 3): capture the vault's branch AND commit SHA BEFORE any
# file is copied, so the pre-commit re-check below can tell whether a concurrent
# session moved HEAD underneath this run. Empty on a non-git vault, which simply
# makes the later comparison a no-op.
HEAD_BRANCH_AT_START="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
HEAD_SHA_AT_START="$(git -C "$VAULT" rev-parse HEAD 2>/dev/null || true)"

COMMIT=1
FORCE_COMMIT=0
SYNC_ALL=0
# Flags may be given in any order and anywhere before the repo args; the first
# non-flag argument ends flag parsing (repo paths can legitimately start with
# anything, and `--` explicitly terminates the flags).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-commit)    COMMIT=0; shift ;;
    --force-commit) FORCE_COMMIT=1; shift ;;
    --all)          SYNC_ALL=1; shift ;;
    --)             shift; break ;;
    *)              break ;;
  esac
done
# --no-commit wins over --force-commit if both were passed.
if [[ $COMMIT -eq 0 ]]; then FORCE_COMMIT=0; fi

# THE LABEL RULE LIVES IN bin/label-guard.mjs (INNOV-274).
#
# This script used to carry count_named_labels(): a pair of greps encoding its
# own idea of "a named community heading", feeding an `incoming >= existing`
# comparison. label-communities.mjs encoded the SAME concept a second time, in a
# regex, and neither knew about the other. Both now call one module, so the two
# commands that touch community labels (/brain:save here, /brain:label there)
# cannot drift apart.
LABEL_GUARD="$SCRIPT_DIR/label-guard.mjs"

# Asks the shared module whether the incoming report ($2) may overwrite the
# existing one ($1). Prints ONE line to stdout for the caller to parse:
#
#   allow <existing_named> <incoming_named>   → copying is safe
#   refuse <existing_named> <incoming_named>  → copying would destroy labels
#   error                                     → COULD NOT DECIDE
#
# `error` covers every way this can go wrong: node missing from PATH, the module
# unreadable or deleted, a malformed/unreadable report, an unrecognised exit
# code, unexpected stdout — anything at all. There is deliberately no fourth
# outcome, and no path on which a failure is reported as `allow`.
#
# FAIL-CLOSED DIRECTIONS (the whole point of this guard):
#   node missing / module gone / crash / garbage stdout → `error` → NOT copied.
#   verdict is anything but the literal word `allow`    → NOT copied.
#   guard says `allow` and exit status is 0             → copied.
# The single case that errs toward copying is "the module ran, exited 0 and said
# allow" — i.e. it positively decided there is nothing to lose. Silence is never
# consent here.
#
# Always exits 0 itself, so `set -e` cannot turn a refusal into an aborted sync.
label_guard_verdict() { # existing_report incoming_report
  local existing="${1:-}" incoming="${2:-}" out="" rc=0 verdict="" have="" want=""
  out="$(node "$LABEL_GUARD" --may-replace "$existing" "$incoming" 2>/dev/null)" || rc=$?
  read -r verdict have want <<<"${out:-}" || true
  # Both counts must be plain integers, or we did not understand the answer.
  if [[ ! "$have" =~ ^[0-9]+$ || ! "$want" =~ ^[0-9]+$ ]]; then
    echo "error"
    return 0
  fi
  if [[ $rc -eq 0 && "$verdict" == "allow" ]]; then
    echo "allow $have $want"
  elif [[ $rc -eq 10 && "$verdict" == "refuse" ]]; then
    echo "refuse $have $want"
  else
    echo "error"
  fi
  return 0
}

# --- THE SCOPE GATE (INNOV-267 + INNOV-268) ---------------------------------
#
# The vault records a SCOPE per repo but nothing implemented it. graphify scans
# ONE positional root, so a multi-root scope is really "scan the root, carve back
# with .graphifyignore" — and that carve-out used to be git-excluded, so it
# existed only on the machine that built the graph. The mirrors that audited
# clean did so because their authors' unreviewable ignore files happened to be
# complete. bin/scope-audit.mjs is the mechanism that check was standing in for.
#
# WHY THIS GUARD'S POLARITY IS THE OPPOSITE OF THE LABEL GUARD'S, three lines up.
# The label guard FAILS CLOSED — "cannot tell" means "do not copy" — because an
# overwritten labeled report is UNRECOVERABLE: the human naming work is simply
# gone. An unaudited publish is not like that. It is recoverable (re-audit and
# re-sync at any time), it is the status quo every existing mirror was built
# under, and refusing every mirror whose graph predates this check would break
# working vaults to enforce a rule they have never been given the chance to meet.
# So:
#   OUT-OF-SCOPE / MISSING-ROOTS  → REFUSE this mirror. The audit positively
#                                   established that the graph is wrong.
#   SKIPPED / unparsable verdict  → LOUD WARNING, publish proceeds. The audit
#                                   established nothing, and says so.
# What is NOT negotiable either way is the naming: SKIPPED is never printed or
# treated as OK (INNOV-277/279). "We could not check" and "we checked and it is
# fine" are different sentences, and a run that conflates them tells the reader
# to stop looking.
SCOPE_AUDIT="$SCRIPT_DIR/scope-audit.mjs"

# Runs the audit for one mirror. Sets SCOPE_VERDICT (OK | OUT-OF-SCOPE |
# MISSING-ROOTS | SKIPPED | UNKNOWN) and SCOPE_OUTPUT (the full report).
# UNKNOWN covers every way the answer can be uninterpretable — node missing, the
# module gone, a first line we do not recognise, or a first line whose verdict
# disagrees with the exit status. It is deliberately NOT collapsed into SKIPPED:
# SKIPPED is the auditor's own honest "I could not determine this", UNKNOWN is
# "the auditor did not answer at all", and the stderr text differs accordingly.
# Always returns 0 so `set -e` cannot turn a report into an aborted sync.
scope_audit() { # graph_path repo_root name
  local graph="${1:-}" root="${2:-}" nm="${3:-}" rc=0 first=""
  SCOPE_VERDICT="UNKNOWN"
  SCOPE_OUTPUT="$(node "$SCOPE_AUDIT" --graph "$graph" --repo-root "$root" --name "$nm" 2>&1)" || rc=$?
  first="${SCOPE_OUTPUT%%$'\n'*}"
  case "$first" in
    "SCOPE-AUDIT: OK"*)            SCOPE_VERDICT="OK" ;;
    "SCOPE-AUDIT: OUT-OF-SCOPE"*)  SCOPE_VERDICT="OUT-OF-SCOPE" ;;
    "SCOPE-AUDIT: MISSING-ROOTS"*) SCOPE_VERDICT="MISSING-ROOTS" ;;
    "SCOPE-AUDIT: SKIPPED"*)       SCOPE_VERDICT="SKIPPED" ;;
  esac
  # The prefix and the exit status must agree, or we did not understand the answer.
  case "$SCOPE_VERDICT:$rc" in
    OK:0|OUT-OF-SCOPE:1|MISSING-ROOTS:1|SKIPPED:2) ;;
    *) SCOPE_VERDICT="UNKNOWN" ;;
  esac
  return 0
}

# True when the repo-side graph at $1 exists and differs from the mirrored copy
# at $2 — the same `cmp -s` test the sync loop uses to decide "up-to-date".
mirror_is_stale() {
  local src_graph="$1" dst_graph="$2"
  [[ -f "$src_graph" ]] || return 1
  [[ -f "$dst_graph" ]] || return 0
  ! cmp -s "$src_graph" "$dst_graph"
}

repos=("$@")
if [[ ${#repos[@]} -eq 0 ]]; then
  # DEFAULT SCOPE: never "every mirror". Only mirrors whose source graph actually
  # differs from the mirrored copy — an unscoped run must not touch a repo nobody
  # rebuilt (that is how tray_pos_flutter got degraded to generic labels).
  # --all (INNOV-269) is the explicit opt-in back to "every mirror".
  selected=()
  for d in "$VAULT"/graphify/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    if [[ $SYNC_ALL -eq 1 ]] || mirror_is_stale "$REPOS_DIR/$n/graphify-out/graph.json" "$VAULT/graphify/$n/graph.json"; then
      repos+=("$REPOS_DIR/$n")
      selected+=("$n")
    fi
  done
  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "nothing to sync: no mirror's graph.json differs from its source" >&2
    exit 0
  fi
  echo "selected ${#selected[@]} mirror(s): ${selected[*]}" >&2
fi

synced=()
refused=()
for repo in "${repos[@]}"; do
  name="$(basename "$repo")"
  src="$repo/graphify-out"
  dst="$VAULT/graphify/$name"

  if [[ ! -f "$src/graph.json" ]]; then
    echo "skip $name: no graph at $src/graph.json" >&2
    continue
  fi
  if [[ -f "$dst/graph.json" ]] && cmp -s "$src/graph.json" "$dst/graph.json"; then
    echo "up-to-date: $name"
    continue
  fi

  # THE SCOPE GATE. Runs BEFORE the first copy, so a refusal leaves the vault
  # exactly as it found it — the mirror it already had is still the mirror it
  # has, and nothing half-published is left behind for the next reader to trust.
  scope_audit "$src/graph.json" "$repo" "$name"
  case "$SCOPE_VERDICT" in
    OUT-OF-SCOPE|MISSING-ROOTS)
      {
        echo "REFUSED $name: its graph does not match the recorded scope, so it was NOT published."
        printf '%s\n' "$SCOPE_OUTPUT"
        echo "  Nothing was copied for $name and no log line was written; the vault keeps the"
        echo "  mirror it already had. Fix the carve-out or the scope row, rebuild the graph,"
        echo "  then re-run this sync."
      } >&2
      refused+=("$name")
      continue
      ;;
    SKIPPED)
      {
        echo "warn: scope audit could not be determined for $name — publishing anyway, unaudited."
        printf '%s\n' "$SCOPE_OUTPUT"
        echo "  This is NOT a clean audit. Rebuild the graph (or fix the checkout path) so the"
        echo "  next sync can actually check it."
      } >&2
      ;;
    OK)
      printf '%s\n' "${SCOPE_OUTPUT%%$'\n'*}" >&2
      ;;
    *)
      {
        echo "warn: the scope audit did not answer for $name (node and/or $SCOPE_AUDIT) — publishing anyway, unaudited."
        [[ -n "$SCOPE_OUTPUT" ]] && printf '  %s\n' "${SCOPE_OUTPUT%%$'\n'*}"
        echo "  Unlike the label guard this does not fail closed: an unaudited publish is"
        echo "  recoverable, an overwritten labeled report is not. But it is not an OK either."
        echo "  Fix the auditor, then re-run to get a real verdict."
      } >&2
      ;;
  esac

  mkdir -p "$dst"
  cp "$src/graph.json" "$dst/graph.json"
  # Report is namespaced per repo in the vault so Obsidian's graph view and
  # quick-switcher don't collapse every repo's report to one "GRAPH_REPORT" node.
  #
  # LABEL GUARD: never let a LESS-labeled incoming report clobber a more-labeled
  # one. This is a COMPARISON, not an existence check: a keyless repo-side rebuild
  # can emit a handful of named headings alongside hundreds of "Community N"
  # placeholders, and copying that over a fully named report destroys the
  # vault-side labels and breaks every Code: [[_COMMUNITY_*]] link built on them
  # (the documented tray_pos_flutter incident). So we copy only when the incoming
  # report names at least as many communities as the existing one — an equal count
  # (a same-count relabel or plain content refresh) still copies. graph.json syncs
  # below either way; stubs regenerate from the preserved report + new graph
  # (member-overlap matching keeps stub filenames stable).
  #
  # The rule itself is label-guard.mjs's (shared with /brain:label). That makes
  # this guard depend on `node` BEFORE the copy, whereas build-community-notes.mjs
  # (also node) only runs after — so a missing node now surfaces earlier. That is
  # deliberate and consistent with the guard's whole purpose: the two failures are
  # not symmetric. Stubs not regenerating is recoverable (re-run the sync); a
  # report overwritten because we could not check it is not. So a node/module
  # failure REFUSES the report copy, exactly as an explicit refusal does, and only
  # the report — graph.json and manifest.json still mirror, and the vault keeps
  # the report it already had.
  if [[ -f "$src/GRAPH_REPORT.md" ]]; then
    guard_verdict=""; existing_named=""; incoming_named=""
    read -r guard_verdict existing_named incoming_named \
      <<<"$(label_guard_verdict "$dst/$name-GRAPH_REPORT.md" "$src/GRAPH_REPORT.md")" || true
    if [[ "$guard_verdict" == "allow" ]]; then
      cp "$src/GRAPH_REPORT.md" "$dst/$name-GRAPH_REPORT.md"
    elif [[ "$guard_verdict" == "refuse" ]]; then
      echo "preserving labeled report for $name: incoming has $incoming_named named communities, existing has $existing_named — run /brain:label $name to refresh labels" >&2
    else
      # FAIL CLOSED. We could not establish that the copy is safe, so we do not
      # copy. Loud, because a silently un-refreshed report is its own trap.
      echo "preserving labeled report for $name: the label guard could not run (node and/or $LABEL_GUARD) — the existing report was NOT overwritten. Fix the guard, then re-run; /brain:label $name can refresh labels." >&2
    fi
  fi
  rm -f "$dst/GRAPH_REPORT.md"  # drop legacy generic name if a prior sync left one
  [[ -f "$src/manifest.json" ]] && cp "$src/manifest.json" "$dst/manifest.json"

  # Regenerate Obsidian community stubs so [[_COMMUNITY_*]] links resolve.
  # The sibling script lives next to this one (in the plugin); the vault it operates
  # on is passed via BRAIN_ROOT.
  BRAIN_ROOT="$VAULT" node "$SCRIPT_DIR/build-community-notes.mjs" "$name" \
    || echo "warn: community notes not regenerated for $name" >&2

  # Node/edge counts for the log line; uses the repo's graphify interpreter
  # because plain `python` may be a Microsoft Store stub on Windows.
  PY_BIN="$(cat "$src/.graphify_python" 2>/dev/null || echo python3)"
  stats="$("$PY_BIN" - "$dst/graph.json" <<'PY' 2>/dev/null || true
import json, sys
g = json.load(open(sys.argv[1], encoding="utf-8"))
edges = g.get("links", g.get("edges", []))
print(f"{len(g.get('nodes', []))} nodes / {len(edges)} edges")
PY
)"
  echo "- $(date +%F) — ${name} graph mirror synced via bin/sync-graph.sh (${stats:-counts unavailable})." >> "$VAULT/wiki/log.md"
  echo "synced: $name (${stats:-?})"
  synced+=("$name")
done

# --- commit, via THE one guarded commit path (INNOV-275) --------------------
# Everything this block used to do by hand — open-PR detection, default-branch
# detection, the protected-branch refusal, the HEAD-pin re-check, the staging —
# now lives in vault-commit.sh, because /brain:save needed all of it too and a
# second copy would drift. This script's remaining job is to say WHAT to commit
# (the two paths it wrote) and WHEN it started (the pin).
#
# The paths must be covered by the vault's .saveinclude or vault-commit.sh will
# refuse — deliberately. "The sync may commit graph mirrors" is a statement about
# what the vault permits, so it belongs in the vault's allowlist, not hardcoded
# in the syncer. The shipped template lists both.
if [[ ${#synced[@]} -gt 0 && $COMMIT -eq 1 ]]; then
  vc_args=(-m "Sync graph mirror(s): ${synced[*]}")
  # Only pin when we actually read a branch+SHA at start; a non-git vault has
  # neither, and an empty pin would be a parse failure rather than "unpinned".
  if [[ -n "$HEAD_BRANCH_AT_START" && -n "$HEAD_SHA_AT_START" ]]; then
    vc_args+=(--pin "$HEAD_BRANCH_AT_START:$HEAD_SHA_AT_START")
  fi
  [[ $FORCE_COMMIT -eq 1 ]] && vc_args+=(--force-commit)
  vc_args+=(-- graphify/ wiki/log.md)

  if ! BRAIN_ROOT="$VAULT" bash "$SCRIPT_DIR/vault-commit.sh" "${vc_args[@]}"; then
    # vault-commit.sh has already explained itself on stderr, in detail. Add only
    # what it cannot know: which mirrors were synced, so the work is not lost
    # track of. The copies, the log.md line and the stubs are all on disk.
    echo "Mirrors synced (files written, commit refused above): ${synced[*]}" >&2
    exit 1
  fi
fi

# A scope refusal is a failed run even when everything else committed cleanly:
# the graph the vault was asked to publish is wrong, and exiting 0 would let
# /brain:save report a successful sync over a mirror that was never written.
if [[ ${#refused[@]} -gt 0 ]]; then
  echo "scope audit REFUSED ${#refused[@]} mirror(s): ${refused[*]} (see the reports above)" >&2
  exit 1
fi
