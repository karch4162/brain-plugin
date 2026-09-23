#!/usr/bin/env bash
# Resolve a direct, material conflict between the saved Codex Terra and Grok reviews.
# Never use this as a routine third review.
#
#   bash "$WAVE/tiebreak.sh" INNOV-309
set -uo pipefail

ISSUE="${1:-}"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CODEX_LOG="$ROOT/.wave-review.codex-terra.log"
GROK_LOG="$ROOT/.wave-review.grok.log"
DIFF_FILE="$ROOT/.wave-review.diff"

[ -s "$CODEX_LOG" ] && [ -s "$GROK_LOG" ] && [ -s "$DIFF_FILE" ] || {
  echo "NO ASTRA TIE-BREAK: requires completed Codex, Grok, and diff logs"
  exit 1
}

prompt="Resolve only a direct, material disagreement between the Codex Terra review in $CODEX_LOG and the Grok architecture review in $GROK_LOG for the diff in $DIFF_FILE. Read all three files. State the evidence and exactly one resolution: CLAUDE FIX, DISMISS FINDING, or NEEDS HUMAN. Do not suggest unrelated improvements. End with TIE-BREAK: <resolution>."
out="$(timeout 900 codex -s read-only --model gpt-6-astra exec "$prompt" 2>"$ROOT/.wave-review.astra.err")"
printf '%s\n' "$out" > "$ROOT/.wave-review.astra.log"

if ! sed '/^[[:space:]]*$/d' <<< "$out" | tail -n 1 | grep -q '^TIE-BREAK: '; then
  echo "NO ASTRA TIE-BREAK: incomplete verdict; see .wave-review.astra.log/.err"
  exit 1
fi
printf '%s\nTIE-BREAKER: astra\n' "$out"
