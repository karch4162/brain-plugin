#!/usr/bin/env bash
# Required fresh correctness review for a Claude wave worker.
#
#   bash "$WAVE/review.sh" INNOV-309
#   RISK_REVIEW=1 bash "$WAVE/review.sh" INNOV-309
#
# Codex Terra is the one correctness reviewer. Grok is added only for a defined
# architecture risk. A failed Codex verdict is never retried elsewhere; only Codex
# quota exhaustion falls back (grok, then sonnet), and the REVIEWER line says so.
# Every attempt leaves .wave-review.<name>.log/.err in the worktree.
set -uo pipefail

ISSUE="${1:-}"
RISK_REVIEW="${RISK_REVIEW:-0}"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DIFF_FILE="$ROOT/.wave-review.diff"
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"

grep -qxF '.wave-review.*' "$EXCLUDE" 2>/dev/null || echo '.wave-review.*' >> "$EXCLUDE"
{
  git diff --merge-base $WAVE_BASE
  git ls-files --others --exclude-standard -z | xargs -0 -r -I{} git diff --no-index -- /dev/null {}
} > "$DIFF_FILE"
[ -s "$DIFF_FILE" ] || { echo "NO CODEX REVIEW: empty diff against $WAVE_BASE"; exit 1; }

correctness_prompt="Review the unified diff supplied on stdin. It is this worktree's complete change against $WAVE_BASE, including untracked files. Report only high-confidence findings, most severe first, each with file:line. Check correctness, CLAUDE.md rules, security boundaries, and whether each changed test asserts behavior rather than only execution. No style nits or summary. End with TEST VERDICT: followed by either none, or one bullet per changed test naming behavior or execution."

architecture_prompt="Act as an adversarial architecture reviewer for this worktree's uncommitted change against $WAVE_BASE. Look only for high-confidence failures in trust boundaries, tenant isolation, API contracts, concurrency, recovery, or operational behavior. Cite file:line. Do not repeat ordinary correctness findings or make style comments. End with ARCHITECTURE VERDICT: PASS, FINDINGS, or NEEDS HUMAN."

verdict_ok() {
  local marker="$1" output="$2"
  sed '/^[[:space:]]*$/d' <<< "$output" | awk -v marker="$marker" '
    index($0, marker) == 1 { seen = 1; ok = 1; next }
    seen && !/^[-*] / { ok = 0 }
    END { exit !(seen && ok) }'
}

# `codex review` treats --base, --uncommitted, and a custom prompt as alternative
# review inputs. Feed our saved complete diff to `exec` instead so Terra receives
# the exact same scope that the worker must gate, including untracked test files.
codex_out="$(cat "$DIFF_FILE" | timeout 900 codex exec -s read-only --model gpt-5.6-terra "$correctness_prompt" 2>"$ROOT/.wave-review.codex-terra.err")"
printf '%s\n' "$codex_out" > "$ROOT/.wave-review.codex-terra.log"
if verdict_ok 'TEST VERDICT:' "$codex_out"; then
  printf '%s\nREVIEWER: codex-terra\n' "$codex_out"
elif grep -qiE 'usage limit|usage_limit_exceeded|rate limit' "$ROOT/.wave-review.codex-terra.err"; then
  # Quota exhaustion only. A bad or missing verdict from a working Codex is never
  # retried elsewhere. Grok first (different family from the Claude worker), then
  # Sonnet. The REVIEWER line names the fallback so human review sees the weaker gate.
  fallback_prompt="${correctness_prompt/supplied on stdin/in the file .wave-review.diff at the repo root (read it first)}"
  name=grok-fallback
  fb_out="$(timeout 900 grok --permission-mode bypassPermissions -p "$fallback_prompt" 2>"$ROOT/.wave-review.$name.err")"
  printf '%s\n' "$fb_out" > "$ROOT/.wave-review.$name.log"
  if ! verdict_ok 'TEST VERDICT:' "$fb_out"; then
    name=sonnet-fallback
    fb_out="$(timeout 900 claude -p --model sonnet --allowedTools Read Grep Glob "$fallback_prompt" 2>"$ROOT/.wave-review.$name.err")"
    printf '%s\n' "$fb_out" > "$ROOT/.wave-review.$name.log"
  fi
  if ! verdict_ok 'TEST VERDICT:' "$fb_out"; then
    echo "NO CODEX REVIEW: Codex quota exhausted and no fallback returned a complete TEST VERDICT; see .wave-review.*-fallback.log/.err"
    exit 1
  fi
  printf '%s\nREVIEWER: %s (codex quota exhausted)\n' "$fb_out" "$name"
else
  echo "NO CODEX REVIEW: Codex Terra did not return a complete TEST VERDICT; see .wave-review.codex-terra.log/.err"
  exit 1
fi

if [ "$RISK_REVIEW" != "1" ]; then
  exit 0
fi

# Grok's CLI requires bypassPermissions to complete this read-only review in the
# current local setup. The prompt confines its role; the worker must inspect git
# status after it returns.
grok_out="$(timeout 900 grok --permission-mode bypassPermissions -p "$architecture_prompt" 2>"$ROOT/.wave-review.grok.err")"
printf '%s\n' "$grok_out" > "$ROOT/.wave-review.grok.log"
if ! verdict_ok 'ARCHITECTURE VERDICT:' "$grok_out"; then
  echo "NO GROK ARCHITECTURE REVIEW: incomplete verdict; see .wave-review.grok.log/.err"
  exit 1
fi

printf '%s\nARCHITECTURE REVIEWER: grok\n' "$grok_out"
