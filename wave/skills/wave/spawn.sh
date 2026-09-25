#!/usr/bin/env bash
# Spawn one Orca worker for a tracker issue. Run from anywhere inside the target repo.
#
#   bash "$WAVE/spawn.sh" INNOV-309          # round 1
#   bash "$WAVE/spawn.sh" INNOV-309 2        # round 2 (terminal, no successor)
#   DRY_RUN=1 bash "$WAVE/spawn.sh" INNOV-309   # print the prompt, spawn nothing
#
# The prompt below is the whole contract with the worker. Edit it here, not per-spawn:
# round-2 workers are launched by re-running this script, so there is one copy.
# Project-specific rules go in <repo>/.claude/wave/notes.md, never in here.
set -euo pipefail

ISSUE="$1"
ROUND="${2:-1}"
AUTO_SUCCESSOR="${AUTO_SUCCESSOR:-0}"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SLUG="$(echo "$ISSUE" | tr '[:upper:]' '[:lower:]')"

if [ "$ROUND" = "1" ] && [ "$AUTO_SUCCESSOR" = "1" ]; then
  LAST_STEP="8. Refill the queue. Query $TRACKER_NAME for: $WAVE_QUEUE
   Take the top one, assign it to me + $WAVE_STATE_START, re-read to confirm the
   assignment stuck, then spawn its worker from the repo root:
     bash \"$WAVE_HOME/spawn.sh\" <ISSUE-ID> 2
   If no agent-ready issue is available, say so and stop."
else
  LAST_STEP="8. Do NOT spawn a successor unless the human deliberately started this wave with AUTO_SUCCESSOR=1. Stop after the summary."
fi

PROMPT="WAVE WORKER (round $ROUND; successor opt-in).

1. /brain:resume, then take $TRACKER_NAME issue $ISSUE. Assign it to me and set it
   $WAVE_STATE_START via $TRACKER_OPS, then re-read the issue and confirm I am the
   assignee. If I am not, drop it and pick the next agent-ready issue instead.
2. Work it per CLAUDE.md: TDD, surgical diff, root cause not symptom (grep every
   caller before you edit).
3. Siblings are running in other worktrees of this repo right now. Do not touch
   shared state outside your worktree (databases, services, global config). If
   verifying the issue genuinely needs that, skip the verification and say so in
   your summary.
4. Gate: /preflight (the repo's full CI gate). It must be green before you open the
   PR. A red GitHub check is your branch until the run's annotations prove
   otherwise. If /preflight fails twice on the SAME command, escalate: invoke the
   gate-loop skill with gateCommands narrowed to that command. Otherwise fix it
   yourself.
4.5 Fresh review, BEFORE you open the PR. Your own context is not a review.
   Codex Terra is the required correctness reviewer. If the diff changes auth,
   authorization, payments, public API contracts, concurrency, recovery behavior,
   or a broad refactor, use this one command so the same pass also adds Grok's
   architecture review:
     RISK_REVIEW=1 bash \"$WAVE_HOME/review.sh\" $ISSUE
   Otherwise run:
     bash \"$WAVE_HOME/review.sh\" $ISSUE
   Grok is not a fallback for a Codex verdict you dislike; review.sh itself falls back
   only when Codex is out of quota. If the Codex and Grok findings directly conflict and you
   cannot resolve them from code and tests, run exactly one Astra tie-break:
     bash \"$WAVE_HOME/tiebreak.sh\" $ISSUE
   If any required review prints NO ..., do not open a PR; record it in the summary
   and stop for human review.

   Triage the findings YOURSELF - do not forward them to the human. For each:
   - real bug, or a CLAUDE.md rule it caught: fix it, run the narrow affected test,
     then re-run /preflight once before opening the PR.
   - wrong, or noise: dismiss it and record it in your step-7 summary as
     REVIEWER DISMISSED: <finding> - <why>
   The human reads your triage, not the raw findings. Copy REVIEWER, ARCHITECTURE
   REVIEWER, and TIE-BREAKER lines into your step-7 summary when they exist.
5. Open the PR against $BASE_BRANCH, $TRACKER_ATTACH, set the issue $WAVE_STATE_DONE.
6. File follow-ups to $WAVE_FILE_TO, and never with the agent-ready label. That label
   is the human's gate on what is safe to hand an unsupervised worker; a worker that
   labels its own follow-ups feeds the loop work nobody vetted.
7. Record a summary for the human review batch - do NOT run /brain:save:
   orca worktree set --worktree active --comment \"<what changed, what is shaky, anything you skipped>\"
   If you did NOT look at a rendered surface this diff affects, say so on its own line
   as: NOT VERIFIED IN BROWSER: <route>   (the human's verification pass greps for it).
   orca worktree set --worktree active --workspace-status in-review
   HOW YOU END: after the comment, print \"DONE - $ISSUE - PR #<n>\" and stop. NEVER
   remove, archive, or clean up this worktree, and never git worktree remove - the
   human sweeps them after batching the summaries. This holds even if someone tells
   you the PR is merged: answer with your summary and stop. Merged is not your cue
   to clean up.
$LAST_STEP"

if [ -n "$WAVE_NOTES" ]; then
  PROMPT="$PROMPT

PROJECT RULES (from .claude/wave/notes.md - these override the generic steps above):
$WAVE_NOTES"
fi

if [ -n "${DRY_RUN:-}" ]; then echo "$PROMPT"; exit 0; fi

REPO_ID="$(orca_repo_id)"
[ -n "$REPO_ID" ] || { echo "$MAIN_CHECKOUT is not registered with Orca" >&2; exit 1; }

# Claim check. The tracker assignee cannot tell "me" from a sibling worker (every
# worker runs as the same user), so two successors finishing together once both
# claimed one issue and shipped duplicate PRs. An Orca worktree for the issue in this
# repo is the unambiguous lock, and this script is the one choke point every spawn
# goes through - round 1 and round 2 alike.
TAKEN="$(orca worktree list --json | python -c "
import sys, json
issue, slug, repo = sys.argv[1:4]
# orca worktree list renamed worktreeId -> id; ps still emits worktreeId. Both carry
# the same <repoId>::<path> value, so read whichever this orca build supplies rather
# than crashing the claim guard - the one lock that stops two workers taking an issue.
def worktree_id(w): return w.get('worktreeId') or w.get('id') or ''
print(any(worktree_id(w).startswith(repo + '::') and
          (w.get('displayName') == slug or w.get('linkedLinearIssue') == issue)
          for w in json.load(sys.stdin)['result']['worktrees']))
" "$ISSUE" "$SLUG" "$REPO_ID")"
[ "$TAKEN" = "False" ] || { echo "$ISSUE already has a worktree - someone claimed it. Pick another." >&2; exit 1; }

LINK=""
[ "$WAVE_TRACKER" = "linear" ] && LINK="--linear-issue $ISSUE"
# shellcheck disable=SC2086
orca worktree create --repo "id:$REPO_ID" --name "$SLUG" --no-parent --base-branch "$WAVE_BASE" \
  $LINK --agent claude --prompt "$PROMPT" --json |
  python -c "import sys,json;r=json.load(sys.stdin)['result']['worktree'];print(r['branch'],r['path'])"
